require_relative "helper"

# `tool_roles:` in settings.yaml is the reusable-role layer on top of
# Boukensha::ToolPolicy's glob matcher — see docs/plans/tools_policy/
# permission.md, Option C.
class TestToolRolesConfig < Minitest::Test
  include McpTestHelper

  def test_parses_named_roles_into_glob_arrays
    yaml = <<~YAML
      tool_roles:
        readonly: [tbamud__look, tbamud__examine, room_knowledge]
        full: ["*"]
    YAML

    config_from(yaml) do |cfg|
      assert_equal(
        { "readonly" => %w[tbamud__look tbamud__examine room_knowledge], "full" => ["*"] },
        cfg.tool_roles
      )
    end
  end

  def test_absent_block_is_empty
    config_from("tasks: {}") { |cfg| assert_equal({}, cfg.tool_roles) }
  end
end
