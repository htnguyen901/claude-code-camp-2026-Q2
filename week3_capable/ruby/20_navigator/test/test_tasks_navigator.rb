require_relative "helper"

# Tasks::Navigator — docs/plans/agent_loop/navigator.md §1, reworked by
# agents_tools/tool_scope_rework.md §0/§3 into a read-only route finder:
# role: navigator (world__room_knowledge/route_to only), never
# tbamud__move/look/attack/give — it answers whether a path exists, it
# doesn't walk it.
class TestTasksNavigator < Minitest::Test
  Navigator = Boukensha::Tasks::Navigator

  NAVIGATOR_ROLE = %w[world__room_knowledge world__route_to].freeze

  def test_task_name_is_navigator
    assert_equal "navigator", Navigator.task_name
  end

  def test_default_prompts_dir_resolves_the_navigator_scoped_prompt
    text = Navigator.system_prompt({}, default_prompts_dir: Boukensha::Config::PROMPTS_DIR)
    assert_includes text, "Navigator"
    assert_includes text, "world__route_to"
  end

  def test_role_navigator_allows_route_tools_and_denies_everything_else
    settings   = { "tools" => { "role" => "navigator" } }
    tool_roles = { "navigator" => NAVIGATOR_ROLE }

    policy = Navigator.tool_policy(settings, tool_roles: tool_roles)
    assert policy.allowed?("world__room_knowledge")
    assert policy.allowed?("world__route_to")

    refute policy.allowed?("tbamud__move")
    refute policy.allowed?("tbamud__look")
    refute policy.allowed?("tbamud__attack")
    refute policy.allowed?("tbamud__examine")
    refute policy.allowed?("tbamud__give")
  end

  def test_no_tools_block_denies_everything
    policy = Navigator.tool_policy({})
    refute policy.allowed?("tbamud__move")
    refute policy.allowed?("world__route_to")
  end

  def test_max_iterations_defaults_to_a_handful
    assert_equal 4, Navigator.max_iterations({})
  end

  def test_max_iterations_honors_an_explicit_settings_value
    assert_equal 2, Navigator.max_iterations({ "max_iterations" => 2 })
  end
end
