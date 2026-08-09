require_relative "helper"

# Logger#total_cost_usd — docs/plans/agent_loop/self_management.md §1. One
# Logger instance is shared across every task (Player, Planner, Judge,
# Navigator) for the whole session, so a running total here is automatically
# a true session-wide, all-tasks total.
class FakeCostBackend
  def initialize(cost)
    @cost = cost
  end

  def model
    "fake-model"
  end

  def provider_name
    "fake"
  end

  def estimate_cost(input_tokens:, output_tokens:)
    @cost
  end
end

class TestLoggerCost < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def new_logger
    Boukensha::Logger.new(dir: @dir, session_id: "test-session")
  end

  def test_starts_at_zero
    assert_equal 0.0, new_logger.total_cost_usd
  end

  def test_accumulates_across_responses_regardless_of_task
    logger = new_logger

    logger.response(text: "a", usage: { "input_tokens" => 1, "output_tokens" => 1 }, task: "player", backend: FakeCostBackend.new(0.10))
    logger.response(text: "b", usage: { "input_tokens" => 1, "output_tokens" => 1 }, task: "planner", backend: FakeCostBackend.new(0.05))
    logger.response(text: "c", usage: { "input_tokens" => 1, "output_tokens" => 1 }, task: "judge", backend: FakeCostBackend.new(0.02))

    assert_in_delta 0.17, logger.total_cost_usd
  end

  # A backend that can't estimate cost (e.g. free-tier Ollama, or a response
  # with no usage) contributes $0.0 — must never raise or be skipped as "no
  # response happened".
  def test_a_response_with_no_estimable_cost_does_not_change_the_total
    logger = new_logger

    logger.response(text: "a", usage: { "input_tokens" => 1, "output_tokens" => 1 }, task: "player", backend: nil)

    assert_equal 0.0, logger.total_cost_usd
  end
end
