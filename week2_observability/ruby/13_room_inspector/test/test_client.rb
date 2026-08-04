require_relative "helper"
require "socket"

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

  def to_api_payload(**)
    @to_api_payload_calls += 1
    { model: "built-by-client" }
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
end
