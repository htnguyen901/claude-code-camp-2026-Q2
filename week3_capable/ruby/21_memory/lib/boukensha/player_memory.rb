require "json"
require "fileutils"

module Boukensha
  # One player's persistent, cross-session memory — .boukensha/memory/
  # <name>.jsonl (raw, append-only, one line per finished Session.play run)
  # and .boukensha/memory/<name>.md (the bounded digest, the only one of the
  # two ever read back into a prompt). See docs/plans/memory/
  # player_memory.md decisions 2 and 6 — never constructed without a player
  # name, never shared between two players' names.
  class PlayerMemory
    def self.load(player_name, memory_dir:)
      new(player_name, memory_dir: memory_dir)
    end

    def initialize(player_name, memory_dir:)
      @player_name = player_name
      @memory_dir  = memory_dir
    end

    # nil if no digest has ever been written for this player yet — a brand
    # new character's first session sees player_memory: nil end-to-end, the
    # same "byte-identical when the feature has nothing to say" posture
    # Context#effective_system already uses for a nil/blank plan.
    def digest_text
      return nil unless File.exist?(digest_path)

      text = File.read(digest_path).strip
      text.empty? ? nil : text
    end

    def save_digest(text)
      FileUtils.mkdir_p(@memory_dir)
      File.write(digest_path, text.to_s.strip)
    end

    # One line per finished Session.play run. record: a JSON-serializable
    # Hash (goal:, stop_reason:, turns:, checkpoints:, outcome:).
    def append_session_record(record)
      FileUtils.mkdir_p(@memory_dir)
      File.open(raw_path, "a") { |f| f.puts(record.merge(at: Time.now.utc.iso8601).to_json) }
    end

    # For a future log_viz "Memory" viewer, or manual digest re-derivation —
    # not on Session.play's hot path, which only ever needs digest_text.
    def session_records(last: nil)
      return [] unless File.exist?(raw_path)

      lines = File.readlines(raw_path)
      lines = lines.last(last) if last
      lines.map { |l| JSON.parse(l) }
    end

    private

    def digest_path = File.join(@memory_dir, "#{@player_name}.md")
    def raw_path    = File.join(@memory_dir, "#{@player_name}.jsonl")
  end
end
