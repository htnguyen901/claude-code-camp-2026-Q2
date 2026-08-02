require "minitest/autorun"
require "tmpdir"
require "json"
require "time"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "log_viz/session"

module SessionTestHelper
  # Writes a synthetic .jsonl session file from a list of event hashes and
  # returns its path. Purely additive to the log format — no dependency on
  # the agent (week1_baseline/ruby/12_context), matching the plan's "no new
  # agent-side change" contract: these tests only exercise what log_viz reads.
  def write_session(events)
    dir  = Dir.mktmpdir
    path = File.join(dir, "test-session.jsonl")
    File.open(path, "w") do |f|
      events.each { |e| f.puts JSON.generate(e) }
    end
    path
  end

  def session_start_event(provider:, model: "test-model")
    { phase: "session_start", provider: provider, model: model,
      session_id: "test-session", at: Time.now.iso8601 }
  end

  def request_event(payload:, message_count: 1, tool_count: 0, iteration: 1, wrap_up: false)
    {
      phase: "request", iteration: iteration, wrap_up: wrap_up,
      model: payload[:model] || payload["model"], payload: payload,
      bytes: JSON.generate(payload).bytesize,
      message_count: message_count, tool_count: tool_count,
      session_id: "test-session", at: Time.now.iso8601
    }
  end

  def response_event(usage:, text: "ok")
    { phase: "response", text: text, usage: usage, stop_reason: "end_turn",
      session_id: "test-session", at: Time.now.iso8601 }
  end

  def request_entry_for(path)
    LogViz::Session.load(path).entries.find { |e| e.type == :request }
  end
end
