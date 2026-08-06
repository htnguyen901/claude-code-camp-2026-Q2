require_relative "helper"

# ToolPolicy is a pure allow/deny glob matcher — see docs/plans/tools_policy/
# permission.md, Option B. Enforcement (Registry#tool never building a denied
# Tool at all) is covered separately in test_registry.rb.
class TestToolPolicy < Minitest::Test
  def test_default_policy_allows_everything
    policy = Boukensha::ToolPolicy.new
    assert policy.allowed?("tbamud__attack")
    assert policy.allowed?("room_knowledge")
  end

  def test_empty_allow_list_denies_everything
    policy = Boukensha::ToolPolicy.new(allow: [])
    refute policy.allowed?("tbamud__look")
  end

  def test_exact_name_match
    policy = Boukensha::ToolPolicy.new(allow: ["tbamud__look"])
    assert policy.allowed?("tbamud__look")
    refute policy.allowed?("tbamud__examine")
  end

  def test_glob_prefix_match
    policy = Boukensha::ToolPolicy.new(allow: ["tbamud__say_*"])
    assert policy.allowed?("tbamud__say_local")
    assert policy.allowed?("tbamud__say_targeted")
    refute policy.allowed?("tbamud__attack")
  end

  def test_star_allows_any_name
    policy = Boukensha::ToolPolicy.new(allow: ["*"])
    assert policy.allowed?("anything_at_all")
  end

  # Explicit refusal should never be shadowed by a broader allow glob.
  def test_deny_wins_over_allow_on_overlap
    policy = Boukensha::ToolPolicy.new(allow: ["*"], deny: ["tbamud__attack"])
    assert policy.allowed?("tbamud__look")
    refute policy.allowed?("tbamud__attack")
  end

  def test_deny_glob_beats_a_narrower_allow
    policy = Boukensha::ToolPolicy.new(allow: ["tbamud__quit"], deny: ["tbamud__*"])
    refute policy.allowed?("tbamud__quit")
  end

  def test_accepts_symbol_names
    policy = Boukensha::ToolPolicy.new(allow: ["tbamud__look"])
    assert policy.allowed?(:tbamud__look)
  end
end
