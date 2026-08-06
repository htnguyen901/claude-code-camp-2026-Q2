require "socket"
require "thread"

module MudManager
  # Long-lived telnet connection to a CircleMUD server.
  #
  # A background thread continuously drains the socket into an internal
  # buffer, stripping telnet IAC negotiation bytes. The agent loop sends a
  # command and then calls `read_until_quiet` (or `read_until` for a known
  # prompt) to collect both the command's response and any async chatter
  # that arrived in the meantime.
  class Session
    DEFAULT_HOST    = "localhost"
    DEFAULT_PORT    = 4000
    DEFAULT_TIMEOUT = 10.0

    # Telnet protocol bytes we recognise. We don't negotiate — we just
    # consume and discard IAC sequences so they don't pollute the buffer.
    IAC  = 0xFF
    DONT = 0xFE
    DO   = 0xFD
    WONT = 0xFC
    WILL = 0xFB
    SB   = 0xFA
    SE   = 0xF0

    class Error          < StandardError; end
    class ConnectionError < Error; end
    class LoginError     < Error; end
    class Timeout        < Error; end
    class CharacterExistsError < Error; end

    attr_reader :host, :port

    def initialize(host: DEFAULT_HOST, port: DEFAULT_PORT, timeout: DEFAULT_TIMEOUT)
      @host       = host
      @port       = port
      @timeout    = timeout
      @socket     = nil
      @reader     = nil
      @buffer     = String.new.force_encoding(Encoding::UTF_8)
      @buffer_mu  = Mutex.new
      @buffer_cv  = ConditionVariable.new
      @closed     = false
      @last_recv_at = nil
    end

    def open
      raise Error, "already open" if @socket
      @socket = TCPSocket.new(@host, @port)
      @closed = false
      start_reader
      self
    rescue SystemCallError => e
      raise ConnectionError, "connect #{@host}:#{@port} failed: #{e.message}"
    end

    def open?
      @socket && !@closed
    end

    def close
      return if @closed
      @closed = true
      begin
        @socket&.close
      rescue StandardError
        # already closed / broken — fine
      end
      @reader&.join(1)
      @socket = nil
      @reader = nil
    end

    # Send a command. Accepts a String, a Primitives::Command, or anything
    # that responds to #raw or #to_s. A trailing newline is appended.
    def send_command(command)
      raise Error, "session not open" unless open?
      line =
        if command == :return || command == :enter
          ""
        elsif command.respond_to?(:raw)
          command.raw
        else
          command.to_s
        end
      @socket.write(line + "\r\n")
      line
    end
    alias_method :send, :send_command

    # Drain whatever is currently buffered and return it. Non-blocking.
    def drain
      @buffer_mu.synchronize do
        out, @buffer = @buffer, String.new.force_encoding(Encoding::UTF_8)
        out
      end
    end

    # Block until `quiet_seconds` have elapsed with no new bytes arriving,
    # or `timeout` total seconds pass. Returns whatever accumulated.
    # This is the workhorse for "send a command, get the full response".
    def read_until_quiet(quiet_seconds = 1.0, timeout: nil)
      raise Error, "session not open" unless open?
      deadline = monotime + (timeout || @timeout)
      @buffer_mu.synchronize do
        loop do
          remaining_total = deadline - monotime
          break if remaining_total <= 0

          if @last_recv_at && (monotime - @last_recv_at) >= quiet_seconds && !@buffer.empty?
            break
          end

          wait_for = if @last_recv_at && !@buffer.empty?
                       quiet_seconds - (monotime - @last_recv_at)
                     else
                       remaining_total
                     end
          wait_for = [wait_for, remaining_total].min
          break if wait_for <= 0
          @buffer_cv.wait(@buffer_mu, wait_for)
        end
        out, @buffer = @buffer, String.new.force_encoding(Encoding::UTF_8)
        out
      end
    end

    # Block until the buffer contains the given pattern (String or Regexp),
    # then return everything up to and including the match. Raises Timeout
    # if `timeout` seconds pass without a match.
    def read_until(pattern, timeout: nil)
      raise Error, "session not open" unless open?
      regexp = pattern.is_a?(Regexp) ? pattern : Regexp.new(Regexp.escape(pattern))
      deadline = monotime + (timeout || @timeout)
      @buffer_mu.synchronize do
        loop do
          if (m = regexp.match(@buffer))
            cut = m.end(0)
            out = @buffer[0...cut]
            @buffer = @buffer[cut..] || String.new
            @buffer.force_encoding(Encoding::UTF_8)
            return out
          end
          remaining = deadline - monotime
          raise Timeout, "read_until #{pattern.inspect} after #{timeout}s" if remaining <= 0
          raise ConnectionError, "socket closed while waiting" if @closed
          @buffer_cv.wait(@buffer_mu, remaining)
        end
      end
    end

    # CircleMUD terminates every command response with a prompt that ends in
    # "> " (greater-than space). Waiting for that sentinel is faster and more
    # deterministic than relying on a silence window — it returns as soon as
    # the server signals it has finished processing the command.
    #
    # Falls back to draining the buffer if the prompt is never seen within
    # the timeout (e.g. during combat when extra async lines may slip in).
    PROMPT_SENTINEL = "> "

    def read_until_prompt(timeout: nil)
      read_until(PROMPT_SENTINEL, timeout: timeout)
    rescue Timeout
      warn "[MudManager::Session] prompt not detected within timeout; returning buffered content"
      drain
    end

    # Send a command and return its response. This is the safe way to do a
    # one-shot round trip — send_command + read_until_prompt back to back is
    # NOT equivalent, and will misattribute output under real MUD conditions.
    #
    # CircleMUD pushes unsolicited text at any time, independent of anything
    # the client sends — broadcasts, other players' visible actions, room
    # spec_procs — each one followed by its own freshly re-displayed prompt.
    # read_until_prompt has no way to tell "a prompt that terminates MY
    # command's response" apart from "a prompt that just happens to be
    # sitting in the buffer because something unrelated arrived earlier
    # while nobody was reading." If any such text is already buffered when
    # we call read_until_prompt, its trailing prompt is what gets matched —
    # this command's real response, generated moments later, becomes the
    # leftover for whatever the NEXT command call is. That shift never
    # self-corrects: every later exchange for the rest of the session
    # inherits the previous one's real output, one message behind.
    #
    # Draining right before we send eliminates the leftover that causes
    # this: anything sitting in the buffer at that instant is guaranteed to
    # predate — and therefore not belong to — the command we're about to
    # issue, so it's safe to discard. It doesn't make this airtight (a
    # message could in principle land in the microseconds between drain and
    # send), but it collapses what was a permanent, session-long
    # misattribution into, at worst, a single corrupted response that the
    # next command's own drain immediately clears — CircleMUD's plain
    # telnet protocol has no per-request correlation id, so that residual
    # race is not something a client-side fix can fully close.
    def command(input, timeout: nil)
      drain
      send_command(input)
      read_until_prompt(timeout: timeout)
    end

    # Send a name at the "By what name do you wish to be known?" prompt and
    # wait for the server to reveal which of the two nanny() branches it
    # took: an existing name goes straight to "Password:"; an unrecognized
    # one asks to confirm the spelling ("Did I get that right, <Name>
    # (Y/N)?") before walking into new-character creation. #login and
    # #create_character both start here and branch on the result.
    def identify(name)
      read_until(/By what name do you wish to be known.*\?/i)
      send_command(name)
      read_until(/Password|Did I get that right/i)
    end

    # Walk the CircleMUD login dance for an EXISTING character:
    def login(username, password)
      result = identify(username)
      raise LoginError, "character '#{username}' does not exist yet" if result =~ /Did I get that right/i

      # Enter Password
      self.send_command(password)

      output = self.read_until(/Welcome|Reconnecting|Wrong password/i)
      if output =~ /Reconnecting/i
        # Already in-world (this connection took over a linkdead character).
        # read_until above only consumed up through the matched word itself
        # ("Reconnecting"), not the status line + prompt the server sent
        # right after it (e.g. ".\r\n\r\n21H 100M 77V (news) (motd) > ") —
        # that's still sitting unread in the buffer. Drain it now, or the
        # first real gameplay command's read_until_prompt would match THIS
        # leftover prompt instead of its own, and silently return stale
        # banner text as if it were that command's response.
        self.read_until_prompt
      elsif output =~ /Welcome/i
        # fresh login, handle menu
        self.send_command(:return) # enter for main menu
        self.send_command(1)       # enter the game
        self.read_until_quiet
      elsif output =~ /Wrong password/i
        raise LoginError, "wrong password"
      end
    end

    # Walk the CircleMUD new-character dance (nanny()'s CON_QSEX/CON_QCLASS
    # states) for a name #identify confirmed is NOT already taken: confirm
    # spelling, set + confirm a password, sex, class, then land in-game the
    # same way #login's fresh-`Welcome` branch does. Races are not asked
    # about here — this server build has them disabled (confirmed against
    # the live dev MUD; if a future build enables them a race prompt would
    # need handling right after the class prompt).
    #
    # `sex` is "M" or "F". `char_class` is the single letter shown in the
    # class menu ("C" Cleric, "T" Thief, "W" Warrior, "M" Magic-user).
    def create_character(name, password, sex:, char_class:)
      result = identify(name)
      raise CharacterExistsError, "character '#{name}' already exists" if result =~ /Password/i

      send_command("Y") # "Did I get that right, <Name> (Y/N)?"
      read_until(/Give me a password/i)
      send_command(password)
      read_until(/retype password/i)
      send_command(password)
      read_until(/What is your sex/i)
      send_command(sex)
      # Anchored to line start: the class MENU's own preceding line is
      # "Select a class:", which also contains the substring "class:" and
      # would otherwise match early.
      read_until(/^Class:/i)
      send_command(char_class)
      read_until(/PRESS RETURN/i)
      send_command(:return) # enter for main menu
      send_command(1)       # enter the game
      read_until_quiet
    end

    # Deletes the character of the session's CURRENT, already-in-game login
    # (call #login first) via the post-login character menu's "[5] Delete
    # this character" option. Requires re-entering `password` a second time
    # — CircleMUD's own verification step, not this client's invention.
    #
    # The server does not respond to further input on this connection once
    # deletion completes — open a fresh Session for anything after this.
    def delete_character(password)
      send_command("quit")
      read_until(/Make your choice/i)
      send_command(5)
      read_until(/password for verification/i)
      send_command(password)
      read_until(/type "yes" to confirm/i)
      send_command("yes")
      read_until(/deleted/i)
    end

    # ----- internals -----

    private

    def start_reader
      @reader = Thread.new do
        begin
          loop do
            chunk = @socket.readpartial(4096)
            break if chunk.nil? || chunk.empty?
            text = strip_iac(chunk)
            unless text.empty?
              @buffer_mu.synchronize do
                @buffer << text.force_encoding(Encoding::UTF_8)
                @last_recv_at = monotime
                @buffer_cv.broadcast
              end
            end
          end
        rescue EOFError, IOError, Errno::ECONNRESET
          # remote closed — fall through
        rescue StandardError => e
          warn "[MudManager::Session] reader error: #{e.class}: #{e.message}"
        ensure
          @buffer_mu.synchronize do
            @closed = true
            @buffer_cv.broadcast
          end
        end
      end
      @reader.report_on_exception = false
    end

    # Telnet protocol IAC stripper. The MUD may interleave:
    #   IAC (WILL|WONT|DO|DONT) <option>            — 3 bytes
    #   IAC SB <option> ... IAC SE                  — variable
    #   IAC IAC                                     — literal 0xFF byte
    # We discard all of them. CircleMUD's negotiation is mostly echo
    # toggling around the password prompt, which we don't honor.
    def strip_iac(bytes)
      out = String.new(capacity: bytes.bytesize)
      bs  = bytes.bytes
      i   = 0
      while i < bs.length
        b = bs[i]
        if b == IAC
          nxt = bs[i + 1]
          case nxt
          when nil
            break
          when IAC
            out << 0xFF.chr
            i += 2
          when WILL, WONT, DO, DONT
            i += 3
          when SB
            j = i + 2
            j += 1 while j < bs.length && !(bs[j] == IAC && bs[j + 1] == SE)
            i = j + 2
          else
            i += 2
          end
        else
          out << b.chr
          i += 1
        end
      end
      out
    end

    def monotime
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
