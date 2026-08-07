require_relative "helper"

# Config#judge_enabled? — docs/plans/agent_loop/repl_judge_integration.md.
# Defaults ON, same reversed-default convention as planner_enabled?.
class TestConfigJudge < Minitest::Test
  include McpTestHelper

  def test_defaults_to_enabled_with_no_tasks_judge_block
    config_from("tasks: {}") { |cfg| assert cfg.judge_enabled? }
  end

  def test_defaults_to_enabled_with_no_settings_at_all
    config_from("") { |cfg| assert cfg.judge_enabled? }
  end

  def test_explicit_false_disables_it
    yaml = <<~YAML
      tasks:
        judge:
          enabled: false
    YAML
    config_from(yaml) { |cfg| refute cfg.judge_enabled? }
  end

  def test_explicit_true_is_still_enabled
    yaml = <<~YAML
      tasks:
        judge:
          enabled: true
    YAML
    config_from(yaml) { |cfg| assert cfg.judge_enabled? }
  end
end
