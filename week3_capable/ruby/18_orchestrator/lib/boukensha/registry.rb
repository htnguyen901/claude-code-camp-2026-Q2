require_relative "errors"
require_relative "tool_policy"

module Boukensha
  class Registry
    # policy: a ToolPolicy (or anything answering #allowed?(name)). Defaults
    # to allow-everything so a bare `Registry.new(ctx)` — tests, examples,
    # any caller that isn't a config-driven task — keeps today's behavior.
    # `Boukensha.run`/`.repl` pass a task-specific policy built from
    # settings.yaml's `tasks.<name>.tools` instead.
    def initialize(context, policy: ToolPolicy.new)
      @context = context
      @policy  = policy
      @denied  = {}
    end

    # Denied tools are never built or handed to @context — the model never
    # sees their schema at all (see docs/plans/tools_policy/permission.md,
    # Option D). Returns nil for a denied name rather than raising: a task
    # legitimately shouldn't crash just because its policy is narrower than
    # an MCP server's full catalog.
    def tool(name, description:, parameters: {}, &block)
      name = name.to_s

      unless @policy.allowed?(name)
        @denied[name] = true
        return nil
      end

      tool = Tool.new(name, description, parameters, block)
      @context.register_tool(tool)
      tool
    end

    def tool_names
      @context.tools.keys
    end

    def dispatch(name, args = {})
      name = name.to_s
      tool = @context.tools[name]

      if tool.nil?
        raise PermissionDeniedError, "Tool '#{name}' is not permitted for this task" if @denied[name]
        raise UnknownToolError, "No tool registered as '#{name}'"
      end

      tool.block.call(**args.transform_keys(&:to_sym))
    end
  end
end
