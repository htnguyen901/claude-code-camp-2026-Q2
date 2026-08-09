require_relative "helper"

# Regression coverage for docs/plans/agent_loop/worker.md §1: every backend's
# to_payload must read Context#effective_system, not #system, so the Player
# sees the Planner's plan — while staying byte-identical to today's payload
# when no plan is ever set (orchestration disabled).
class TestBackendsEffectiveSystem < Minitest::Test
  def new_context(plan: nil)
    ctx = Boukensha::Context.new(system: "You are an agent.")
    ctx.plan = plan
    ctx.add_message(:user, "hi")
    ctx
  end

  def test_anthropic_system_field_is_byte_identical_when_plan_is_unset
    ctx     = new_context
    backend = Boukensha::Backends::Anthropic.new(api_key: "k", model: "claude-haiku-4-5")
    assert_equal ctx.system, backend.to_payload(ctx)[:system]
  end

  def test_anthropic_system_field_includes_the_plan_when_set
    ctx     = new_context(plan: "explore the temple")
    backend = Boukensha::Backends::Anthropic.new(api_key: "k", model: "claude-haiku-4-5")
    assert_equal ctx.effective_system, backend.to_payload(ctx)[:system]
    assert_includes backend.to_payload(ctx)[:system], "explore the temple"
  end

  def test_openai_instructions_field_is_byte_identical_when_plan_is_unset
    ctx     = new_context
    backend = Boukensha::Backends::OpenAI.new(api_key: "k", model: "gpt-5.4-mini")
    assert_equal ctx.system, backend.to_payload(ctx)[:instructions]
  end

  def test_openai_instructions_field_includes_the_plan_when_set
    ctx     = new_context(plan: "explore the temple")
    backend = Boukensha::Backends::OpenAI.new(api_key: "k", model: "gpt-5.4-mini")
    assert_includes backend.to_payload(ctx)[:instructions], "explore the temple"
  end

  def test_gemini_system_instruction_is_byte_identical_when_plan_is_unset
    ctx     = new_context
    backend = Boukensha::Backends::Gemini.new(api_key: "k", model: "gemini-2.5-flash")
    assert_equal ctx.system, backend.to_payload(ctx)[:systemInstruction][:parts][0][:text]
  end

  def test_gemini_system_instruction_includes_the_plan_when_set
    ctx     = new_context(plan: "explore the temple")
    backend = Boukensha::Backends::Gemini.new(api_key: "k", model: "gemini-2.5-flash")
    assert_includes backend.to_payload(ctx)[:systemInstruction][:parts][0][:text], "explore the temple"
  end

  def test_ollama_system_message_is_byte_identical_when_plan_is_unset
    ctx     = new_context
    backend = Boukensha::Backends::Ollama.new(host: "http://localhost:11434", model: "qwen3:8b")
    assert_equal ctx.system, backend.to_payload(ctx)[:messages].first[:content]
  end

  def test_ollama_system_message_includes_the_plan_when_set
    ctx     = new_context(plan: "explore the temple")
    backend = Boukensha::Backends::Ollama.new(host: "http://localhost:11434", model: "qwen3:8b")
    assert_includes backend.to_payload(ctx)[:messages].first[:content], "explore the temple"
  end

  def test_ollama_cloud_system_message_is_byte_identical_when_plan_is_unset
    ctx     = new_context
    backend = Boukensha::Backends::OllamaCloud.new(api_key: "k", model: "kimi-k2.5:cloud")
    assert_equal ctx.system, backend.to_payload(ctx)[:messages].first[:content]
  end

  def test_ollama_cloud_system_message_includes_the_plan_when_set
    ctx     = new_context(plan: "explore the temple")
    backend = Boukensha::Backends::OllamaCloud.new(api_key: "k", model: "kimi-k2.5:cloud")
    assert_includes backend.to_payload(ctx)[:messages].first[:content], "explore the temple"
  end
end
