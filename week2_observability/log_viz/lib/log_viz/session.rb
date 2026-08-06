require "json"

require_relative "room_echo"
require_relative "self_state"

module LogViz
  # Parses a Boukensha session .jsonl log into an ordered list of entries
  # suitable for rendering as a human-readable transcript.
  class Session
    Entry = Struct.new(:type, :text, :usage, :turn, :iteration,
                       :tool_name, :tool_args, :tool_result, :tool_ok, :tool_error,
                       :stop_reason, :reason, :iterations, :tokens, :before, :dropped,
                       :running_turn_tokens, :redacted,
                       :task, :provider, :model, :input_tokens, :output_tokens,
                       :cost_usd, :usage_unit, :usage_level,
                       :wrap_up, :payload, :bytes, :message_count, :tool_count,
                       :bytes_delta, :message_count_delta,
                       :comp_system_tokens, :comp_tools_tokens, :comp_messages_tokens,
                       :comp_other_tokens, :comp_input_tokens, :comp_cache_read,
                       :comp_system_cost, :comp_tools_cost, :comp_messages_cost,
                       :comp_other_cost, :comp_output_cost, :comp_cost_usd,
                       :comp_output_tokens, :room_title, :injected_calls,
                       :trace_id,
                       keyword_init: true)

    # One sample per `response`, in order. Drives the in-transcript chips (§2.3)
    # and the trend sparkline (§2.4).
    UsagePoint = Struct.new(:turn, :iteration, :input, :output,
                            :cache_read, :cache_creation, :running, :at,
                            :task, :provider, :model, :cost_usd,
                            :usage_unit, :usage_level,
                            keyword_init: true)

    # One sample per `request` event, in call order across the whole session
    # (not reset per turn/iteration) — drives the linear payload-growth chart.
    RequestPoint = Struct.new(:index, :turn, :iteration, :message_count,
                              :message_count_delta, :bytes, :wrap_up, :at,
                              :system_tokens, :tools_tokens, :messages_tokens,
                              keyword_init: true)

    # Per-MTok input/output rates. Cache reads bill at ~0.1x input, cache
    # writes at ~1.25x input (used by `point_cost`'s old-log fallback path
    # only — see there). Unknown models return nil cost (rendered as —).
    #
    # Mirrors the `cost_per_million` values hardcoded in each backend's
    # MODELS table (week1_baseline/ruby/12_context/lib/boukensha/backends/
    # *.rb) — duplicated here (log_viz has no dependency on the agent) so
    # that a request's dollar cost can be computed and split across the
    # system/tools/messages/other composition buckets independent of
    # whatever `cost_usd` (if any) got logged for that call. OllamaCloud
    # models aren't listed: their backend itself has no fixed per-token
    # price (`cost_per_million: { input: nil, output: nil }`).
    MODEL_PRICES = {
      # Anthropic
      "claude-fable-5"            => { input: 10.0, output: 50.0 },
      "claude-opus-4-8"           => { input: 5.0,  output: 25.0 },
      "claude-opus-4-7"           => { input: 5.0,  output: 25.0 },
      "claude-opus-4-6"           => { input: 5.0,  output: 25.0 },
      "claude-sonnet-4-6"         => { input: 3.0,  output: 15.0 },
      "claude-haiku-4-5"          => { input: 1.0,  output: 5.0 },
      "claude-haiku-4-5-20251001" => { input: 1.0,  output: 5.0 },
      # OpenAI
      "gpt-5.5"      => { input: 5.0,  output: 30.0 },
      "gpt-5.4-mini" => { input: 0.75, output: 4.5 },
      "gpt-5.4-nano" => { input: 0.2,  output: 1.25 },
      # Gemini
      "gemini-3.5-flash"      => { input: 1.5,  output: 9.0 },
      "gemini-3.1-flash-lite" => { input: 0.25, output: 1.5 },
      "gemini-2.5-pro"        => { input: 1.25, output: 10.0 },
      "gemini-2.5-flash"      => { input: 0.30, output: 2.50 },
      "gemini-2.5-flash-lite" => { input: 0.10, output: 0.40 },
      # Ollama (local compute, no API cost)
      "gemma4"         => { input: 0.0, output: 0.0 },
      "gemma4:e2b"     => { input: 0.0, output: 0.0 },
      "gemma4:e4b"     => { input: 0.0, output: 0.0 },
      "gemma4:12b"     => { input: 0.0, output: 0.0 },
      "gemma4:26b"     => { input: 0.0, output: 0.0 },
      "gemma4:31b"     => { input: 0.0, output: 0.0 },
      "qwen3:30b"      => { input: 0.0, output: 0.0 },
      "qwen3:8b"       => { input: 0.0, output: 0.0 },
      "deepseek-r1:8b" => { input: 0.0, output: 0.0 },
    }.freeze

    # Where each backend's `to_payload` (week1_baseline/ruby/12_context/lib/
    # boukensha/backends/*.rb) puts the system prompt and message history —
    # the two keys that, along with the already-consistent `tools` key, let a
    # request's bytes be split into named buckets without a per-backend
    # branch. `system: nil` means the backend folds the system prompt into
    # the first message instead of a separate top-level key (Ollama) — that
    # case is split out of `messages` by role instead.
    PROVIDER_KEYS = {
      "anthropic"    => { system: ["system"],            messages: "messages" },
      "openai"       => { system: ["instructions"],      messages: "input" },
      "gemini"       => { system: ["systemInstruction"], messages: "contents" },
      "ollama"       => { system: nil,                   messages: "messages" },
      "ollama_cloud" => { system: nil,                   messages: "messages" },
    }.freeze

    # Where each backend's raw `usage` hash reports cache reads/writes.
    # Anthropic's shape is what the code originally (incorrectly) assumed for
    # every provider. OpenAI's shape is confirmed against a real logged
    # session (`usage.input_tokens_details.{cached_tokens,cache_write_tokens}`).
    # Gemini's is per the public `usageMetadata` shape, unconfirmed against a
    # real session (none logged in this repo yet). Ollama has no cache
    # concept, so both keys are nil.
    CACHE_KEYS = {
      "anthropic"    => { read: "cache_read_input_tokens", write: "cache_creation_input_tokens" },
      "openai"       => { read: %w[input_tokens_details cached_tokens], write: %w[input_tokens_details cache_write_tokens] },
      "gemini"       => { read: "cachedContentTokenCount", write: nil },
      "ollama"       => { read: nil, write: nil },
      "ollama_cloud" => { read: nil, write: nil },
    }.freeze

    # Falls back to Anthropic's shape for unknown/missing providers — the
    # historical default, and harmless for Ollama-style hashes that simply
    # don't have that key (reads back nil -> 0).
    def self.cache_tokens(usage, provider)
      usage ||= {}
      keys = CACHE_KEYS[provider] || CACHE_KEYS["anthropic"]
      { read: dig_cache(usage, keys[:read]), write: dig_cache(usage, keys[:write]) }
    end

    def self.dig_cache(usage, key)
      return 0 if key.nil?

      value = key.is_a?(Array) ? usage.dig(*key) : usage[key]
      value.to_i
    end

    attr_reader :id, :path, :started_at, :entries,
                :total_input_tokens, :total_output_tokens, :snapshot,
                :usage_series, :peak_input_tokens, :request_series,
                :compaction_markers, :current_room, :self_state

    def self.load(path)
      new(path).tap(&:parse!)
    end

    def initialize(path)
      @path                = path
      @id                  = File.basename(path, ".jsonl")
      @entries             = []
      @started_at          = nil
      @total_input_tokens  = 0
      @total_output_tokens = 0
      @snapshot            = {}
      @usage_series        = []
      @peak_input_tokens   = 0
      @request_series      = []
      @compaction_markers  = []
      @current_room        = nil
      @self_state          = {}
    end

    def parse!
      current_turn      = 0
      current_iteration = 0
      current_trace_id  = nil # this turn's trace_id, from its "turn" event (Phase 2/3 bridge)
      pending_user      = true
      pending_calls     = []
      running_turn      = 0   # cumulative input+output within the current turn
      last_request      = nil # {message_count:, bytes:} of the previous request, for deltas
      pending_request   = nil # {entry:, point:, bytes:, total_bytes:} awaiting this call's response
      pending_injected  = []  # {name:, compacted:, raw_len:, compacted_len:} since the last request

      File.foreach(@path) do |line|
        line = line.strip
        next if line.empty?

        event = JSON.parse(line)

        case event["phase"]
        when "session_start"
          @started_at = event["at"]
          @snapshot   = event           # carries the limits/model denominators
        when "turn"
          current_turn     = event["n"]
          current_trace_id = event["trace_id"]
          pending_user     = true
          running_turn     = 0
        when "iteration"
          current_iteration = event["n"]
        when "request"
          payload = event["payload"] || {}

          if pending_user
            if event["last_user_text"]
              @entries << Entry.new(type: :user, text: extract_text(event["last_user_text"]),
                                     turn: current_turn, iteration: current_iteration)
            end
            pending_user = false
          end

          if pending_injected.any?
            @entries << Entry.new(type: :injected, injected_calls: pending_injected,
                                   turn: current_turn, iteration: current_iteration)
            pending_injected = []
          end

          message_count = event["message_count"].to_i
          bytes         = event["bytes"].to_i
          message_count_delta = last_request && message_count - last_request[:message_count]
          bytes_delta          = last_request && bytes - last_request[:bytes]

          request_entry = Entry.new(type: :request, turn: current_turn, iteration: current_iteration,
                                     wrap_up: event["wrap_up"] == true, model: event["model"],
                                     payload: payload, bytes: bytes, message_count: message_count,
                                     tool_count: event["tool_count"].to_i,
                                     bytes_delta: bytes_delta, message_count_delta: message_count_delta)
          @entries << request_entry

          request_point = RequestPoint.new(
            index: @request_series.size, turn: current_turn, iteration: current_iteration,
            message_count: message_count, message_count_delta: message_count_delta,
            bytes: bytes, wrap_up: event["wrap_up"] == true, at: event["at"])
          @request_series << request_point

          # Byte split happens now (payload is only available on the request
          # event); apportioning it into real tokens happens once this call's
          # matching `response` event arrives with the ground-truth input_tokens.
          pending_request = {
            entry: request_entry, point: request_point,
            bytes: split_request_bytes(payload, @snapshot["provider"]), total_bytes: bytes
          }

          last_request = { message_count: message_count, bytes: bytes }
        when "compaction"
          @entries << Entry.new(type: :compaction, before: event["before"],
                                 dropped: event["dropped"],
                                 turn: current_turn, iteration: current_iteration)
          @compaction_markers << @request_series.size
        when "reasoning"
          @entries << Entry.new(type: :reasoning, text: event["text"],
                                 redacted: event["redacted"],
                                 turn: current_turn, iteration: current_iteration)
        when "plan"
          @entries << Entry.new(type: :plan, text: event["text"],
                                 turn: current_turn, iteration: current_iteration)
        when "response"
          usage = event["usage"]
          if usage
            input  = event["input_tokens"] || usage["input_tokens"]
            output = event["output_tokens"] || usage["output_tokens"]
            input  = input.to_i
            output = output.to_i
            @total_input_tokens  += input
            @total_output_tokens += output
            running_turn         += input + output
            @peak_input_tokens    = input if input > @peak_input_tokens
            cache = self.class.cache_tokens(usage, @snapshot["provider"])
            @usage_series << UsagePoint.new(
              turn: current_turn, iteration: current_iteration,
              input: input, output: output,
              cache_read: cache[:read], cache_creation: cache[:write],
              running: running_turn, at: event["at"],
              task: event["task"], provider: event["provider"], model: event["model"],
              cost_usd: numeric(event["cost_usd"]),
              usage_unit: event["usage_unit"], usage_level: event["usage_level"])

            if pending_request
              tokens = apportion_tokens(pending_request[:bytes], pending_request[:total_bytes], input)
              pending_request[:entry].comp_system_tokens   = tokens[:system]
              pending_request[:entry].comp_tools_tokens    = tokens[:tools]
              pending_request[:entry].comp_messages_tokens = tokens[:messages]
              pending_request[:entry].comp_other_tokens    = tokens[:other]
              pending_request[:entry].comp_input_tokens    = input
              pending_request[:entry].comp_cache_read      = cache[:read]

              pending_request[:point].system_tokens   = tokens[:system]
              pending_request[:point].tools_tokens    = tokens[:tools]
              pending_request[:point].messages_tokens = tokens[:messages]

              costs = bucket_costs(tokens, output, MODEL_PRICES[pending_request[:entry].model])
              pending_request[:entry].comp_system_cost   = costs[:system]
              pending_request[:entry].comp_tools_cost    = costs[:tools]
              pending_request[:entry].comp_messages_cost = costs[:messages]
              pending_request[:entry].comp_other_cost    = costs[:other]
              pending_request[:entry].comp_output_cost   = costs[:output]
              pending_request[:entry].comp_cost_usd      = costs[:total]
              pending_request[:entry].comp_output_tokens = output

              pending_request = nil
            end
          end
          @entries << Entry.new(type: :assistant, text: event["text"], usage: usage,
                                 stop_reason: event["stop_reason"],
                                 running_turn_tokens: running_turn,
                                 task: event["task"], provider: event["provider"],
                                 model: event["model"], input_tokens: event["input_tokens"],
                                 output_tokens: event["output_tokens"],
                                 cost_usd: numeric(event["cost_usd"]),
                                 usage_unit: event["usage_unit"],
                                 usage_level: event["usage_level"],
                                 turn: current_turn, iteration: current_iteration)
        when "tool_call"
          pending_calls << { name: event["name"], args: event["args"] }
        when "tool_result"
          call = pending_calls.shift || {}
          name = event["name"] || call[:name]
          room_title = extract_room_title(name, event["result"])
          record_self_state(name, call[:args], event, current_turn, current_iteration)

          @entries << Entry.new(type: :tool, tool_name: name, tool_args: call[:args],
                                 tool_result: event["result"], tool_ok: event.fetch("ok", true),
                                 tool_error: event["error"], room_title: room_title,
                                 turn: current_turn, iteration: current_iteration)

          # Older logs predate Logger#tool_result's `compacted:` field —
          # event["compacted"] is simply absent there, so nothing is
          # buffered and no :injected panel appears for those sessions.
          if event["compacted"]
            pending_injected << { name: name, compacted: event["compacted"],
                                   raw_len: event["result"].to_s.length,
                                   compacted_len: event["compacted"].to_s.length }
          end
        when "turn_end"
          @entries << Entry.new(type: :turn_end, reason: event["reason"],
                                 iterations: event["iterations"], tokens: event["tokens"],
                                 turn: current_turn, iteration: current_iteration,
                                 trace_id: current_trace_id)
        end
      end
    end

    def turn_count
      entries.map(&:turn).max.to_i + 1
    end

    def iteration_count
      entries.map(&:iteration).max.to_i
    end

    # ---- denominators sourced from the session_start snapshot ------------
    def iteration_max   = @snapshot["max_iterations"]
    def max_turn_tokens = @snapshot["max_turn_tokens"]
    def context_window  = @snapshot["context_window"]
    def model           = @snapshot["model"]
    def provider        = @snapshot["provider"]
    def response_models = @usage_series.map(&:model).compact.uniq
    def response_providers = @usage_series.map(&:provider).compact.uniq
    def task_names = @usage_series.map(&:task).compact.uniq

    def model_summary
      labels = @usage_series.map { |p| model_label(p.provider, p.model) }.compact.uniq
      labels = [model_label(provider, model)].compact if labels.empty?
      labels.length <= 2 ? labels.join(", ") : "#{labels.length} models"
    end

    # ---- per-turn outcomes ----------------------------------------------
    def turn_ends   = entries.select { |e| e.type == :turn_end }
    def end_reason  = turn_ends.last&.reason
    def stopped?    = !end_reason.nil? && end_reason != "completed"

    # Iterations/tokens of the final turn (falls back to whole-session figures
    # for older logs that predate turn_end).
    def last_iterations = turn_ends.last&.iterations || iteration_count
    def turn_tokens     = turn_ends.last&.tokens || (@total_input_tokens + @total_output_tokens)

    # ---- per-turn rollup (§2.2) -----------------------------------------
    # One row per turn, built from turn_end events. Falls back to a single
    # synthetic row for older logs that predate turn_end.
    def turns
      rows = turn_ends.map do |e|
        { n: e.turn, iterations: e.iterations, tokens: e.tokens.to_i, reason: e.reason }
      end
      return rows unless rows.empty?

      [{ n: entries.map(&:turn).max.to_i, iterations: iteration_count,
         tokens: @total_input_tokens + @total_output_tokens, reason: end_reason }]
    end

    def limit_reason?(reason) = !reason.nil? && reason != "completed"

    # Worst turn by token spend — the one closest to (or over) the cap.
    def largest_turn      = turns.max_by { |t| t[:tokens] }
    def busiest_turn      = turns.max_by { |t| t[:iterations].to_i }
    def any_limit_tripped? = turns.any? { |t| limit_reason?(t[:reason]) }
    def turn_count_real    = turns.length

    # ---- cost estimate (§2.1) -------------------------------------------
    # Prefer logger-emitted per-response cost. Older logs fall back to local
    # model rates; nil means no trustworthy cost is available.
    def estimated_cost
      costs = @usage_series.map { |p| point_cost(p) }.compact
      return nil if costs.empty?

      costs.sum
    end

    def cost_breakdown
      rows = {}
      @usage_series.each do |p|
        key = [p.task || "unknown", p.provider || provider || "unknown", p.model || model || "unknown"]
        row = rows[key] ||= {
          task: key[0], provider: key[1], model: key[2],
          calls: 0, input: 0, output: 0, cost: 0.0, cost_known: true
        }
        row[:calls] += 1
        row[:input] += p.input.to_i
        row[:output] += p.output.to_i
        cost = point_cost(p)
        if cost
          row[:cost] += cost
        else
          row[:cost_known] = false
        end
      end
      rows.values.sort_by { |row| [-row[:cost], row[:task], row[:provider], row[:model]] }
    end

    def task
      entries.find { |e| e.type == :user }&.text
    end

    def final_response
      entries.reverse.find do |e|
        e.type == :assistant &&
          e.stop_reason != "tool_use" &&
          !e.text.to_s.start_with?("(tool use")
      end&.text
    end

    private

    # Splits one request's payload bytes into named buckets, generically per
    # PROVIDER_KEYS — the one universal key (`tools`) plus a provider-keyed
    # system/messages lookup. Everything not captured by those three keys
    # (model name, max_output_tokens, reasoning config, etc.) is left for the
    # caller to infer as "other" from the total minus these three.
    def split_request_bytes(payload, provider)
      tools_bytes = json_bytesize(payload["tools"])
      keys = PROVIDER_KEYS[provider]

      return { system: 0, tools: tools_bytes, messages: 0 } unless keys

      if keys[:system]
        system_bytes   = json_bytesize(payload.slice(*keys[:system]))
        messages_bytes = json_bytesize(payload[keys[:messages]])
      else
        # Ollama-style: no separate system key — the system prompt is the
        # leading role=="system" message inside the messages array.
        messages    = payload[keys[:messages]] || []
        head, *rest = messages
        if head.is_a?(Hash) && head["role"] == "system"
          system_bytes   = json_bytesize(head)
          messages_bytes = json_bytesize(rest)
        else
          system_bytes   = 0
          messages_bytes = json_bytesize(messages)
        end
      end

      { system: system_bytes, tools: tools_bytes, messages: messages_bytes }
    end

    def json_bytesize(value)
      return 0 if value.nil?

      JSON.generate(value).bytesize
    end

    # Anchors the byte-proportional split to the call's real, provider-billed
    # input_tokens: the three named buckets are rounded independently, and
    # "other" absorbs whatever's left (misc payload overhead *and* rounding
    # drift), so the four buckets always sum to exactly `input_tokens` — by
    # construction, not by hope (see plan §2/§6).
    def apportion_tokens(bytes, total_bytes, input_tokens)
      input_tokens = input_tokens.to_i
      return { system: 0, tools: 0, messages: 0, other: input_tokens } if total_bytes.to_i <= 0

      system_t   = (input_tokens.to_f * bytes[:system]   / total_bytes).round
      tools_t    = (input_tokens.to_f * bytes[:tools]    / total_bytes).round
      messages_t = (input_tokens.to_f * bytes[:messages] / total_bytes).round
      other_t    = input_tokens - system_t - tools_t - messages_t

      { system: system_t, tools: tools_t, messages: messages_t, other: other_t }
    end

    # Prices each composition bucket's real tokens at the model's list input
    # rate, plus a separate output-cost line for the response side of the
    # same call. Built from `tokens` (already exact-sum-to-input_tokens per
    # `apportion_tokens`), so `total` is exactly the four input buckets plus
    # output — internally consistent by construction, the same way the token
    # buckets are. Returns all-nil when `rates` is nil (unpriced model),
    # matching `point_cost`'s existing "unknown model -> no cost" behavior.
    def bucket_costs(tokens, output_tokens, rates)
      return { system: nil, tools: nil, messages: nil, other: nil, output: nil, total: nil } unless rates

      input_rate  = rates[:input] / 1_000_000.0
      output_rate = rates[:output] / 1_000_000.0

      system_c   = tokens[:system]   * input_rate
      tools_c    = tokens[:tools]    * input_rate
      messages_c = tokens[:messages] * input_rate
      other_c    = tokens[:other]    * input_rate
      output_c   = output_tokens.to_i * output_rate

      { system: system_c, tools: tools_c, messages: messages_c, other: other_c,
        output: output_c, total: system_c + tools_c + messages_c + other_c + output_c }
    end

    # Per-session, in-memory location tracking (no WorldMap/SQLite
    # dependency — this page already parses exactly one file per request,
    # so it doesn't have the cross-session scaling problem WorldMap solves;
    # see player_journey_map.md §3). Only tags "reached this room" on the
    # entry — the new-vs-revisit distinction needs cross-session history,
    # which lives on the /map page instead.
    def extract_room_title(name, result)
      return nil unless name && RoomEcho.location_tool?(name)

      parsed = RoomEcho.parse(result)
      return nil unless parsed

      @current_room = parsed[:title]
    end

    def record_self_state(name, args, event, turn, iteration)
      return unless name && SelfState.info_self?(name)

      kind = args && (args["kind"] || args[:kind])
      return unless kind

      @self_state[kind] = { text: SelfState.summarize(event["result"]), turn: turn,
                             iteration: iteration, at: event["at"] }
    end

    def extract_text(content)
      case content
      when String
        content
      when Array
        content.map do |block|
          case block["type"]
          when "text"        then block["text"]
          when "tool_use"    then "[tool_use: #{block["name"]}]"
          when "tool_result" then "[tool_result]"
          else block.to_s
          end
        end.join("\n")
      else
        content.to_s
      end
    end

    def numeric(value)
      return nil if value.nil?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def model_label(provider, model)
      return nil if provider.nil? && model.nil?

      [provider, model].compact.join(" / ")
    end

    def point_cost(point)
      return point.cost_usd unless point.cost_usd.nil?

      rates = MODEL_PRICES[point.model || model]
      return nil unless rates

      input_rate  = rates[:input] / 1_000_000.0
      output_rate = rates[:output] / 1_000_000.0
      point.input * input_rate +
        point.output * output_rate +
        point.cache_read * input_rate * 0.1 +
        point.cache_creation * input_rate * 1.25
    end
  end
end
