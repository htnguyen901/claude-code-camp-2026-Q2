require_relative "base"

module Boukensha
  module Tasks
    # Reflects on one finished Session.play run and rewrites that player's
    # memory digest. Never given tools — it reasons over the goal, the
    # session's outcome, and its own prior digest, never the live game or
    # world_knowledge (see docs/plans/memory/player_memory.md decision 3).
    # No tasks.chronicler.tools block in settings.yaml -> Tasks::Base.
    # tool_policy denies everything, same default Tasks::Planner relies on.
    class Chronicler < Base
      def self.task_name = "chronicler"
    end
  end
end
