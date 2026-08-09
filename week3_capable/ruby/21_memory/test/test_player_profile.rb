require_relative "helper"
require "boukensha/player_profile"

class TestPlayerProfile < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir)
  end

  def write_profile(name, yaml)
    File.write(File.join(@tmp_dir, "#{name}.yaml"), yaml)
  end

  def test_loads_name_password_and_persona
    write_profile("noir", <<~YAML)
      name: noir
      password: shadowveil
      sex: F
      class: thief
      admin: false

      persona:
        playstyle: stealthy
        risk_mode: cautious
        thought_process: null
        notes: null
    YAML

    profile = Boukensha::PlayerProfile.load("noir", players_dir: @tmp_dir)

    assert_equal "noir", profile.name
    assert_equal "shadowveil", profile.password
    assert_equal "F", profile.sex
    assert_equal "thief", profile.player_class
    refute profile.admin
    assert_equal "stealthy", profile.persona["playstyle"]
  end

  def test_admin_flag_is_boolean
    write_profile("admin", <<~YAML)
      name: admin
      password: password
      sex: M
      class: warrior
      admin: true
    YAML

    profile = Boukensha::PlayerProfile.load("admin", players_dir: @tmp_dir)
    assert profile.admin
  end

  def test_missing_persona_defaults_to_empty_hash
    write_profile("dummy", <<~YAML)
      name: dummy
      password: helloworld
      sex: M
      class: cleric
      admin: false
    YAML

    profile = Boukensha::PlayerProfile.load("dummy", players_dir: @tmp_dir)
    assert_equal({}, profile.persona)
  end

  def test_missing_file_aborts_with_a_clear_message
    err = assert_raises(SystemExit) do
      capture_io { Boukensha::PlayerProfile.load("nobody", players_dir: @tmp_dir) }
    end
    assert_equal 1, err.status
  end

  def test_missing_file_message_names_the_expected_path
    _out, err = capture_io do
      assert_raises(SystemExit) { Boukensha::PlayerProfile.load("nobody", players_dir: @tmp_dir) }
    end
    assert_match(/nobody\.yaml/, err)
  end
end
