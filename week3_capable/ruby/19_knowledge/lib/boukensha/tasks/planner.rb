require_relative "base"

module Boukensha
  module Tasks
    # Reasons over the goal (and, on a replan, the prior plan + Player
    # transcript tail). Tools are configured the same way as every other
    # task — `tasks.planner.tools` in settings.yaml — and default to
    # deny-everything only because Tasks::Base.tool_policy denies-by-default
    # when that block is omitted, not because Planner special-cases itself
    # out of tools anywhere in code. See
    # docs/plans/agent_loop/orchestrator.md §3.
    class Planner < Base
      def self.task_name = "planner"
    end
  end
end
