module Boukensha
  # Per-session/per-process memory of the Judge's own past verdicts — see
  # docs/plans/agent_loop/evaluator_judge_redesign.md §3. Owned by whoever
  # already owns checkpoint state (Session#play's local
  # turns_since_checkpoint, Repl's @turns_since_checkpoint), not part of
  # Context: Context#plan is Player-facing state rendered into
  # effective_system; JudgeMemory is Judge-facing and must never leak into
  # the Player's prompt.
  class JudgeMemory
    Entry = Struct.new(
      :turn, :stop_reason, :plan, :verdict, :reasoning,
      :repeated_actions, :overridden, keyword_init: true
    )

    def initialize(max_entries: 5)
      @max_entries = max_entries
      @entries     = []
    end

    def record(entry)
      @entries << entry
      @entries.shift while @entries.size > @max_entries
      entry
    end

    def entries = @entries.dup

    # Checkpoints since the plan text last changed — a cheap "how long has
    # this plan gone unchallenged" signal, independent of the LLM noticing.
    def checkpoints_on_current_plan(current_plan)
      streak = 0
      @entries.reverse_each do |e|
        break unless e.plan == current_plan

        streak += 1
      end
      streak
    end

    # Rendered for judge_input — see Boukensha.judge_input. Most recent
    # last, so it reads like a log, and stays within max_entries regardless
    # of session length.
    def to_prompt_text
      return nil if @entries.empty?

      @entries.map do |e|
        tag = e.overridden ? " [mechanically overridden]" : ""
        "- turn #{e.turn} (#{e.stop_reason}): VERDICT=#{e.verdict}#{tag} — #{e.reasoning}"
      end.join("\n")
    end
  end
end
