require_relative "helper"

# docs/plans/agent_loop/log_viz_visibility.md: every entry type log_viz
# renders in the Iteration view should carry `task` once the underlying
# Logger events do, so a Planner/Judge/subagent chunk can be visually
# distinguished from Player activity — not just present in cost_breakdown.
class TestSessionTask < Minitest::Test
  include SessionTestHelper

  def tool_call_event(name:, args: {}, task: nil)
    { phase: "tool_call", name: name, args: args, task: task, session_id: "test-session", at: Time.now.iso8601 }
  end

  def tool_result_event(name:, result:, ok: true, task: nil)
    { phase: "tool_result", name: name, result: result, ok: ok, task: task,
      session_id: "test-session", at: Time.now.iso8601 }
  end

  def reasoning_event(text:, task: nil)
    { phase: "reasoning", text: text, redacted: false, task: task, session_id: "test-session", at: Time.now.iso8601 }
  end

  def plan_event(text:, task: nil)
    { phase: "plan", text: text, task: task, session_id: "test-session", at: Time.now.iso8601 }
  end

  def test_request_entry_carries_task
    path = write_session([
      session_start_event(provider: "openai"),
      request_event(payload: { model: "m", input: [] }, task: "planner")
    ])

    entry = LogViz::Session.load(path).entries.find { |e| e.type == :request }
    assert_equal "planner", entry.task
  end

  def test_user_entry_carries_task_from_its_request
    path = write_session([
      session_start_event(provider: "openai"),
      request_event(payload: { model: "m", input: [] }, task: "player", last_user_text: "explore the temple")
    ])

    entry = LogViz::Session.load(path).entries.find { |e| e.type == :user }
    assert_equal "player", entry.task
  end

  def test_reasoning_and_plan_entries_carry_task
    path = write_session([
      session_start_event(provider: "openai"),
      reasoning_event(text: "hmm", task: "judge"),
      plan_event(text: "about to look", task: "player")
    ])

    entries = LogViz::Session.load(path).entries
    assert_equal "judge", entries.find { |e| e.type == :reasoning }.task
    assert_equal "player", entries.find { |e| e.type == :plan }.task
  end

  def test_tool_entry_carries_task_from_tool_result
    path = write_session([
      session_start_event(provider: "openai"),
      tool_call_event(name: "room_knowledge", task: "judge"),
      tool_result_event(name: "room_knowledge", result: "examined: none", task: "judge")
    ])

    entry = LogViz::Session.load(path).entries.find { |e| e.type == :tool }
    assert_equal "judge", entry.task
  end

  # Older logs (or any event type this doc deliberately didn't touch —
  # compaction/turn_end/injected) simply have no `task` key at all; parsing
  # must not blow up, and the entry's task should read back nil, not "".
  def test_missing_task_reads_back_as_nil_not_a_blank_string
    path = write_session([
      session_start_event(provider: "openai"),
      request_event(payload: { model: "m", input: [] })
    ])

    entry = LogViz::Session.load(path).entries.find { |e| e.type == :request }
    assert_nil entry.task
  end

  # task_names (index.erb's "Task" column, and task_marker/task_color's
  # coloring source) must reflect every entry type now, not just response
  # events — a session where the Planner only ever produced a request (e.g.
  # truncated mid-call) still needs to show up.
  def test_task_names_reflects_every_entry_type_not_just_responses
    path = write_session([
      session_start_event(provider: "openai"),
      request_event(payload: { model: "m", input: [] }, task: "planner"),
      reasoning_event(text: "hmm", task: "judge")
    ])

    assert_equal %w[planner judge], LogViz::Session.load(path).task_names
  end

  def test_task_names_is_empty_for_a_session_with_no_task_tagged_events
    path = write_session([
      session_start_event(provider: "openai"),
      request_event(payload: { model: "m", input: [] })
    ])

    assert_empty LogViz::Session.load(path).task_names
  end
end
