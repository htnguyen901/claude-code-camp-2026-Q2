require_relative "helper"

# Boukensha.session_budget_status(logger, cfg) — docs/plans/agent_loop/
# self_management.md §1's session-wide cost governor.
class TestSessionBudgetStatus < Minitest::Test
  include McpTestHelper

  FakeLogger = Struct.new(:total_cost_usd)

  def test_ok_when_no_budget_is_configured
    config_from("") do |cfg|
      assert_equal :ok, Boukensha.session_budget_status(FakeLogger.new(999.0), cfg)
    end
  end

  def test_ok_when_budget_is_zero
    yaml = <<~YAML
      session:
        max_cost_usd: 0
    YAML
    config_from(yaml) do |cfg|
      assert_equal :ok, Boukensha.session_budget_status(FakeLogger.new(999.0), cfg)
    end
  end

  def test_ok_below_the_warn_threshold
    yaml = <<~YAML
      session:
        max_cost_usd: 10.0
        cost_warn_pct: 0.8
    YAML
    config_from(yaml) do |cfg|
      assert_equal :ok, Boukensha.session_budget_status(FakeLogger.new(7.99), cfg)
    end
  end

  def test_warn_at_or_above_the_warn_threshold
    yaml = <<~YAML
      session:
        max_cost_usd: 10.0
        cost_warn_pct: 0.8
    YAML
    config_from(yaml) do |cfg|
      assert_equal :warn, Boukensha.session_budget_status(FakeLogger.new(8.0), cfg)
    end
  end

  def test_exhausted_at_or_above_the_budget
    yaml = <<~YAML
      session:
        max_cost_usd: 10.0
    YAML
    config_from(yaml) do |cfg|
      assert_equal :exhausted, Boukensha.session_budget_status(FakeLogger.new(10.0), cfg)
      assert_equal :exhausted, Boukensha.session_budget_status(FakeLogger.new(15.0), cfg)
    end
  end
end
