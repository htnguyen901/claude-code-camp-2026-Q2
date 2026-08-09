require_relative "helper"

# Config#memory_enabled?/#memory_dir — docs/plans/memory/player_memory.md
# decision 5. Defaults OFF, same posture as compactor_enabled? — an
# LLM-authored digest that's wrong can steer a future session's plan in the
# wrong direction, so this stays opt-in until evaluated.
class TestConfigMemory < Minitest::Test
  include McpTestHelper

  def test_memory_enabled_defaults_to_disabled_with_no_memory_block
    config_from("") { |cfg| refute cfg.memory_enabled? }
  end

  def test_memory_enabled_explicit_false_stays_disabled
    yaml = <<~YAML
      memory:
        enabled: false
    YAML
    config_from(yaml) { |cfg| refute cfg.memory_enabled? }
  end

  def test_memory_enabled_explicit_true_enables_it
    yaml = <<~YAML
      memory:
        enabled: true
    YAML
    config_from(yaml) { |cfg| assert cfg.memory_enabled? }
  end

  def test_memory_dir_defaults_to_memory_under_the_boukensha_dir
    config_from("") { |cfg| assert_equal File.join(cfg.dir, "memory"), cfg.memory_dir }
  end

  def test_memory_dir_honors_an_override
    yaml = <<~YAML
      memory:
        dir: player_notes
    YAML
    config_from(yaml) { |cfg| assert_equal File.join(cfg.dir, "player_notes"), cfg.memory_dir }
  end
end
