require_relative "helper"
require "socket"
require "json"

# Serves one canned JSON response per accepted connection, in order — lets a
# test script a whole request/tool-call/response sequence without a real
# provider. Mirrors test_client.rb/test_compactor.rb's echo-server pattern.
class ScriptedServer
  def initialize(bodies)
    @bodies = bodies.dup
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { accept_loop }
    @thread.report_on_exception = false
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}/"

  def stop
    @server.close
  rescue StandardError
    nil
  ensure
    @thread.join(1)
  end

  private

  def accept_loop
    @bodies.each do |body|
      conn = @server.accept
      conn.gets # request line
      headers = {}
      while (line = conn.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.strip if key && value
      end
      conn.read(headers["content-length"].to_i) # drain the request body, unused

      conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    ensure
      conn.close rescue nil
    end
  rescue IOError, Errno::EBADF
    nil # server socket closed — normal shutdown
  end
end

# A minimal Backends::* stand-in speaking Anthropic-shaped JSON — just the
# interface Client/Agent/PromptBuilder actually use, pointed at a
# ScriptedServer instead of a real provider.
class ScriptedBackend < Boukensha::Backends::Base
  def self.provider_name = "fake"

  def initialize(url:)
    @url        = url
    @model      = "fake-model"
    @model_info = { context_window: 100_000, cost_per_million: { input: 1.0, output: 5.0 }, usage_unit: :tokens }
  end

  def url = @url
  def headers = { "Content-Type" => "application/json" }
  def to_messages(messages) = messages.map { |m| { role: m.role.to_s, content: m.content } }
  def to_tools(tools) = tools.values.map { |t| { name: t.name } }

  def to_payload(context, max_output_tokens: 1024, tools: nil)
    { model: @model, messages: to_messages(context.messages), max_tokens: max_output_tokens }
  end

  def parse_response(response)
    { stop_reason: response["stop_reason"] == "tool_use" ? "tool_use" : "end_turn", content: response["content"] }
  end
end

# Asserts the actual span tree a real turn produces against the overview's
# span-tree diagram (docs/plans/observability/otel_and_logs/00_overview.md)
# — parent/child linkage by span_id, not just "N spans got created somewhere"
# — using the SDK's InMemorySpanExporter so this runs with no live collector.
class TestTelemetry < Minitest::Test
  include TelemetryTestHelper

  TOOL_USE_RESPONSE = JSON.generate(
    stop_reason: "tool_use", usage: { input_tokens: 100, output_tokens: 20 },
    content: [{ type: "tool_use", id: "t1", name: "echo", input: { text: "hi" } }]
  )

  FINAL_RESPONSE = JSON.generate(
    stop_reason: "end_turn", usage: { input_tokens: 130, output_tokens: 15 },
    content: [{ type: "text", text: "done" }]
  )

  def test_turn_span_tree_matches_the_overview_diagram
    with_span_exporter do |exporter|
      server = ScriptedServer.new([TOOL_USE_RESPONSE, FINAL_RESPONSE])

      ctx      = Boukensha::Context.new(system: "sys", context_window: 100_000, working_dir: ".")
      registry = Boukensha::Registry.new(ctx)
      registry.tool("echo", description: "echo") { |text:| "echoed: #{text}" }

      backend = ScriptedBackend.new(url: server.url)
      builder = Boukensha::PromptBuilder.new(ctx, backend)
      client  = Boukensha::Client.new(builder)
      logger  = Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "telemetry-test")

      agent = Boukensha::Agent.new(context: ctx, registry: registry, builder: builder, client: client,
                                    logger: logger, task_name: "telemetry_task", max_iterations: 5)
      ctx.add_message(:user, "go")
      result = agent.run
      logger.close
      server.stop

      assert_equal "done", result

      spans   = exporter.finished_spans
      by_name = spans.group_by(&:name)

      turn = by_name.fetch("boukensha.turn").fetch(0)
      assert_equal OpenTelemetry::Trace::INVALID_SPAN_ID, turn.parent_span_id, "turn must be the trace root"
      assert_equal "telemetry_task", turn.attributes["boukensha.task"]
      assert_equal "fake", turn.attributes["boukensha.provider"]
      assert_equal "fake-model", turn.attributes["boukensha.model"]

      iterations = by_name.fetch("boukensha.iteration").sort_by { |s| s.attributes["boukensha.iteration"] }
      assert_equal 2, iterations.length
      assert(iterations.all? { |s| s.parent_span_id == turn.span_id }, "every iteration must be a direct child of turn")
      assert_equal [1, 2], iterations.map { |s| s.attributes["boukensha.iteration"] }

      llm_requests = by_name.fetch("boukensha.llm_request").sort_by { |s| s.attributes["boukensha.iteration"] }
      assert_equal 2, llm_requests.length
      assert_equal [iterations[0].span_id, iterations[1].span_id], llm_requests.map(&:parent_span_id),
                   "each llm_request must nest under its own iteration, not the other one or the turn"

      first_call, second_call = llm_requests
      assert_equal "fake", first_call.attributes["gen_ai.system"]
      assert_equal "fake-model", first_call.attributes["gen_ai.request.model"]
      assert_equal 100, first_call.attributes["gen_ai.usage.input_tokens"]
      assert_equal 20, first_call.attributes["gen_ai.usage.output_tokens"]
      assert_equal "tool_use", first_call.attributes["gen_ai.response.finish_reason"]
      assert_in_delta 0.0002, first_call.attributes["boukensha.cost_usd"], 0.0000001

      assert_equal 130, second_call.attributes["gen_ai.usage.input_tokens"]
      assert_equal 15, second_call.attributes["gen_ai.usage.output_tokens"]
      assert_equal "end_turn", second_call.attributes["gen_ai.response.finish_reason"]

      tool_calls = by_name.fetch("boukensha.tool_call")
      assert_equal 1, tool_calls.length
      tool_call = tool_calls.first
      assert_equal iterations[0].span_id, tool_call.parent_span_id, "the tool_call belongs to the iteration that requested it"
      assert_equal "echo", tool_call.attributes["boukensha.tool.name"]
      assert_equal true, tool_call.attributes["boukensha.tool.ok"]
      refute tool_call.attributes.key?("boukensha.tool.error"), "no error attribute on a successful dispatch"
    end
  end

  def test_failed_tool_dispatch_is_flagged_ok_false_with_error_on_the_span
    with_span_exporter do |exporter|
      tool_use = JSON.generate(
        stop_reason: "tool_use", usage: { input_tokens: 10, output_tokens: 5 },
        content: [{ type: "tool_use", id: "t1", name: "boom", input: {} }]
      )
      final = JSON.generate(stop_reason: "end_turn", usage: { input_tokens: 10, output_tokens: 5 },
                             content: [{ type: "text", text: "done" }])
      server = ScriptedServer.new([tool_use, final])

      ctx      = Boukensha::Context.new(system: "sys", context_window: 100_000, working_dir: ".")
      registry = Boukensha::Registry.new(ctx)
      registry.tool("boom", description: "boom") { raise "kaboom" }

      backend = ScriptedBackend.new(url: server.url)
      builder = Boukensha::PromptBuilder.new(ctx, backend)
      client  = Boukensha::Client.new(builder)
      logger  = Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "telemetry-error-test")

      agent = Boukensha::Agent.new(context: ctx, registry: registry, builder: builder, client: client,
                                    logger: logger, task_name: "t", max_iterations: 5)
      ctx.add_message(:user, "go")
      agent.run
      logger.close
      server.stop

      tool_call = exporter.finished_spans.find { |s| s.name == "boukensha.tool_call" }
      assert_equal false, tool_call.attributes["boukensha.tool.ok"]
      assert_includes tool_call.attributes["boukensha.tool.error"], "kaboom"
    end
  end
end
