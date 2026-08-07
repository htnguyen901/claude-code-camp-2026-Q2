require_relative "helper"
require "socket"

# A fake backend, standing in for Backends::* — Client's llm_request
# instrumentation reads provider_name/model/estimate_cost off of it.
class FakeClientBackend
  def provider_name
    "fake"
  end

  def model
    "fake-model"
  end

  def estimate_cost(input_tokens:, output_tokens:)
    nil
  end
end

# A fake PromptBuilder that records whether Client asked it to build the
# payload, so tests can prove a precomputed payload: bypasses that call.
class FakeBuilder
  attr_reader :to_api_payload_calls

  def initialize(url:)
    @url = url
    @to_api_payload_calls = 0
  end

  def url
    @url
  end

  def headers
    { "Content-Type" => "application/json" }
  end

  def backend
    @backend ||= FakeClientBackend.new
  end

  def to_api_payload(**)
    @to_api_payload_calls += 1
    { model: "built-by-client" }
  end

  def parse_response(response)
    { stop_reason: "end_turn", content: [] }
  end
end

class TestClient < Minitest::Test
  # Minimal single-request HTTP/1.1 server: accepts one connection, captures
  # the request body, replies 200 with an empty JSON object. No gems, no
  # real network — just enough to assert what Client#call actually sent.
  def start_echo_server
    server = TCPServer.new("127.0.0.1", 0)
    port   = server.addr[1]
    body   = nil

    thread = Thread.new do
      conn = server.accept
      conn.gets # request line
      headers = {}
      while (line = conn.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.strip if key && value
      end
      length = headers["content-length"].to_i
      body   = conn.read(length)

      response = "{}"
      conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{response.bytesize}\r\n\r\n#{response}")
      conn.close
    end

    [server, thread, port, -> { body }]
  end

  def teardown
    @server&.close
  end

  def test_call_uses_precomputed_payload_as_is
    @server, thread, port, captured_body = start_echo_server
    builder = FakeBuilder.new(url: "http://127.0.0.1:#{port}/")
    client  = Boukensha::Client.new(builder)
    payload = { model: "exact-payload", messages: [{ role: "user", content: "hi" }] }

    client.call(payload: payload)
    thread.join

    assert_equal 0, builder.to_api_payload_calls
    assert_equal payload.to_json, captured_body.call
  end

  def test_call_without_payload_falls_back_to_builder
    @server, thread, port, captured_body = start_echo_server
    builder = FakeBuilder.new(url: "http://127.0.0.1:#{port}/")
    client  = Boukensha::Client.new(builder)

    client.call

    thread.join

    assert_equal 1, builder.to_api_payload_calls
    assert_equal({ model: "built-by-client" }.to_json, captured_body.call)
  end

  # The load-bearing fail-open guarantee (phase1_ruby_sdk.md "Fail-open —
  # hard requirement"): an unreachable OTLP collector must never raise or add
  # meaningful latency to a real request. Actually points
  # OTEL_EXPORTER_OTLP_ENDPOINT at a closed port and asserts on wall-clock
  # time — a regression that swaps BatchSpanProcessor for
  # SimpleSpanProcessor (which exports synchronously, on this thread) would
  # make this test hang or time out, not just fail an assertion.
  def test_call_is_fail_open_when_the_otlp_collector_is_unreachable
    closed_port_server = TCPServer.new("127.0.0.1", 0)
    closed_port = closed_port_server.addr[1]
    closed_port_server.close # nothing listening here anymore

    old_endpoint = ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]
    ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://127.0.0.1:#{closed_port}"
    Boukensha::Telemetry.reset!
    Boukensha::Metrics.reset!
    Boukensha.tracer # forces setup! to configure against the unreachable endpoint

    @server, thread, port, captured_body = start_echo_server
    builder = FakeBuilder.new(url: "http://127.0.0.1:#{port}/")
    client  = Boukensha::Client.new(builder)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result  = client.call(payload: { model: "m", messages: [] })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    thread.join

    assert_equal({}, result)
    assert_operator elapsed, :<, 2.0,
                     "a request must not block on an unreachable OTLP endpoint — got #{elapsed}s"
  ensure
    old_endpoint.nil? ? ENV.delete("OTEL_EXPORTER_OTLP_ENDPOINT") : ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] = old_endpoint
    Boukensha::Telemetry.reset!
    Boukensha::Metrics.reset!
  end
end
