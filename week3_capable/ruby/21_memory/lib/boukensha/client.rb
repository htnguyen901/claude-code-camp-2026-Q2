require "net/http"
require "json"
require "openssl"

module Boukensha
  class Client
    RETRYABLE_STATUS_CODES = [408, 409, 429, 500, 502, 503, 504].freeze
    TRANSIENT_ERRORS = [
      EOFError,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Net::OpenTimeout,
      Net::ReadTimeout,
      OpenSSL::SSL::SSLError,
      SocketError,
      Timeout::Error
    ].freeze
    MAX_RETRIES = 3
    BASE_RETRY_DELAY = 0.5

    def initialize(builder)
      @builder = builder
    end

    # iteration:/task: are purely for span/metric labels (see the overview's
    # attribute table) — instrumenting once here, rather than at each of
    # Agent#run/Agent#wrap_up/Compactor#call_model's call sites, means every
    # caller's llm_request span nests correctly under whatever span is
    # current when it calls in, for free.
    def call(max_output_tokens: 1024, tools: nil, payload: nil, iteration: nil, task: nil)
      payload ||= @builder.to_api_payload(max_output_tokens: max_output_tokens, tools: tools)
      backend  = @builder.backend
      provider = backend.provider_name
      model    = backend.model

      Boukensha.tracer.in_span("boukensha.llm_request", attributes: {
        "gen_ai.system"        => provider,
        "gen_ai.request.model" => model,
        "boukensha.iteration"  => iteration
      }.compact) do |span|
        started_at  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result      = perform_request(payload)
        duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000

        Metrics.llm_request_duration.record(duration_ms, attributes: { "provider" => provider, "model" => model })
        Metrics.llm_requests.add(1, attributes: { "provider" => provider, "model" => model, "task" => task&.to_s }.compact)
        annotate_response(span, backend, result, provider: provider, model: model, task: task)
        result
      rescue ApiError
        Metrics.errors.add(1, attributes: { "kind" => "api_error" })
        raise
      end
    end

    private

    def perform_request(payload)
      uri          = URI(@builder.url)
      http         = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      # NOTE: Originally set to OpenSSL::X509::DEFAULT_CERT_FILE for macOS compatibility,
      # but that path (/usr/lib/ssl/cert.pem) doesn't exist on Linux/WSL2.
      # Omitting ca_file lets OpenSSL find system certs automatically on all platforms.
      # http.ca_file = OpenSSL::X509::DEFAULT_CERT_FILE

      request      = Net::HTTP::Post.new(uri, @builder.headers)
      request.body = payload.to_json

      attempts = 0
      response = nil

      loop do
        attempts += 1

        begin
          response = http.request(request)
        rescue *TRANSIENT_ERRORS => e
          raise ApiError, "API request failed after #{attempts} attempts: #{e.class}: #{e.message}" if attempts > MAX_RETRIES

          sleep retry_delay(attempts)
          next
        end

        if retryable_response?(response) && attempts <= MAX_RETRIES
          sleep retry_delay(attempts)
          next
        end

        break
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise ApiError, "API request failed after #{attempts} attempt#{'s' unless attempts == 1} (#{response.code}): #{response.body}"
      end

      JSON.parse(response.body)
    end

    # gen_ai.usage.*/boukensha.cost_usd on the span, plus the token/cost
    # counters — all from the one already-parsed response, so a caller never
    # pays for parsing it twice.
    def annotate_response(span, backend, result, provider:, model:, task:)
      input_tokens, output_tokens = extract_tokens(result)
      span.set_attribute("gen_ai.usage.input_tokens", input_tokens) if input_tokens
      span.set_attribute("gen_ai.usage.output_tokens", output_tokens) if output_tokens

      finish_reason = @builder.parse_response(result)[:stop_reason]
      span.set_attribute("gen_ai.response.finish_reason", finish_reason) if finish_reason

      Metrics.llm_tokens.add(input_tokens, attributes: { "provider" => provider, "model" => model, "direction" => "input" }) if input_tokens
      Metrics.llm_tokens.add(output_tokens, attributes: { "provider" => provider, "model" => model, "direction" => "output" }) if output_tokens
      return unless input_tokens && output_tokens

      cost = backend.estimate_cost(input_tokens: input_tokens, output_tokens: output_tokens)
      return unless cost

      span.set_attribute("boukensha.cost_usd", cost)
      Metrics.llm_cost.add(cost, attributes: { "provider" => provider, "model" => model, "task" => task&.to_s }.compact)
    end

    # Provider response shapes disagree on usage field names (see backends/*)
    # — mirrors Logger#usage_tokens's own fallback list, since Client sees
    # the raw response before any backend gets a chance to normalize it.
    def extract_tokens(result)
      usage = result["usage"] || {}
      [
        first_integer(usage, "input_tokens", "prompt_tokens", "promptTokenCount", "prompt_eval_count"),
        first_integer(usage, "output_tokens", "completion_tokens", "candidatesTokenCount", "eval_count")
      ]
    end

    def first_integer(hash, *keys)
      keys.each do |key|
        value = hash[key] || hash[key.to_sym]
        return Integer(value) unless value.nil?
      end
      nil
    rescue ArgumentError, TypeError
      nil
    end

    def retryable_response?(response)
      RETRYABLE_STATUS_CODES.include?(response.code.to_i)
    end

    def retry_delay(attempt)
      BASE_RETRY_DELAY * (2**(attempt - 1))
    end
  end
end
