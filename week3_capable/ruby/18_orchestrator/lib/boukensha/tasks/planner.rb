require_relative "base"

module Boukensha
  module Tasks
    # Pure reasoning over the goal (and, on a replan, the prior plan + Player
    # transcript tail) — no tools: block, so Tasks::Base.tool_policy denies
    # everything by default. See docs/plans/agent_loop/orchestrator.md §3.
    class Planner < Base
      def self.task_name = "planner"
    end
  end
end
