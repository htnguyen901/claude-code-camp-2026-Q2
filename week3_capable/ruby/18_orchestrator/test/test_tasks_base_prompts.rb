require_relative "helper"

# Tasks::Base.read_default_prompt is task-scoped, mirroring read_user_prompt
# — docs/plans/agent_loop/orchestrator.md §1. Player's own prompt moved from
# prompts/system.md to prompts/player/system.md; this is a no-op path change
# for Player (the only caller today) and the prerequisite for Planner/Judge
# each getting their own default prompt instead of colliding on Player's.
class TestTasksBaseDefaultPrompts < Minitest::Test
  Player = Boukensha::Tasks::Player

  def test_player_default_system_prompt_resolves_from_the_player_scoped_path
    text = Player.system_prompt({}, default_prompts_dir: Boukensha::Config::PROMPTS_DIR)

    expected = File.read(File.join(Boukensha::Config::PROMPTS_DIR, "player", "system.md")).strip
    assert_equal expected, text
    assert_includes text, "Boukensha"
  end

  def test_unscoped_default_prompts_dir_no_longer_resolves
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "system.md"), "unscoped prompt")

      assert_nil Player.system_prompt({}, default_prompts_dir: dir)
    end
  end

  def test_a_different_task_reads_its_own_scoped_prompt_not_players
    fake_task = Class.new(Boukensha::Tasks::Base) { def self.task_name = "planner" }

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "player"))
      FileUtils.mkdir_p(File.join(dir, "planner"))
      File.write(File.join(dir, "player", "system.md"), "player prompt")
      File.write(File.join(dir, "planner", "system.md"), "planner prompt")

      assert_equal "planner prompt", fake_task.system_prompt({}, default_prompts_dir: dir)
      assert_equal "player prompt", Player.system_prompt({}, default_prompts_dir: dir)
    end
  end
end
