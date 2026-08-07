require_relative "ansi"

module LogViz
  # Parses a CircleMUD/tbaMUD room echo — the fixed shape every `look`/
  # `move`/`enter`/`leave`/`flee` result follows: a title line, a
  # description paragraph, an "[ Exits: ... ]" line, zero or more
  # room-content lines, then the HP/Mana/Move prompt. See
  # docs/plans/observability/player_journey_map.md §1 for the real captured
  # examples this is grounded in.
  module RoomEcho
    EXITS_RE       = /\[ Exits: ([a-z ]*)\]/i
    PROMPT_RE      = /\A\d+H\s+\d+M\s+\d+V\b/
    TITLE_COLOR_RE = /\e\[0;33m(.+?)\e\[0m/

    # Primitives defined to always emit a room echo. `flee` is included: a
    # successful flee relocates the player unpredictably mid-combat, which
    # is exactly the kind of unplanned move a "where is he" view needs to
    # catch, not miss.
    LOCATION_VERBS = %w[look move enter leave flee].freeze

    def self.location_tool?(tool_name)
      LOCATION_VERBS.include?(tool_name.to_s.split("__").last)
    end

    def self.strip_ansi(raw_ansi_text)
      raw_ansi_text.to_s.gsub(Ansi::ESCAPE_RE, "").gsub("\r\n", "\n")
    end

    # Strips ANSI, blank lines, and the trailing HP/Mana/Move status-prompt
    # line from a raw MUD reply that ISN'T itself a room echo — namely an
    # `examine`/`look at <target>` result. `#parse` already discards the
    # prompt line from a room's `contents`; this is the same cleanup for
    # WorldMap#record_examination, so a persisted `examinations.result_text`
    # (surfaced as a discoveries row's "Findings" / a room_knowledge tool
    # result's clue) is the actual answer text, not
    # "...\n\n21H 100M 83V (news) (motd) > " noise appended to it.
    def self.clean_reply(raw_ansi_text)
      strip_ansi(raw_ansi_text).split("\n").map(&:strip).reject { |l| l.empty? || l =~ PROMPT_RE }.join(" ").strip
    end

    # Returns nil for anything that isn't a real room echo — a failed move
    # ("Alas, you cannot go that way..."), a dark room ("It is pitch
    # black..."), a mangled/misattributed result, etc. Callers must treat
    # nil as "no location update," never as an empty room.
    #
    # The title is located by its ANSI color wrapper (0;33), not by "the
    # first line" — CircleMUD sometimes prepends an uncolored zone-warning
    # banner ("This zone is above your recommended level.") directly in
    # front of the real room echo, confirmed against real logged sessions.
    # Anchoring on color instead of position skips that banner correctly.
    def self.parse(raw_ansi_text)
      raw = raw_ansi_text.to_s
      exits_pos = raw.index(EXITS_RE)
      return nil unless exits_pos

      title_match = TITLE_COLOR_RE.match(raw[0...exits_pos])
      return nil unless title_match

      title = title_match[1].strip
      return nil if title.empty?

      lines      = strip_ansi(raw).split("\n")
      exits_line = lines.find { |l| l =~ EXITS_RE }
      exits_idx  = lines.index(exits_line)
      title_idx  = lines.index { |l| l.strip == title }
      return nil unless title_idx && title_idx < exits_idx

      description = lines[(title_idx + 1)...exits_idx].join(" ").squeeze(" ").strip
      contents    = lines[(exits_idx + 1)..]
                      .map(&:strip)
                      .reject { |l| l.empty? || l =~ PROMPT_RE }

      {
        title: title,
        description: description,
        exits: exits_line[EXITS_RE, 1].to_s.split(" "),
        contents: contents
      }
    end
  end
end
