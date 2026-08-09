require "net/http"
require "uri"
require "json"
require "digest"

module LogViz
  # Structured LLM extraction, two shapes:
  #   .extract(raw)             — one room-content line ("A fountain is
  #                                here, bubbling merrily.") -> one
  #                                {subject, kind, clause}.
  #   .extract_mentions(desc)   — a room's free-form *description* paragraph
  #                                -> zero or more mentions worth examining
  #                                that were narrated in prose rather than
  #                                itemized as their own line (see
  #                                room_world_inspector.md "Follow-up:
  #                                description-embedded mentions").
  #   Both documented at docs/plans/observability/room_world_inspector.md §1.
  #
  # Regex-based extraction ("Tier A") was scoped out per explicit feedback on
  # that plan: real CircleMUD long-descriptions don't reliably put the head
  # noun first ("A large fountain carved from blue-streaked marble" — is the
  # head "fountain" or "marble"?), so this goes straight to a local LLM
  # ("Tier B") for every line. Latency is accepted (see plan feedback #1);
  # cost is not a concern — Ollama is local compute, zero `cost_per_million`
  # (mirrors `Session::MODEL_PRICES`'s ollama rows).
  #
  # One HTTP call per *unique* raw string/description (caller is responsible
  # for caching — see `WorldMap`'s `content_facts`/`room_description_scans`
  # tables), never per sighting/visit.
  module ContentFact
    KINDS = %w[item mob npc scenery].freeze

    # `host`/`model` defaults here are the last-resort fallback for direct
    # callers (tests, `.extract(raw)` with no args). Real callers
    # (`WorldMap`'s background worker and `bin/backfill_content_facts`) get
    # `host`/`model` from `LogViz::Settings` (`.boukensha/settings.yaml`'s
    # `tasks.content_fact` block), not from these constants — see
    # `settings.rb` for why the config moved there.
    DEFAULT_HOST  = "http://localhost:11434"
    DEFAULT_MODEL = "gemma4"

    # Ollama's *first* call after the daemon starts (or after a model's ~5m
    # idle keep-alive expires) pays a one-time cold-load cost — loading
    # weights onto the GPU/warming CUDA kernels — before it serves any
    # response, separate from actual generation time. Measured directly
    # against gemma4 (9.6GB) on this project's dev box: ~50s cold
    # (load_duration ~20s + prompt_eval_duration ~30s from Ollama's own
    # response timing), then ~1s once warm. A short timeout here doesn't
    # just fail that one call — since the background worker marks a string
    # "fallback"/unknown permanently on any failure (see WorldMap, no
    # retry-on-timeout), a too-short timeout silently and irreversibly
    # blanks out classification for everything the worker touches right
    # after Ollama restarts. 120s gives real headroom above the measured
    # cold-load cost while still failing well before it'd be mistaken for a
    # hang.
    TIMEOUT_SECONDS = 120

    PROMPT = <<~PROMPT.freeze
      Extract structured JSON from this single line of MUD (text adventure)
      room-content description. Identify the main noun (subject) being
      described, what kind of thing it is, and any trailing descriptive
      clause (what it's doing/its state).

      Respond with ONLY a JSON object of this exact shape, no other text:
      {"subject": "<short head noun phrase, e.g. 'fountain' not 'large fountain carved from blue-streaked marble'>", "kind": "item"|"mob"|"npc"|"scenery", "clause": "<trailing descriptive clause, or null>"}

      Line: %<raw>s
    PROMPT

    # See room_world_inspector.md "Follow-up": a room's free-form
    # description paragraph can narrate inspectable things in passing
    # ("A small note hangs on the wall.") that never get their own itemized
    # `room_contents` line (CircleMUD only itemizes trailing "X is here"
    # style lines after `[ Exits: ... ]`) — those were previously silently
    # invisible to the whole discoveries/examined-tracking pipeline. This
    # prompt asks for zero-or-more mentions instead of exactly one, with a
    # verbatim "quote" so each becomes its own room_contents-style entry.
    MENTION_PROMPT = <<~PROMPT.freeze
      This is the narrative description of a MUD (text adventure) room —
      NOT the separate "X is here"/"X stands here" bullet lines, just the
      prose paragraph. List every distinct inspectable item, mob, NPC, or
      scenery element mentioned within it that a player might reasonably
      `examine`/`look at` for more information — including things
      mentioned only in passing (e.g. "a small note hangs on the wall",
      "items are stacked on shelves"), not just an obvious focal point.
      Do not invent anything that isn't actually in the text. If nothing
      in it is worth examining, respond with an empty array.

      Respond with ONLY a JSON array, no other text — even if there is only
      one match, it must still be wrapped in an array: [{...}]. Never
      respond with a single bare object. Each array element:
      {"quote": "<the exact sentence or clause mentioning it, verbatim from the text>", "subject": "<short head noun>", "kind": "item"|"mob"|"npc"|"scenery", "clause": "<other descriptive info, or null>"}

      Room description: %<description>s
    PROMPT

    def self.content_hash(raw)
      Digest::SHA256.hexdigest(raw.to_s)
    end

    # Never raises. An unreachable Ollama daemon or a malformed reply
    # degrades to kind: "unknown" (source: "fallback") rather than blocking
    # ingestion — same "never let an observability feature break ingestion"
    # posture as `WorldMap`'s corrupt-DB recovery.
    def self.extract(raw, host: DEFAULT_HOST, model: DEFAULT_MODEL)
      reply  = call_ollama(format(PROMPT, raw: raw), host: host, model: model)
      parsed = JSON.parse(reply)

      {
        subject: normalize_subject(parsed["subject"], raw),
        kind: normalize_kind(parsed["kind"]),
        clause: parsed["clause"]&.to_s,
        source: "llm"
      }
    rescue StandardError => e
      warn "[LogViz::ContentFact] extraction failed (#{e.class}: #{e.message}) — " \
           "leaving #{raw.to_s[0, 60].inspect} unclassified"
      { subject: raw.to_s, kind: "unknown", clause: nil, source: "fallback" }
    end

    # Never raises. Returns `{ mentions: [...], source: "llm" | "fallback" }`
    # — deliberately the same "source" signal as `.extract`, not just a bare
    # array, so a caller can tell "genuinely asked and found nothing" apart
    # from "never actually got to ask" (an empty array alone can't carry
    # that distinction, and WorldMap's retry logic depends on it — see
    # `WorldMap#next_unscanned_room`).
    def self.extract_mentions(description, host: DEFAULT_HOST, model: DEFAULT_MODEL)
      reply  = call_ollama(format(MENTION_PROMPT, description: description), host: host, model: model)
      parsed = JSON.parse(reply)
      raw_mentions = as_mention_array(parsed)
      raise "reply wasn't a JSON array (or object containing one): #{reply.to_s[0, 100]}" if raw_mentions.nil?

      mentions = raw_mentions.filter_map do |m|
        next nil unless m.is_a?(Hash)

        quote = m["quote"].to_s.strip
        next nil if quote.empty?
        # Real-world failure mode against gemma4, caught by running the
        # backfill against the actual 45-room world_map.sqlite3: despite the
        # prompt explicitly requiring a *verbatim* quote, the model
        # occasionally still invents one — observed once producing "a small
        # note hangs on the wall" for a room whose description never
        # mentions a note at all (it had bled in from a *different* room's
        # description, presumably pattern-matched from training data rather
        # than actually read). Since the prompt itself demands verbatim
        # text, holding the reply to that same standard is a legitimate
        # check, not guesswork — a quote that isn't actually substring-
        # present in the source is dropped rather than trusted.
        next nil unless quote_in_description?(quote, description)

        { quote: quote[0, 500], subject: normalize_subject(m["subject"], quote), kind: normalize_kind(m["kind"]),
          clause: m["clause"]&.to_s }
      end

      { mentions: mentions, source: "llm" }
    rescue StandardError => e
      warn "[LogViz::ContentFact] mention extraction failed (#{e.class}: #{e.message}) — " \
           "no mentions extracted for #{description.to_s[0, 60].inspect}"
      { mentions: [], source: "fallback" }
    end

    # Ollama's `format: "json"` guarantees *valid* JSON, not a specific
    # top-level shape — a small model asked for "a JSON array" sometimes
    # still wraps it (`{"mentions": [...]}`), so accept either: a bare
    # array, or a Hash whose first Array-valued key is used. Anything else
    # (a bare object with no array inside, a string, etc.) is nil, treated
    # as a failure by the caller — never guessed at.
    def self.as_mention_array(parsed)
      return parsed if parsed.is_a?(Array)
      return nil unless parsed.is_a?(Hash)

      # Observed in practice against real gemma4 replies for nearly every
      # room tested: despite the prompt explicitly saying "always wrap in
      # an array, even for one match," the model still very often collapses
      # straight to the one bare mention object instead
      # ({"quote": "...", "subject": "...", ...} with no wrapping array).
      # A hash with a "quote" key IS a single mention — treat it as a
      # one-element array rather than treating this extremely common case
      # as a failure.
      return [parsed] if parsed.key?("quote")

      parsed.values.find { |v| v.is_a?(Array) }
    end
    private_class_method :as_mention_array

    # Case-insensitive, whitespace-collapsed substring check — not exact
    # equality, since the model may reproduce a quote with slightly
    # different internal spacing than the source (e.g. after Ollama's own
    # JSON round-trip) without that meaning it invented the content.
    def self.quote_in_description?(quote, description)
      squeeze = ->(s) { s.to_s.downcase.gsub(/\s+/, " ").strip }
      squeeze.call(description).include?(squeeze.call(quote))
    end
    private_class_method :quote_in_description?

    def self.normalize_subject(subject, raw)
      s = subject.to_s.strip
      s.empty? ? raw.to_s : s[0, 200]
    end
    private_class_method :normalize_subject

    def self.normalize_kind(kind)
      KINDS.include?(kind) ? kind : "unknown"
    end
    private_class_method :normalize_kind

    def self.call_ollama(prompt, host:, model:)
      uri  = URI.join(host.end_with?("/") ? host : "#{host}/", "api/generate")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = TIMEOUT_SECONDS
      http.read_timeout = TIMEOUT_SECONDS

      request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
      request.body = JSON.generate(model: model, stream: false, format: "json", prompt: prompt)

      response = http.request(request)
      raise "ollama returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)["response"]
    end
    private_class_method :call_ollama
  end
end
