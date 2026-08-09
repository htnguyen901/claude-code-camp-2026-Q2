require_relative "helper"

# Config#self_manage?/#session_max_cost_usd/#session_cost_warn_pct —
# docs/plans/agent_loop/self_management.md §1/§3.
class TestConfigSession < Minitest::Test
  include McpTestHelper

  # Unlike planner_enabled?/judge_enabled?, self_manage? defaults OFF — it
  # changes the execution model (unattended tool-calling) rather than adding
  # an advisory round trip.
  def test_self_manage_defaults_to_disabled
    config_from("") { |cfg| refute cfg.self_manage? }
  end

  def test_self_manage_explicit_true_enables_it
    yaml = <<~YAML
      session:
        self_manage: true
    YAML
    config_from(yaml) { |cfg| assert cfg.self_manage? }
  end

  def test_session_max_cost_usd_defaults_to_nil
    config_from("") { |cfg| assert_nil cfg.session_max_cost_usd }
  end

  def test_session_max_cost_usd_zero_disables_it
    yaml = <<~YAML
      session:
        max_cost_usd: 0
    YAML
    config_from(yaml) { |cfg| assert_nil cfg.session_max_cost_usd }
  end

  def test_session_max_cost_usd_reads_a_positive_value
    yaml = <<~YAML
      session:
        max_cost_usd: 5.00
    YAML
    config_from(yaml) { |cfg| assert_in_delta 5.00, cfg.session_max_cost_usd }
  end

  def test_session_cost_warn_pct_defaults_to_0_85
    config_from("") { |cfg| assert_in_delta 0.85, cfg.session_cost_warn_pct }
  end

  def test_session_cost_warn_pct_reads_an_override
    yaml = <<~YAML
      session:
        cost_warn_pct: 0.5
    YAML
    config_from(yaml) { |cfg| assert_in_delta 0.5, cfg.session_cost_warn_pct }
  end
end
