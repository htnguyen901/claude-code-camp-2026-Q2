require_relative "helper"
require "socket"
require "json"

# Serves one canned JSON response per accepted connection, in order — mirrors
# test_telemetry.rb's ScriptedServer/ScriptedBackend pattern.
class StopReasonScriptedServer
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
      conn.gets
      headers = {}
      while (line = conn.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.strip if key && value
      end
      conn.read(headers["content-length"].to_i)
      conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    ensure
      conn.close rescue nil
    end
  rescue IOError, Errno::EBADF
    nil
  end
end

class StopReasonScriptedBackend < Boukensha::Backends::Base
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

# Agent#stop_reason — docs/plans/agent_loop/worker.md §2. A thin, additive
# accessor set at each of Agent#run's three return points; the driver
# (Phase 4) and Judge checkpoint trigger both need this to distinguish a
# natural completion from a limit-triggered wrap-up without re-parsing text.
class TestAgentStopReason < Minitest::Test
  FINAL_RESPONSE = JSON.generate(
    stop_reason: "end_turn", usage: { input_tokens: 10, output_tokens: 5 },
    content: [{ type: "text", text: "done" }]
  )

  def tool_use_response(input_tokens:, output_tokens:)
    JSON.generate(
      stop_reason: "tool_use", usage: { input_tokens: input_tokens, output_tokens: output_tokens },
      content: [{ type: "tool_use", id: "t1", name: "echo", input: { text: "hi" } }]
    )
  end

  def build_agent(server, **agent_opts)
    ctx      = Boukensha::Context.new(system: "sys", context_window: 100_000, working_dir: ".")
    registry = Boukensha::Registry.new(ctx)
    registry.tool("echo", description: "echo") { |text:| "echoed: #{text}" }

    backend = StopReasonScriptedBackend.new(url: server.url)
    builder = Boukensha::PromptBuilder.new(ctx, backend)
    client  = Boukensha::Client.new(builder)
    logger  = Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "stop-reason-test")

    Boukensha::Agent.new(context: ctx, registry: registry, builder: builder, client: client,
                          logger: logger, task_name: "t", **agent_opts)
  end

  def test_stop_reason_is_completed_after_a_natural_end_of_turn
    server = StopReasonScriptedServer.new([FINAL_RESPONSE])
    agent  = build_agent(server, max_iterations: 5)

    agent.run
    server.stop

    assert_equal :completed, agent.stop_reason
  end

  def test_stop_reason_is_max_iterations_after_the_iteration_limit_wrap_up
    server = StopReasonScriptedServer.new([tool_use_response(input_tokens: 10, output_tokens: 5), FINAL_RESPONSE])
    agent  = build_agent(server, max_iterations: 1)

    agent.run
    server.stop

    assert_equal :max_iterations, agent.stop_reason
  end

  def test_stop_reason_is_max_tokens_after_the_token_limit_wrap_up
    server = StopReasonScriptedServer.new([tool_use_response(input_tokens: 80, output_tokens: 30), FINAL_RESPONSE])
    agent  = build_agent(server, max_iterations: 25, max_turn_tokens: 100)

    agent.run
    server.stop

    assert_equal :max_tokens, agent.stop_reason
  end
end
