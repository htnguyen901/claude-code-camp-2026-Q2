require_relative "../tool_policy"

module Boukensha
  module Tasks
    class Base
      DEFAULT_MAX_ITERATIONS = 25
      DEFAULT_MAX_OUTPUT_TOKENS = 1024

      def self.task_name
        raise NotImplementedError, "#{self} must define .task_name"
      end

      def self.provider(settings)
        fetch(settings, :provider) || raise(ArgumentError, "tasks.#{task_name}.provider is required in settings.yaml")
      end

      def self.model(settings)
        fetch(settings, :model) || raise(ArgumentError, "tasks.#{task_name}.model is required in settings.yaml")
      end

      def self.prompt_override?(settings, prompt = :system)
        node = fetch(settings, :prompt_override)
        return false unless node.is_a?(Hash)

        (node[prompt.to_s] || node[prompt.to_sym]) == true
      end

      def self.prompt(settings, name = :system, user_prompts_dir: nil, default_prompts_dir: nil)
        if prompt_override?(settings, name) && (text = read_user_prompt(name, user_prompts_dir: user_prompts_dir))
          return text
        end

        read_default_prompt(name, default_prompts_dir: default_prompts_dir)
      end

      def self.system_prompt(settings, user_prompts_dir: nil, default_prompts_dir: nil)
        prompt(settings, :system, user_prompts_dir: user_prompts_dir, default_prompts_dir: default_prompts_dir)
      end

      def self.max_iterations(settings)
        integer_setting(settings, :max_iterations, DEFAULT_MAX_ITERATIONS)
      end

      def self.max_output_tokens(settings)
        integer_setting(settings, :max_output_tokens, DEFAULT_MAX_OUTPUT_TOKENS)
      end

      # Builds this task's ToolPolicy from `tasks.<name>.tools`:
      #
      #   tools:
      #     role:  readonly       # expands to tool_roles["readonly"], resolved
      #                           # against Config#tool_roles, before allow:/deny:
      #     allow: [tbamud__list_commands]   # ad hoc additions on top of role:
      #     deny:  [tbamud__quit]            # always wins over allow on overlap
      #
      # No `tools:` block at all -> deny-by-default (an empty allow-list denies
      # every name): a new task that forgets to configure this gets zero
      # tools rather than silently inheriting everything an MCP server
      # advertises. See docs/plans/tools_policy/permission.md's "Default /
      # fail-safe" — Tasks::Player is expected to carry an explicit `role:
      # full` grant for exactly this reason.
      def self.tool_policy(settings, tool_roles: {})
        node = fetch(settings, :tools)
        return ToolPolicy.new(allow: []) unless node.is_a?(Hash)

        role_name = node["role"] || node[:role]
        allow     = role_name ? Array(tool_roles[role_name.to_s]).dup : []
        allow.concat(Array(node["allow"] || node[:allow]).map(&:to_s))

        ToolPolicy.new(allow: allow, deny: Array(node["deny"] || node[:deny]).map(&:to_s))
      end

      class << self
        private

        def fetch(settings, key)
          return nil unless settings.is_a?(Hash)

          settings[key.to_s] || settings[key.to_sym]
        end

        def integer_setting(settings, key, default)
          value = fetch(settings, key)
          return default if value.nil?

          Integer(value)
        end

        def read_user_prompt(prompt_name, user_prompts_dir: nil)
          return nil unless user_prompts_dir

          read_file(File.join(user_prompts_dir, task_name, "#{prompt_name}.md"))
        end

        def read_default_prompt(prompt_name, default_prompts_dir: nil)
          return nil unless default_prompts_dir

          read_file(File.join(default_prompts_dir, task_name, "#{prompt_name}.md"))
        end

        def read_file(path)
          File.exist?(path) ? File.read(path).strip : nil
        end
      end
    end
  end
end
