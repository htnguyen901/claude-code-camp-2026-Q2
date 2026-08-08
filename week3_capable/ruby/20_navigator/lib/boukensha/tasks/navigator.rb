require_relative "base"

module Boukensha
  module Tasks
    # Read-only route finder: given a destination room title and the
    # caller's own current room title, answers whether there's a known path
    # between them over already-discovered edges (world__route_to) and
    # describes it. Never given tbamud__move or tbamud__look — it answers
    # whether a path exists, it doesn't walk it, and it's deliberately fed
    # "where am I" by its caller instead of re-observing it itself. See
    # docs/plans/agent_loop/navigator.md §3 and
    # docs/plans/agent_loop/agents_tools/tool_scope_rework.md §0/§3.
    # `tools: { role: navigator }` in settings.yaml —
    # world__room_knowledge/route_to, nothing else (no move/attack/examine/
    # give — a route finder, not a second Player).
    class Navigator < Base
      def self.task_name = "navigator"

      # A handful of tool calls to answer one question ("is there a known
      # path, and what is it?"), not open-ended play — same posture as
      # Judge's small ceiling (evaluator.md §1), just sized for a route
      # lookup instead of "check a couple of facts."
      # tasks.navigator.max_iterations in settings.yaml still overrides this.
      DEFAULT_MAX_ITERATIONS = 4

      def self.max_iterations(settings)
        value = fetch(settings, :max_iterations)
        value.nil? ? DEFAULT_MAX_ITERATIONS : Integer(value)
      end
    end
  end
end
