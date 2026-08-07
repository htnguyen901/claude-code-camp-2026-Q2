require_relative "room_echo"

module LogViz
  # Detects `info_self` tool results (inventory/equipment/score/exits/
  # where/levels) and reduces one to displayable text. No per-kind shape
  # parsing — real logged output shapes weren't reliably distinguishable
  # per kind (see player_journey_map.md Background's note on tool_call/
  # tool_result misattribution), so this keeps the honest, simple contract:
  # "here is the last raw text seen for this kind, as of this turn."
  module SelfState
    def self.info_self?(tool_name)
      tool_name.to_s.split("__").last == "info_self"
    end

    def self.summarize(raw_ansi_text)
      lines = RoomEcho.strip_ansi(raw_ansi_text).split("\n")
      lines.reject! { |l| l.strip.empty? || l =~ RoomEcho::PROMPT_RE }
      lines.join("\n").strip
    end
  end
end
