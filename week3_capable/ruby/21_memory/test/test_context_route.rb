require_relative "helper"

# Context#route / #effective_system — docs/plans/agent_loop/
# player_route_adherence.md §3b. The Navigator's route lives on the Context
# as a mutable field separate from `system` (fixed at construction) and
# `plan` (a sibling field) — `effective_system` folds it in as a
# "## Active Route" block, together with the fixed follow-it instruction,
# only when non-blank, so a session that never calls consult_navigator pays
# zero bytes for it.
class TestContextRoute < Minitest::Test
  def new_context
    Boukensha::Context.new(system: "You are an agent.")
  end

  def test_route_defaults_to_nil
    assert_nil new_context.route
  end

  def test_effective_system_equals_system_when_route_is_unset
    ctx = new_context
    assert_equal ctx.system, ctx.effective_system
  end

  def test_effective_system_equals_system_when_route_is_blank
    ctx = new_context
    ctx.route = "   "
    assert_equal ctx.system, ctx.effective_system
  end

  def test_effective_system_appends_active_route_block_when_route_is_set
    ctx = new_context
    ctx.route = "Route (2 hops) to The Reception:\n1. north\n2. up"

    assert_includes ctx.effective_system, "## Active Route"
    assert_includes ctx.effective_system, Boukensha::Context::ROUTE_INSTRUCTION
    assert_includes ctx.effective_system, "Route (2 hops) to The Reception:\n1. north\n2. up"
    assert_includes ctx.effective_system, Boukensha::Context::ROUTE_FOOTER
  end

  def test_effective_system_reflects_the_latest_route_assignment
    ctx = new_context
    ctx.route = "old route"
    ctx.route = "new route"

    assert_includes ctx.effective_system, "new route"
    refute_includes ctx.effective_system, "old route"
  end

  def test_effective_system_carries_both_plan_and_route_when_both_are_set
    ctx = new_context
    ctx.plan  = "1. Reach the temple square."
    ctx.route = "Route (1 hop) to The Temple Square:\n1. north"

    assert_includes ctx.effective_system, "## Current Plan"
    assert_includes ctx.effective_system, "## Active Route"
  end

  def test_route_survives_compaction
    ctx = new_context
    ctx.route = "Route (1 hop) to The Temple Square:\n1. north"

    20.times { |i| ctx.add_message(:user, "message #{i}") }
    ctx.current_tokens = (ctx.context_window * 0.9).to_i
    assert ctx.needs_compaction?
    ctx.compact_messages!

    assert_equal "Route (1 hop) to The Temple Square:\n1. north", ctx.route
    assert_includes ctx.effective_system, "Route (1 hop) to The Temple Square:\n1. north"
  end
end
