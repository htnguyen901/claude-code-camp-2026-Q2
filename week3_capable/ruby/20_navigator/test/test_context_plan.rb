require_relative "helper"

# Context#plan / #effective_system — docs/plans/agent_loop/orchestrator.md §2.
# The Planner's output lives on the Context as a mutable field separate from
# `system` (fixed at construction); `effective_system` is what backends must
# read so the Player sees the current plan on every iteration.
class TestContextPlan < Minitest::Test
  def new_context
    Boukensha::Context.new(system: "You are an agent.")
  end

  def test_plan_defaults_to_nil
    assert_nil new_context.plan
  end

  def test_effective_system_equals_system_when_plan_is_unset
    ctx = new_context
    assert_equal ctx.system, ctx.effective_system
  end

  def test_effective_system_equals_system_when_plan_is_blank
    ctx = new_context
    ctx.plan = "   "
    assert_equal ctx.system, ctx.effective_system
  end

  def test_effective_system_appends_current_plan_block_when_plan_is_set
    ctx = new_context
    ctx.plan = "1. Reach the temple square.\n2. Talk to the priest."

    assert_equal "You are an agent.\n\n## Current Plan\n1. Reach the temple square.\n2. Talk to the priest.",
                 ctx.effective_system
  end

  def test_effective_system_reflects_the_latest_assignment
    ctx = new_context
    ctx.plan = "old plan"
    ctx.plan = "new plan"

    assert_includes ctx.effective_system, "new plan"
    refute_includes ctx.effective_system, "old plan"
  end
end
