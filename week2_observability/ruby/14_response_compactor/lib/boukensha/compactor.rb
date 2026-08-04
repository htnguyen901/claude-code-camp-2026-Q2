require "digest"

module Boukensha
  # Compactor shrinks a MUD tool-result string before it goes into
  # @context.messages (Agent#handle_tool_calls), so a session can run more
  # turns before the context window fills. See
  # docs/plans/token_optimization/mud_response_compaction.md for the full
  # design; this is a summary of the invariants that matter here:
  #
  #   - The observability record is untouched. Agent passes the RAW result
  #     to @logger.tool_result and only the COMPACTED string returned here to
  #     @context.add_message — Compactor never sees or affects the log.
  #   - Fail open, always. Any error degrades to the original raw text; a
  #     compaction bug must never be the reason a turn breaks.
  #   - Errors are never compacted: callers must pass `ok: false` for a
  #     failed tool call and get the raw text straight back.
  #   - Scope is hard-scoped to the MUD MCP server's `tbamud__` prefix —
  #     this project targets tbaMUD specifically (see the plan's Open
  #     Questions #1); a future non-MUD MCP server's output is never
  #     touched.
  #
  # Three tiers, always applied in order:
  #   Tier 0 — deterministic normalization (ANSI color codes, the trailing
  #            telnet prompt fragment, blank-line/whitespace noise). Always
  #            on, zero semantic loss.
  #   Tier 1 — structure-aware split of a CircleMUD room echo (title line /
  #            free prose description / "[ Exits: ... ]" line / itemized
  #            "X is here."-style content lines). Always on, no model call —
  #            it only isolates which part (the free prose) is eligible for
  #            Tier 2; title/exits/content lines are reassembled verbatim,
  #            character-for-character, whether or not Tier 2 is enabled.
  #   Tier 2 — LLM-based prose compaction, opt-in (`enabled:`), gated by a
  #            minimum-length check so the common short reply never pays any
  #            latency, and cached by content hash so a revisited room's
  #            byte-identical description is only ever compacted once per
  #            process. Default off until evaluated per the plan's Tier 2
  #            eval section.
  #
  # Tier 2 deliberately reuses boukensha's own Backends::*/Context/
  # PromptBuilder/Client machinery — the exact same one-shot request path
  # Agent uses for a real turn — rather than a bespoke HTTP call to one
  # provider's API. `backend:` is any already-constructed `Backends::*`
  # instance (Anthropic, OpenAI, Gemini, Ollama, OllamaCloud); which one is
  # a config choice (`tasks.compactor.provider`/`model`), not something
  # Compactor decides. This means a Tier 2 compaction call gets the same
  # retry/timeout behavior as every other API call in the codebase, and
  # switching models is just a settings.yaml edit — see the step's README
  # for how.
  class Compactor
    DEFAULT_MIN_CHARS = 400
    DEFAULT_HOST      = "http://localhost:11434"
    DEFAULT_MODEL     = "gemma4"

    # Tier 2 replies are short by design (a few sentences at most) — no need
    # to budget for anything close to a normal turn's output.
    MAX_OUTPUT_TOKENS = 300

    # The MUD MCP server's configured `prefix:` (see .boukensha/settings.yaml
    # mcp_servers.mud.prefix) — hard-scoped per the plan's Open Questions #1
    # rather than derived from config, since this project targets tbaMUD
    # specifically.
    MUD_PREFIX = "tbamud"

    ANSI_RE = /\e\[[0-9;]*[a-zA-Z]/.freeze

    # Matches a whole line that is nothing but the telnet prompt sentinel
    # MudManager::Session reads for (PROMPT_SENTINEL = "> "), optionally
    # preceded by the HP/Mana/Move status CircleMUD prepends to it and/or a
    # parenthesized channel-subscription list (e.g.
    # "22H 100M 84V (news) (motd) > ", or just "(news) (motd) > " when the
    # HP/Mana/Move portion is absent) — grounded in the same real captured
    # shape LogViz::RoomEcho::PROMPT_RE targets. Matched against one line at
    # a time (see #normalize) rather than as a suffix of the whole string:
    # every piece here is optional, so anchoring it at the end of the full
    # text let it match a bare "> " anywhere inside an unrelated trailing
    # line and leave the rest of that line (e.g. "(news) (motd)") behind.
    PROMPT_LINE_RE = /\A[ \t]*(?:\d+H\s+\d+M\s+\d+V\b\s*)?(?:\([^)\n]*\)[ \t]*)*>[ \t]*\z/i.freeze

    # CircleMUD's "[ Exits: n s ]" line (LogViz::RoomEcho's grounded shape);
    # also accepts the unbracketed "Exits: north." shape simpler MUD
    # stand-ins (e.g. MudManager::FakeMud) use.
    EXITS_LINE_RE = /\A\s*\[?\s*Exits:.*\z/i.freeze

    SYSTEM_PROMPT = <<~PROMPT.strip.freeze
      You compact prose from a MUD (text adventure) game reply — a room
      description, combat narration, or social/emote text — into the
      shortest plain-text summary that preserves every fact an agent
      playing the game would need to act correctly: what changed, what's
      notable or actionable, any names/numbers mentioned. Drop flavor
      adjectives and repeated scene-setting. Do not invent anything that
      isn't in the original text. Respond with ONLY the rewritten text, no
      preamble or quotes around it.
    PROMPT

    def initialize(enabled: false, backend: nil, min_chars: DEFAULT_MIN_CHARS)
      @enabled   = enabled
      @backend   = backend
      @min_chars = min_chars.to_i
      @cache     = {}
    end

    # compact(name:, result:, ok:) -> String
    #
    # Returns the text that should be passed to
    # @context.add_message(:tool_result, ...) in place of the raw result.
    # Never raises: any failure degrades to the original raw text.
    def compact(name:, result:, ok:)
      raw = result.to_s
      return raw unless ok
      return raw unless mud_tool?(name)

      structured = split_structure(normalize(raw))
      structured[:prose] = compact_prose(structured[:prose]) if @enabled
      reassemble(structured)
    rescue StandardError => e
      warn "[Boukensha::Compactor] compaction failed (#{e.class}: #{e.message}) — passing through raw result"
      raw
    end

    private

    def mud_tool?(name)
      name.to_s.start_with?("#{MUD_PREFIX}__")
    end

    # ---------- Tier 0: deterministic normalization -------------------------

    def normalize(text)
      lines = text.to_s.gsub(ANSI_RE, "").gsub("\r\n", "\n").split("\n")
      lines.pop if lines.last && lines.last =~ PROMPT_LINE_RE

      out = lines.join("\n")
      out = out.gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n")
      out.strip
    end

    # ---------- Tier 1: structure-aware split --------------------------------

    # { title:, prose:, exits_line:, content_lines: } — title/exits_line are
    # nil and content_lines empty when the text doesn't look like a room echo
    # (combat spam, social text, shop menus, ...); in that case the whole
    # text is the `prose` candidate, since Tier 2 also targets narrated
    # combat/social text, not just room descriptions.
    def split_structure(text)
      lines     = text.split("\n")
      exits_idx = lines.index { |l| l =~ EXITS_LINE_RE }

      return { title: nil, prose: text, exits_line: nil, content_lines: [] } unless exits_idx && exits_idx >= 1

      {
        title: lines[0],
        prose: lines[1...exits_idx].join("\n").strip,
        exits_line: lines[exits_idx],
        content_lines: lines[(exits_idx + 1)..] || []
      }
    end

    def reassemble(structured)
      parts = []
      parts << structured[:title] if structured[:title]
      parts << structured[:prose] unless structured[:prose].to_s.empty?
      parts << structured[:exits_line] if structured[:exits_line]
      parts.concat(structured[:content_lines])
      parts.join("\n")
    end

    # ---------- Tier 2: LLM-based prose compaction ---------------------------

    # Isolated from `compact`'s own rescue so a Tier 2 failure only gives up
    # the model rewrite, not the Tier 0/1 normalization already done — those
    # tiers are zero-risk and must survive even when the backend is
    # unreachable.
    def compact_prose(prose)
      return prose if prose.to_s.length < @min_chars

      key = Digest::SHA256.hexdigest(prose)
      @cache.fetch(key) { @cache[key] = call_model(prose) }
    rescue StandardError => e
      warn "[Boukensha::Compactor] Tier 2 model call failed (#{e.class}: #{e.message}) — leaving prose uncompacted"
      prose
    end

    # One-shot request through the same Context/PromptBuilder/Client path
    # Agent uses for a real turn, against whichever backend was configured —
    # `tools: []` so no tool schema is ever sent for this call.
    def call_model(text)
      ctx = Context.new(system: SYSTEM_PROMPT, context_window: @backend.context_window)
      ctx.add_message(:user, text)

      builder  = PromptBuilder.new(ctx, @backend)
      client   = Client.new(builder)
      response = client.call(tools: [], max_output_tokens: MAX_OUTPUT_TOKENS)
      content  = builder.parse_response(response)[:content]

      reply = content.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join.strip
      reply.empty? ? text : reply
    end
  end
end
