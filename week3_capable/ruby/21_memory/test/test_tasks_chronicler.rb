require_relative "helper"

# Tasks::Chronicler — docs/plans/memory/player_memory.md decision 3. Pure
# reflection, no tools: it must never be able to act on the world or query
# world_knowledge, only rewrite a memory digest from what's given to it.
class TestTasksChronicler < Minitest::Test
  Chronicler = Boukensha::Tasks::Chronicler

  def test_task_name_is_chronicler
    assert_equal "chronicler", Chronicler.task_name
  end

  # Mirrors test_tasks_planner.rb's deny-by-default case: no `tools:` block
  # in settings.yaml -> zero tools, the same fail-safe every Tasks::Base
  # subclass gets for free.
  def test_tool_policy_denies_every_tool_with_no_tools_block
    policy = Chronicler.tool_policy({})
    refute policy.allowed?("tbamud__look")
    refute policy.allowed?("world__room_knowledge")
  end

  # Even an explicit tools: block can't grant Chronicler anything under the
  # intended settings.yaml shape (no tasks.chronicler.tools block at all) —
  # but the policy machinery itself is generic, so prove intent by never
  # configuring one, not by asserting Base can't do something it
  # deliberately still can.
  def test_default_prompts_dir_resolves_the_chronicler_scoped_prompt
    text = Chronicler.system_prompt({}, default_prompts_dir: Boukensha::Config::PROMPTS_DIR)
    assert_includes text, "Chronicler"
  end

  # docs/plans/agent_loop/capability/resource_bootstrap.md §6 — a checkpoint's
  # stated intent must not be promoted to a Strategy unless the transcript
  # actually shows it succeeded; this was the dina.md incident's root cause.
  def test_default_prompts_dir_requires_proven_success_before_a_strategy
    text = Chronicler.system_prompt({}, default_prompts_dir: Boukensha::Config::PROMPTS_DIR)
    assert_includes text, "actually succeeded"
    assert_includes text, "Mistakes"
  end
end
