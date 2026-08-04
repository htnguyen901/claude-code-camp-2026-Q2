require_relative "helper"
require "log_viz/settings"

# `.boukensha/settings.yaml`'s `tasks.content_fact` block — the content-fact
# subtask's config, mirroring `tasks.player`'s shape (see
# docs/plans/observability/room_world_inspector.md). Unlike
# Boukensha::Tasks::Base#provider/#model (which raise if missing —
# Player has no sensible default), this must never raise: log_viz has to
# keep working with zero configuration.
class TestSettings < Minitest::Test
  def setup
    @tmp_dir      = Dir.mktmpdir
    @sessions_dir = File.join(@tmp_dir, "sessions")
    FileUtils.mkdir_p(@sessions_dir)
    @settings_path = File.join(@tmp_dir, "settings.yaml")
    @prior_ollama_host = ENV.delete("OLLAMA_HOST")
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir)
    ENV["OLLAMA_HOST"] = @prior_ollama_host if @prior_ollama_host
  end

  def write_settings(yaml_text)
    File.write(@settings_path, yaml_text)
  end

  def test_boukensha_dir_is_the_sessions_dirs_parent
    assert_equal @tmp_dir, LogViz::Settings.boukensha_dir(@sessions_dir)
  end

  def test_defaults_when_no_settings_file_exists
    assert_equal "ollama", LogViz::Settings.content_fact_provider(@sessions_dir)
    assert_equal "gemma4", LogViz::Settings.content_fact_model(@sessions_dir)
    assert_equal "http://localhost:11434", LogViz::Settings.content_fact_host(@sessions_dir)
  end

  def test_reads_tasks_content_fact_block
    write_settings(<<~YAML)
      tasks:
        content_fact:
          provider: ollama
          model: qwen3:8b
          host: http://ollama.local:11434
    YAML

    assert_equal "ollama", LogViz::Settings.content_fact_provider(@sessions_dir)
    assert_equal "qwen3:8b", LogViz::Settings.content_fact_model(@sessions_dir)
    assert_equal "http://ollama.local:11434", LogViz::Settings.content_fact_host(@sessions_dir)
  end

  def test_missing_content_fact_block_falls_back_to_defaults
    write_settings(<<~YAML)
      tasks:
        player:
          provider: openai
          model: gpt-5.4-mini
    YAML

    assert_equal "ollama", LogViz::Settings.content_fact_provider(@sessions_dir)
    assert_equal "gemma4", LogViz::Settings.content_fact_model(@sessions_dir)
  end

  def test_ollama_host_env_var_wins_over_settings_yaml_host
    write_settings(<<~YAML)
      tasks:
        content_fact:
          host: http://from-settings-yaml:11434
    YAML
    ENV["OLLAMA_HOST"] = "http://from-env:11434"

    assert_equal "http://from-env:11434", LogViz::Settings.content_fact_host(@sessions_dir)
  end

  def test_malformed_yaml_falls_back_to_defaults_without_raising
    write_settings("tasks: [this is not a mapping :::")

    assert_equal "ollama", LogViz::Settings.content_fact_provider(@sessions_dir)
    assert_equal "gemma4", LogViz::Settings.content_fact_model(@sessions_dir)
  end
end
