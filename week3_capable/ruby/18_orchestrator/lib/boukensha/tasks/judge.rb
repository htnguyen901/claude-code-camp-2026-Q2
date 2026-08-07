require_relative "base"

module Boukensha
  module Tasks
    # Read-only evaluator: fact-checks the Player's transcript against the
    # current plan (and, via tools, WorldKnowledge/room_knowledge) and
    # returns a continue/replan/flag verdict. `tools: { role: inspector }`
    # in settings.yaml — look/examine/consider/diagnose + room_knowledge,
    # never move/attack/quit/give. An evaluator that can act on the world
    # isn't an evaluator. See docs/plans/agent_loop/evaluator.md §1.
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
    end
  end
end
