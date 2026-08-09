require_relative "helper"

# Context#compact_messages!/#checkpoint_trim! pairing safety — docs/plans/
# memory/context_lifecycle.md §2/§3b/§3c. Both trims share the same
# boundary-aware drop logic: a naive "drop the oldest/keep the newest N"
# count gets nudged to the nearest point that doesn't land inside a
# tool_use-bearing :assistant message and its own :tool_result(s)
# (Agent#handle_tool_calls always adds one such assistant message followed
# immediately by one :tool_result per tool_use block) — otherwise a trimmed
# payload could carry an orphaned :tool_result whose tool_use_id matches
# nothing still in the conversation, which every backend is likely to reject
# as malformed.
class TestContext < Minitest::Test
  def new_context
    Boukensha::Context.new(system: "You are an agent.")
  end

  # Appends one tool-use round: an :assistant message carrying `calls.size`
  # tool_use blocks, immediately followed by one :tool_result per call —
  # exactly the shape Agent#handle_tool_calls produces.
  def add_tool_round(ctx, calls)
    content = calls.map { |c| { "type" => "tool_use", "name" => c[:name], "input" => c[:args] || {}, "id" => c[:id] } }
    ctx.add_message(:assistant, content)
    calls.each { |c| ctx.add_message(:tool_result, "result for #{c[:name]}", tool_use_id: c[:id]) }
  end

  # 10 messages, indices 0-9. Index 3 is a 2-call tool_use round (indices
  # 3, 4, 5): assistant + its two tool_results — the group a naive drop
  # count could land inside.
  def build_context_with_a_tool_use_group
    ctx = new_context
    ctx.add_message(:user, "u0")
    ctx.add_message(:assistant, "a0")
    ctx.add_message(:user, "u1")
    add_tool_round(ctx, [{ name: "look", id: "tu1" }, { name: "listen", id: "tu2" }])
    ctx.add_message(:assistant, "a1")
    ctx.add_message(:user, "u2")
    ctx.add_message(:assistant, "a2")
    ctx.add_message(:user, "u3")
    ctx
  end

  def assert_no_orphaned_tool_results(messages)
    seen_tool_use_ids = []
    messages.each do |m|
      if m.role == :assistant && m.content.is_a?(Array)
        seen_tool_use_ids.concat(m.content.select { |b| b["type"] == "tool_use" }.map { |b| b["id"] })
      elsif m.role == :tool_result
        assert_includes seen_tool_use_ids, m.tool_use_id, "orphaned tool_result #{m.tool_use_id.inspect} with no matching tool_use earlier in the kept messages"
      end
    end
  end

  # The naive 40%-of-10 drop count is 4, which lands strictly inside the
  # tool_use group at indices 3..5 (assistant + 2 tool_results) — the exact
  # bug docs/plans/memory/context_lifecycle.md §2 describes. The fix must
  # move the cut to the nearest group boundary instead (here: index 3,
  # keeping the whole group) rather than slicing it in half.
  def test_compact_messages_never_splits_a_tool_use_group
    ctx = build_context_with_a_tool_use_group
    dropped = ctx.compact_messages!

    assert_equal 3, dropped, "cut moved from the naive 4 to the group's own boundary at index 3"
    assert_equal 7, ctx.messages.size
    assert_no_orphaned_tool_results(ctx.messages)

    first = ctx.messages.first
    assert_equal :assistant, first.role
    assert_equal 2, first.content.count { |b| b["type"] == "tool_use" }
  end

  # A fixture for compact_messages! itself (the 85%-threshold path, no
  # checkpoint involved) confirming the fix at the source.
  def test_compact_messages_is_a_no_op_regression_when_no_group_is_split
    ctx = new_context
    10.times { |i| ctx.add_message(:user, "u#{i}") }
    dropped = ctx.compact_messages!

    assert_equal 4, dropped, "no tool_use groups at all — behaves exactly like the pre-fix naive drop count"
    assert_equal 6, ctx.messages.size
  end

  def test_compact_messages_keeps_at_least_two_messages
    ctx = new_context
    3.times { |i| ctx.add_message(:user, "u#{i}") }
    ctx.compact_messages!

    assert_equal 2, ctx.messages.size
  end

  def test_compact_messages_resets_current_tokens
    ctx = new_context
    10.times { |i| ctx.add_message(:user, "u#{i}") }
    ctx.update_tokens(50_000)
    ctx.compact_messages!

    assert_equal 0, ctx.current_tokens
  end

  # Checkpoint-triggered trim (§3b): naive "keep the last 5 of 10" drops the
  # oldest 5, which would land at index 5 — the middle of the same tool_use
  # group (indices 3..5). The fix must round to the nearest boundary; here
  # that means dropping the whole group (index 6) rather than orphaning its
  # tool_results.
  def test_checkpoint_trim_never_splits_a_tool_use_group
    ctx = build_context_with_a_tool_use_group
    dropped = ctx.checkpoint_trim!(tail: 5)

    assert_equal 6, dropped
    assert_equal 4, ctx.messages.size
    assert_no_orphaned_tool_results(ctx.messages)
    refute ctx.messages.any? { |m| m.role == :assistant && m.content.is_a?(Array) }, "the whole tool_use round was dropped, not half of it"
  end

  def test_checkpoint_trim_is_a_no_op_when_already_within_the_tail
    ctx = new_context
    3.times { |i| ctx.add_message(:user, "u#{i}") }
    dropped = ctx.checkpoint_trim!(tail: 20)

    assert_equal 0, dropped
    assert_equal 3, ctx.messages.size
  end

  def test_checkpoint_trim_keeps_only_the_most_recent_tail_messages
    ctx = new_context
    10.times { |i| ctx.add_message(:user, "u#{i}") }
    ctx.checkpoint_trim!(tail: 4)

    assert_equal 4, ctx.messages.size
    assert_equal "u6", ctx.messages.first.content
    assert_equal "u9", ctx.messages.last.content
  end

  # docs/plans/agent_loop/player_route_adherence.md §3b's whole point:
  # ctx.plan/ctx.route live in @system (via effective_system), never in
  # @messages, so neither trim can touch them.
  def test_checkpoint_trim_never_touches_plan_or_route
    ctx = build_context_with_a_tool_use_group
    ctx.plan  = "1. Reach the temple square."
    ctx.route = "Route (1 hop) to The Temple Square:\n1. north"

    ctx.checkpoint_trim!(tail: 2)

    assert_equal "1. Reach the temple square.", ctx.plan
    assert_equal "Route (1 hop) to The Temple Square:\n1. north", ctx.route
    assert_includes ctx.effective_system, "## Current Plan"
    assert_includes ctx.effective_system, "## Active Route"
  end
end
