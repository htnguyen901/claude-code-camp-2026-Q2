require_relative "helper"

# Registry is the one choke point every tool registration path (MCP
# discovery, the ad hoc RunDSL#tool used by room_knowledge) funnels through —
# see docs/plans/tools_policy/permission.md, Option D. A denied tool is never
# built at all: its schema never reaches @context.tools.
class TestRegistry < Minitest::Test
  include McpTestHelper

  def test_bare_registry_defaults_to_allow_everything
    ctx, registry = new_registry
    registry.tool("attack", description: "hit") { "ok" }
    assert ctx.tools.key?("attack")
  end

  def test_denied_tool_is_never_registered
    ctx, registry = new_registry(policy: Boukensha::ToolPolicy.new(allow: ["look"]))
    registry.tool("look", description: "look around") { "ok" }
    registry.tool("attack", description: "hit") { "ok" }

    assert ctx.tools.key?("look")
    refute ctx.tools.key?("attack")
    assert_equal 1, ctx.tools.size
  end

  def test_registering_a_denied_tool_returns_nil
    _ctx, registry = new_registry(policy: Boukensha::ToolPolicy.new(allow: []))
    assert_nil registry.tool("attack", description: "hit") { "ok" }
  end

  def test_dispatching_a_denied_tool_raises_permission_denied
    _ctx, registry = new_registry(policy: Boukensha::ToolPolicy.new(allow: ["look"]))
    registry.tool("look", description: "look around") { "ok" }
    registry.tool("attack", description: "hit") { "ok" }

    assert_raises(Boukensha::PermissionDeniedError) { registry.dispatch("attack", {}) }
  end

  # A name that was never registered by anything at all (not even filtered
  # out by policy) stays UnknownToolError — the two failure modes stay
  # distinguishable in observability.
  def test_dispatching_a_never_registered_tool_raises_unknown_tool
    _ctx, registry = new_registry(policy: Boukensha::ToolPolicy.new(allow: ["*"]))
    assert_raises(Boukensha::UnknownToolError) { registry.dispatch("nonexistent", {}) }
  end

  def test_tool_names_only_reflects_allowed_tools
    _ctx, registry = new_registry(policy: Boukensha::ToolPolicy.new(allow: ["look"]))
    registry.tool("look", description: "look around") { "ok" }
    registry.tool("attack", description: "hit") { "ok" }

    assert_equal ["look"], registry.tool_names
  end
end
