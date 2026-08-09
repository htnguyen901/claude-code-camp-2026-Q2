require_relative "helper"

# Config#planner_enabled? — docs/plans/agent_loop/repl_planner_integration.md.
# Defaults ON (unlike compactor_enabled?/observability_enabled?'s own
# defaults) — this is the deliberate reversal of high_level_agentic_loop_
# design.md's "Alternative B".
class TestConfigPlanner < Minitest::Test
  include McpTestHelper

  def test_defaults_to_enabled_with_no_tasks_planner_block
    config_from("tasks: {}") { |cfg| assert cfg.planner_enabled? }
  end

  def test_defaults_to_enabled_with_no_settings_at_all
    config_from("") { |cfg| assert cfg.planner_enabled? }
  end

  def test_explicit_false_disables_it
    yaml = <<~YAML
      tasks:
        planner:
          enabled: false
    YAML
    config_from(yaml) { |cfg| refute cfg.planner_enabled? }
  end

  def test_explicit_true_is_still_enabled
    yaml = <<~YAML
      tasks:
        planner:
          enabled: true
    YAML
    config_from(yaml) { |cfg| assert cfg.planner_enabled? }
  end
end
