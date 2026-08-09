require_relative "helper"

# Boukensha::JudgeMemory — docs/plans/agent_loop/evaluator_judge_redesign.md
# §3. A small, bounded log of the Judge's own past verdicts, owned by the
# driver (Session/Repl), never by Context.
class TestJudgeMemory < Minitest::Test
  Entry = Boukensha::JudgeMemory::Entry

  def entry(turn:, plan: "1. Find food.", verdict: :continue, overridden: false)
    Entry.new(turn: turn, stop_reason: :max_iterations, plan: plan, verdict: verdict,
              reasoning: "some reasoning", repeated_actions: {}, overridden: overridden)
  end

  def test_to_prompt_text_is_nil_when_empty
    memory = Boukensha::JudgeMemory.new
    assert_nil memory.to_prompt_text
  end

  def test_record_keeps_only_the_most_recent_max_entries
    memory = Boukensha::JudgeMemory.new(max_entries: 2)
    memory.record(entry(turn: 1))
    memory.record(entry(turn: 2))
    memory.record(entry(turn: 3))

    assert_equal [2, 3], memory.entries.map(&:turn)
  end

  def test_entries_returns_a_copy_not_the_live_array
    memory = Boukensha::JudgeMemory.new
    memory.record(entry(turn: 1))
    memory.entries << entry(turn: 99)

    assert_equal [1], memory.entries.map(&:turn)
  end

  def test_to_prompt_text_renders_most_recent_last_and_tags_overrides
    memory = Boukensha::JudgeMemory.new
    memory.record(entry(turn: 1, verdict: :continue, overridden: false))
    memory.record(entry(turn: 2, verdict: :replan, overridden: true))

    text = memory.to_prompt_text
    assert_includes text, "turn 1"
    assert_includes text, "VERDICT=continue"
    assert_includes text, "turn 2"
    assert_includes text, "VERDICT=replan"
    assert_includes text, "[mechanically overridden]"
    assert text.index("turn 1") < text.index("turn 2"), "most recent entry must render last"
  end

  def test_checkpoints_on_current_plan_counts_the_trailing_streak_of_matching_plans
    memory = Boukensha::JudgeMemory.new
    memory.record(entry(turn: 1, plan: "plan A"))
    memory.record(entry(turn: 2, plan: "plan B"))
    memory.record(entry(turn: 3, plan: "plan B"))
    memory.record(entry(turn: 4, plan: "plan B"))

    assert_equal 3, memory.checkpoints_on_current_plan("plan B")
    assert_equal 0, memory.checkpoints_on_current_plan("plan C")
  end
end
