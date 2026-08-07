require_relative "helper"

# Tasks::Planner — docs/plans/agent_loop/orchestrator.md §3. Pure reasoning,
# no tools: it must never be able to act on the world, only produce plan text.
class TestTasksPlanner < Minitest::Test
  Planner = Boukensha::Tasks::Planner

  def test_task_name_is_planner
    assert_equal "planner", Planner.task_name
  end

  # Mirrors test_tasks_base_tool_policy.rb's deny-by-default case: no
  # `tools:` block in settings.yaml -> zero tools, the same fail-safe every
  # Tasks::Base subclass gets for free.
  def test_tool_policy_denies_every_tool_with_no_tools_block
    policy = Planner.tool_policy({})
    refute policy.allowed?("tbamud__look")
    refute policy.allowed?("room_knowledge")
  end

  # Even an explicit tools: block can't grant Planner anything under the
  # intended settings.yaml shape (orchestrator.md §3: "No tools: block in
  # its settings.yaml entry") — but the policy machinery itself is generic,
  # so prove intent by never configuring one, not by asserting Base can't do
  # something it deliberately still can.
  def test_default_prompts_dir_resolves_the_planner_scoped_prompt
    text = Planner.system_prompt({}, default_prompts_dir: Boukensha::Config::PROMPTS_DIR)
    assert_includes text, "Planner"
  end
end
