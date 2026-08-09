require_relative "helper"

# Tasks::Judge — docs/plans/agent_loop/evaluator.md §1, reworked by
# agents_tools/tool_scope_rework.md §0/§2 into an overall mentor, not a
# gameplay coach: role: world_knowledge (room_knowledge only) plus
# consult_navigator for path-specific reasoning, never
# look/examine/shop/consume/consider/diagnose (the Player's responsibility)
# and never move/attack/quit/give — an evaluator that can act on the world
# isn't one.
class TestTasksJudge < Minitest::Test
  Judge = Boukensha::Tasks::Judge

  WORLD_KNOWLEDGE_ROLE = %w[room_knowledge].freeze

  def test_task_name_is_judge
    assert_equal "judge", Judge.task_name
  end

  def test_default_prompts_dir_resolves_the_judge_scoped_prompt
    text = Judge.system_prompt({}, default_prompts_dir: Boukensha::Config::PROMPTS_DIR)
    assert_includes text, "Judge"
    assert_includes text, "VERDICT"
  end

  def test_role_world_knowledge_allows_room_facts_and_denies_action_and_perception_tools
    settings   = { "tools" => { "role" => "world_knowledge" } }
    tool_roles = { "world_knowledge" => WORLD_KNOWLEDGE_ROLE }

    policy = Judge.tool_policy(settings, tool_roles: tool_roles)
    assert policy.allowed?("room_knowledge")

    refute policy.allowed?("tbamud__look")
    refute policy.allowed?("tbamud__examine")
    refute policy.allowed?("tbamud__move")
    refute policy.allowed?("tbamud__attack")
    refute policy.allowed?("tbamud__quit")
    refute policy.allowed?("tbamud__give")
  end

  def test_no_tools_block_denies_everything
    policy = Judge.tool_policy({})
    refute policy.allowed?("tbamud__look")
    refute policy.allowed?("room_knowledge")
  end

  def test_max_iterations_defaults_to_a_handful
    assert_equal 5, Judge.max_iterations({})
  end

  def test_max_iterations_honors_an_explicit_settings_value
    assert_equal 3, Judge.max_iterations({ "max_iterations" => 3 })
  end
end
