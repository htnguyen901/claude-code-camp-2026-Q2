require "socket"
require "thread"

module MudManager
  # A minimal in-process stand-in for a CircleMUD server, used by offline
  # tests and `mud-manager --mcp`'s --dry demo. It speaks just enough of
  # the real login dance (see MudManager::Session#login) to get a
  # character logged in, then echoes any command line back as
  # "You do: <line>\r\n> " — the trailing "> " is the same prompt
  # sentinel Session#read_until_prompt looks for against a real MUD.
  class FakeMud
    attr_reader :port

    # A longer, realistically-flowery CircleMUD-shaped room echo (ANSI
    # title/exits color, a multi-sentence prose description, and itemized
    # "X is here."-style content lines) — the initial room ("A nondescript
    # room.") is deliberately too short to exercise prose compaction at all,
    # so this is the fixture boukensha's Compactor Tier 2 eval suite needs
    # (see docs/plans/token_optimization/mud_response_compaction.md, Tier 2
    # Verification #1). Reached with a single "north" from the start room.
    FLOWERY_ROOM = (
      "\e[0;33mThe Sunken Garden\e[0m\r\n" \
      "   You stand in a sprawling, overgrown garden that must once have been\r\n" \
      "the pride of some forgotten noble house. Ivy chokes the crumbling stone\r\n" \
      "archways, and thick moss carpets every surface in a soft green blanket.\r\n" \
      "Somewhere beneath the tangled hedges you can hear the faint trickle of\r\n" \
      "running water, though the source is nowhere in sight. Broken statues,\r\n" \
      "worn featureless by centuries of rain, stand sentinel among the weeds,\r\n" \
      "watching over a garden that has long since reclaimed itself from any\r\n" \
      "human hand.\r\n" \
      "\e[0;36m[ Exits: s ]\e[0m\r\n" \
      "\e[0;32mA weathered stone fountain is here, choked with moss and dead leaves.\e[0m\r\n" \
      "\e[0;33mA tarnished silver locket lies half-buried in the undergrowth.\e[0m\r\n" \
      "> "
    ).freeze

    # A two-screen CircleMUD-style pager exchange, triggered by "help" —
    # exercises MudManager::Primitives#page / the boukensha `page` tool
    # (docs/journal/3_capable.md's "Agent view level info, then can't get
    # out ... don't have tool to exit" bug). The first screen deliberately
    # does NOT end in "> " (Session#read_until_prompt's sentinel), the same
    # way a real CircleMUD pager prompt doesn't — only answering it with
    # RETURN/"q"/etc. gets the normal prompt back.
    PAGER_PAGE_1 = (
      "This is a very long help topic that does not fit on one screen.\r\n" \
      "[ Return to continue, (q)uit, (r)efresh, (b)ack, or page number (1/2) ]"
    ).freeze

    PAGER_PAGE_2 = "The rest of the help topic. That's everything.\r\n> ".freeze

    def initialize(name: "Gandalf", password: "secret")
      @name       = name
      @password   = password
      @server     = TCPServer.new("127.0.0.1", 0)
      @port       = @server.addr[1]
      @clients    = []
      @clients_mu = Mutex.new
      @accept_thread = Thread.new { accept_loop }
      @accept_thread.report_on_exception = false
    end

    def stop
      @server.close rescue nil
      @accept_thread.join(1)
      @clients_mu.synchronize { @clients.each { |c| c.close rescue nil } }
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        @clients_mu.synchronize { @clients << client }
        thread = Thread.new(client) { |c| handle_client(c) }
        thread.report_on_exception = false
      end
    rescue IOError, Errno::EBADF
      # server socket closed — normal shutdown
    end

    def handle_client(sock)
      return unless login!(sock)

      entered = false
      paging  = false
      loop do
        line = read_line(sock)
        break if line.nil?

        unless entered
          # Swallow the blank "enter for menu" line and the "1" that picks
          # "enter the game" — Session#login sends both after seeing
          # "Welcome". The first real reply we send is the room
          # description, which is what its trailing read_until_quiet is
          # waiting to see go quiet.
          next if line.empty?
          if line == "1"
            entered = true
            sock.write("\r\nA nondescript room.\r\nExits: north.\r\n> ")
          end
          next
        end

        if paging
          case line.to_s.strip.downcase
          when "", "return"
            sock.write("\r\n#{PAGER_PAGE_2}")
            paging = false
          when "q"
            sock.write("\r\n> ")
            paging = false
          else
            # "r"/"b"/a page number: still paging either way in this fixture
            # — real behavior (redisplay/go back/jump) isn't needed to
            # exercise "the agent can send something and it's accepted".
            sock.write("\r\n#{PAGER_PAGE_1}")
          end
          next
        end

        if line =~ /\Aquit\z/i
          sock.write("Goodbye.\r\n")
          break
        end
        if line =~ /\Anorth\z/i
          sock.write("\r\n#{FLOWERY_ROOM}")
          next
        end
        if line =~ /\Ahelp\z/i
          sock.write("\r\n#{PAGER_PAGE_1}")
          paging = true
          next
        end
        sock.write("You do: #{line}\r\n> ")
      end
    rescue IOError, Errno::ECONNRESET, Errno::EPIPE
      nil
    ensure
      sock.close rescue nil
    end

    # Returns true on a successful login, false (having already replied
    # and closed) on a bad name/password.
    def login!(sock)
      sock.write("By what name do you wish to be known? ")
      name = read_line(sock)
      sock.write("\r\nPassword: ")
      pass = read_line(sock)

      unless name == @name && pass == @password
        sock.write("\r\nWrong password.\r\n")
        return false
      end

      sock.write("\r\nWelcome, #{name}, to the game!\r\n")
      true
    end

    def read_line(sock)
      sock.gets&.strip
    end
  end
end
