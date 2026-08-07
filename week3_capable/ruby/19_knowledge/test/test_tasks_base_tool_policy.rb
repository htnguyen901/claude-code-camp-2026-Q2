require_relative "helper"

# Tasks::Base.tool_policy turns tasks.<name>.tools into a ToolPolicy — the
# per-task config surface docs/plans/tools_policy/permission.md adds
# alongside the existing .provider/.model/.prompt_override? readers.
class TestTasksBaseToolPolicy < Minitest::Test
  Base = Boukensha::Tasks::Base

  # No `tools:` block at all -> deny-by-default (see the plan's "Default /
  # fail-safe"): a task that forgot to configure itself gets zero tools
  # rather than silently inheriting an MCP server's whole catalog.
  def test_no_tools_block_denies_everything
    policy = Base.tool_policy({})
    refute policy.allowed?("tbamud__look")
  end

  def test_role_expands_to_the_configured_role_globs
    settings   = { "tools" => { "role" => "readonly" } }
    tool_roles = { "readonly" => ["tbamud__look", "tbamud__examine"] }

    policy = Base.tool_policy(settings, tool_roles: tool_roles)
    assert policy.allowed?("tbamud__look")
    refute policy.allowed?("tbamud__attack")
  end

  def test_unknown_role_name_yields_no_tools
    settings = { "tools" => { "role" => "nonexistent" } }
    policy   = Base.tool_policy(settings, tool_roles: {})
    refute policy.allowed?("tbamud__look")
  end

  def test_role_plus_ad_hoc_allow_composes
    settings   = { "tools" => { "role" => "readonly", "allow" => ["tbamud__list_commands"] } }
    tool_roles = { "readonly" => ["tbamud__look"] }

    policy = Base.tool_policy(settings, tool_roles: tool_roles)
    assert policy.allowed?("tbamud__look")
    assert policy.allowed?("tbamud__list_commands")
    refute policy.allowed?("tbamud__attack")
  end

  def test_deny_overrides_role_and_allow
    settings   = { "tools" => { "role" => "full", "deny" => ["tbamud__quit"] } }
    tool_roles = { "full" => ["*"] }

    policy = Base.tool_policy(settings, tool_roles: tool_roles)
    assert policy.allowed?("tbamud__look")
    refute policy.allowed?("tbamud__quit")
  end

  def test_allow_with_no_role_works_standalone
    settings = { "tools" => { "allow" => ["room_knowledge"] } }
    policy   = Base.tool_policy(settings)
    assert policy.allowed?("room_knowledge")
    refute policy.allowed?("tbamud__look")
  end

  # Symbol-keyed settings.yaml parses (e.g. YAML.safe_load with symbolize)
  # resolve the same as string-keyed ones.
  def test_symbol_keys_are_supported
    settings   = { tools: { role: :full, deny: [:tbamud__quit] } }
    tool_roles = { "full" => ["*"] }

    policy = Base.tool_policy(settings, tool_roles: tool_roles)
    assert policy.allowed?("tbamud__look")
    refute policy.allowed?("tbamud__quit")
  end
end
