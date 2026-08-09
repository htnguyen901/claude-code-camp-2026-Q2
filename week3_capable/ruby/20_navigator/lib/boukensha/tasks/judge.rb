require_relative "base"

module Boukensha
  module Tasks
    # Read-only overall mentor, not a gameplay coach: fact-checks the
    # Player's transcript against the current plan (via world__room_knowledge
    # and, for path-specific reasoning, the consult_navigator tool) and
    # returns a continue/replan/flag verdict. `tools: { role: world_knowledge,
    # allow: [consult_navigator] }` in settings.yaml — never
    # look/examine/shop/consume/consider/diagnose (the Player's
    # responsibility) and never move/attack/quit/give. An evaluator that can
    # act on the world isn't an evaluator. See
    # docs/plans/agent_loop/evaluator.md §1 and
    # docs/plans/agent_loop/agents_tools/tool_scope_rework.md §0.
    class Judge < Base
      def self.task_name = "judge"

      # "Check a couple of facts, then decide" (evaluator.md §2), not another
      # open-ended play loop — a lower default than Base's 25.
      # `tasks.judge.max_iterations` in settings.yaml still overrides this.
      DEFAULT_MAX_ITERATIONS = 5

      def self.max_iterations(settings)
        value = fetch(settings, :max_iterations)
        value.nil? ? DEFAULT_MAX_ITERATIONS : Integer(value)
      end

      # Tuning knobs for Boukensha.repeated_tool_calls (evaluator_judge_
      # redesign.md §5) — starting guesses, not fixed constants:
      # window matches transcript_tail's own `last: 20` default, so the two
      # stay consistent about "how far back is recent"; threshold of 3
      # avoids flagging a legitimate short retry (two repeats) as a loop.
      DEFAULT_REPEATED_ACTION_WINDOW    = 20
      DEFAULT_REPEATED_ACTION_THRESHOLD = 3

      def self.repeated_action_window(settings)
        value = fetch(settings, :repeated_action_window)
        value.nil? ? DEFAULT_REPEATED_ACTION_WINDOW : Integer(value)
      end

      def self.repeated_action_threshold(settings)
        value = fetch(settings, :repeated_action_threshold)
        value.nil? ? DEFAULT_REPEATED_ACTION_THRESHOLD : Integer(value)
      end
    end
  end
end
