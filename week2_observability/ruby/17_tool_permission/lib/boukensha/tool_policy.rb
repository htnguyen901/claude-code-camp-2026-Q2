module Boukensha
  # Answers "can this task's model see/call this tool name?" — a static,
  # config-declared allow/deny list matched with shell-glob patterns
  # (File.fnmatch), e.g. "tbamud__say_*" or "*". `deny` always wins over
  # `allow` on overlap: an explicit refusal should never be shadowed by a
  # broader allow glob.
  #
  # The default policy (no args) allows everything — this is what a bare
  # `Registry.new(ctx)` gets, preserving pre-policy behavior for tests,
  # examples, and any other caller that isn't a config-driven task.
  # `Boukensha.run`/`.repl` instead build one from `Tasks::Base.tool_policy`,
  # which defaults to deny-all when a task has no `tools:` block configured
  # (see docs/plans/tools_policy/permission.md's "Default / fail-safe").
  class ToolPolicy
    def initialize(allow: ["*"], deny: [])
      @allow = Array(allow).map(&:to_s)
      @deny  = Array(deny).map(&:to_s)
    end

    def allowed?(name)
      name = name.to_s
      return false if matches?(@deny, name)

      matches?(@allow, name)
    end

    private

    def matches?(patterns, name)
      patterns.any? { |pattern| File.fnmatch?(pattern, name) }
    end
  end
end
