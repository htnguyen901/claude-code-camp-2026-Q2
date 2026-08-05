require "sinatra/base"
require "time"
require "json"
require "cgi"

require_relative "session"
require_relative "ansi"
require_relative "world_map"
require_relative "content_fact"

module LogViz
  class App < Sinatra::Base
    set :root, File.expand_path("../..", __dir__)
    set :sessions_dir, ENV.fetch("LOG_VIZ_SESSIONS_DIR") {
      File.expand_path("../../../../.boukensha/sessions", __dir__)
    }
    set :world_map_db, ENV["LOG_VIZ_WORLD_MAP_DB"]
    # Base URL for the Jaeger UI a turn's trace_id (see Session#parse!'s
    # "turn" case, sourced from Boukensha::Logger#turn — docs/plans/
    # observability/otel_and_logs/00_overview.md "Bridging the two systems")
    # links out to. A link, not a merged pipeline — log_viz never talks to
    # Jaeger's API, it just builds a URL.
    set :jaeger_ui_base, ENV.fetch("LOG_VIZ_JAEGER_UI_BASE") { "http://localhost:16686" }

    LIVE_MARKER_COLORS = %w[#e11d48 #2563eb #16a34a #d97706 #7c3aed #0891b2].freeze

    helpers do
      def session_paths
        Dir.glob(File.join(settings.sessions_dir, "*.jsonl")).sort.reverse
      end

      # Memoized per-process (not per-request) so `refresh!`'s incremental
      # ingestion (player_journey_map.md §2) actually pays off across
      # requests — a fresh WorldMap per request would still only cost O(new
      # data) per refresh, but would also re-open/re-migrate the database
      # every time for no reason.
      def world_map
        WorldMap.instance(sessions_dir: settings.sessions_dir, db_path: settings.world_map_db).tap(&:refresh!)
      end

      def format_time(iso)
        return "?" unless iso

        Time.parse(iso).strftime("%Y-%m-%d %H:%M:%S %z")
      rescue ArgumentError
        iso
      end

      def truncate(text, length = 100)
        flat = text.to_s.gsub(/\s+/, " ").strip
        flat.length > length ? "#{flat[0, length]}…" : flat
      end

      def format_args(args)
        return "" if args.nil? || args.empty?

        args.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")
      end

      def ansi_html(text)
        Ansi.to_html(text)
      end

      # nil for a turn with no trace_id (pre-Phase-2 logs, or any turn whose
      # Logger#turn event predates this field) — session.erb only renders
      # the "View trace" link when this returns non-nil, same
      # graceful-degradation posture as the `compacted`/injected panel.
      def jaeger_trace_url(trace_id)
        return nil if trace_id.to_s.empty?

        "#{settings.jaeger_ui_base}/trace/#{trace_id}"
      end

      def text_html(text)
        Ansi.escape_html(text)
      end

      def fmt_tokens(n)
        n = n.to_i
        n >= 1000 ? format("%.1fk", n / 1000.0) : n.to_s
      end

      def pct(used, max)
        max.to_i.positive? ? [(used.to_f / max.to_i * 100).round, 100].min : 0
      end

      # Uncapped percentage for labels — shows >100% when a budget is exceeded
      # (bar widths still use the clamped `pct`).
      def pct_raw(used, max)
        max.to_i.positive? ? (used.to_f / max.to_i * 100).round : 0
      end

      # A small inline progress bar. `danger` paints it red (limit tripped).
      def progress_bar(used, max, label:, danger: false)
        width = pct(used, max)
        klass = danger ? "bar-fill danger" : "bar-fill"
        <<~HTML
          <div class="budget">
            <div class="budget-label">#{label}</div>
            <div class="bar"><div class="#{klass}" style="width: #{width}%"></div></div>
          </div>
        HTML
      end

      def fmt_cost(n)
        n.nil? ? "&mdash;" : format("$%.4f", n)
      end

      def fmt_cost_cell(cost, known: true)
        return "&mdash;" if cost.nil? || !known

        fmt_cost(cost)
      end

      # In-transcript chip (§2.3): live context size as a mini-bar scaled to the
      # context window, plus the turn spend accumulating toward its cap.
      def ctx_chip(usage, running, context_window:, max_turn_tokens:, model: nil, provider: nil, cost_usd: nil)
        return "" unless usage

        input = usage["input_tokens"].to_i
        out   = usage["output_tokens"].to_i
        cache = Session.cache_tokens(usage, provider)[:read]

        parts = []
        # Turn spend first and bar-backed — it's what trips max_tokens, so it's
        # the signal worth watching fill as you scroll.
        if max_turn_tokens.to_i.positive?
          danger = running.to_i > max_turn_tokens.to_i ? " danger" : ""
          parts << %(<span class="ctx-turn#{danger}">turn #{fmt_tokens(running)}/#{fmt_tokens(max_turn_tokens)}</span>)
          parts << %(<span class="ctx-bar"><span class="ctx-bar-fill#{danger}" style="width: #{pct(running, max_turn_tokens)}%"></span></span>)
        end
        # Live context size second, with a smaller mini-bar.
        parts << %(<span class="ctx-amt">ctx #{fmt_tokens(input)}</span>)
        if context_window.to_i.positive?
          parts << %(<span class="ctx-mini"><span class="ctx-mini-fill" style="width: #{pct(input, context_window)}%"></span></span>)
        end
        parts << %(<span class="ctx-out">+#{fmt_tokens(out)} out</span>)
        parts << %(<span class="ctx-cache">cached #{fmt_tokens(cache)}</span>) if cache.positive?
        parts << %(<span class="ctx-cost">#{fmt_cost(cost_usd)}</span>) unless cost_usd.nil?
        parts << %(<span class="ctx-model">#{[provider, model].compact.join(" / ")}</span>) if provider || model

        %(<span class="ctx-chip">#{parts.join("\n")}</span>)
      end

      # Bucket name -> the CSS custom property carrying its color, shared by
      # the bar segments (public/style.css), the session-wide chart's lines/
      # legend, and this tag's text — one source of truth for "what color is
      # 'tools'" across every composition view.
      COMP_BUCKET_COLORS = {
        "System"   => "var(--comp-system)",
        "Tools"    => "var(--comp-tools)",
        "Messages" => "var(--comp-messages)",
        "Other"    => "var(--comp-other)"
      }.freeze

      # Compact, glanceable composition indicator for the always-visible
      # summary line (§4 revision of the token-composition-observability
      # plan — the original one-line-of-numbers rendering was illegible once
      # a turn has a dozen-plus iterations, each with its own line). A small
      # proportional bar plus the *dominant* bucket's share is the one signal
      # worth reading without a click; full precision (every bucket's exact
      # tokens/%) lives in the bar's native tooltip, and cost lives in
      # `composition_rows`' table in the expanded body. Returns "" when the
      # request has no matching response yet (e.g. the log was truncated
      # mid-call).
      def composition_bar(entry)
        total = entry.comp_input_tokens
        return "" if total.nil? || total.zero?

        buckets = [
          ["System", entry.comp_system_tokens],
          ["Tools", entry.comp_tools_tokens],
          ["Messages", entry.comp_messages_tokens],
          ["Other", entry.comp_other_tokens]
        ]

        segments = buckets.map do |name, tokens|
          %(<span class="comp-bar-seg comp-bar-#{name.downcase}" style="width: #{pct(tokens, total)}%"></span>)
        end.join

        tooltip = buckets.map { |name, tokens| "#{name} #{fmt_tokens(tokens)} (#{pct_raw(tokens, total)}%)" }.join(" &middot; ")
        if entry.comp_cache_read.to_i.positive?
          tooltip += " &middot; cached #{fmt_tokens(entry.comp_cache_read)} (#{pct_raw(entry.comp_cache_read, total)}%)"
        end

        dominant_name, dominant_tokens = buckets.max_by { |_, tokens| tokens.to_i }
        tag = %(<span class="comp-tag" style="color: #{COMP_BUCKET_COLORS[dominant_name]}">#{dominant_name} #{pct_raw(dominant_tokens, total)}%</span>)

        cache_tag = entry.comp_cache_read.to_i.positive? ? %(<span class="comp-cache-tag">cached #{pct_raw(entry.comp_cache_read, total)}%</span>) : ""

        %(<span class="comp-summary" title="#{tooltip}"><span class="comp-bar">#{segments}</span>#{tag}#{cache_tag}</span>)
      end

      # Row data for the expanded-body composition table (§4/§7): plain
      # hashes, formatted by the view the same way @session.cost_breakdown's
      # rows already are — System/Tools/Messages/Other (input, priced at the
      # model's list input rate), Cached (informational — already counted
      # inside whichever bucket it came from, not additive), Output, and a
      # closing Total row. Returns [] when the request has no matching
      # response yet.
      def composition_rows(entry)
        total = entry.comp_input_tokens
        return [] if total.nil?

        rows = [
          { name: "System", tokens: entry.comp_system_tokens, cost: entry.comp_system_cost },
          { name: "Tools", tokens: entry.comp_tools_tokens, cost: entry.comp_tools_cost },
          { name: "Messages", tokens: entry.comp_messages_tokens, cost: entry.comp_messages_cost }
        ]
        rows << { name: "Other", tokens: entry.comp_other_tokens, cost: entry.comp_other_cost } if entry.comp_other_tokens.to_i.positive?
        rows.each { |r| r[:pct] = pct_raw(r[:tokens], total) }

        if entry.comp_cache_read.to_i.positive?
          rows << { name: "Cached (of input)", tokens: entry.comp_cache_read, pct: pct_raw(entry.comp_cache_read, total), cost: nil }
        end

        rows << { name: "Output", tokens: entry.comp_output_tokens, pct: nil, cost: entry.comp_output_cost }
        rows << { name: "Total", tokens: total + entry.comp_output_tokens.to_i, pct: nil, cost: entry.comp_cost_usd, total_row: true }

        rows
      end

      # Builds a query string for the /map pagination/"clear filter" links,
      # dropping nil/blank values so a link never carries an empty
      # `&kind=` param around (room_world_inspector.md §4).
      def build_query(params_hash)
        params_hash.reject { |_, v| v.nil? || v.to_s.empty? }
                   .map { |k, v| "#{CGI.escape(k.to_s)}=#{CGI.escape(v.to_s)}" }
                   .join("&")
      end

      def fmt_bytes(n)
        n = n.to_i
        return "#{n}b" if n < 1024

        format("%.1fkb", n / 1024.0)
      end

      # Char-count delta chip for the "injected into next request" panel — a
      # quick "did compaction actually shrink this" signal without diffing
      # the raw/compacted text by eye. Growth (compacted longer than raw,
      # possible if a Tier 2 model rewrite pads instead of trims) renders as
      # a "+" delta rather than a nonsensical negative shrink.
      def fmt_char_delta(raw_len, compacted_len)
        raw_len       = raw_len.to_i
        compacted_len = compacted_len.to_i
        return "#{compacted_len} chars &middot; unchanged" if raw_len == compacted_len

        delta_pct = raw_len.positive? ? ((raw_len - compacted_len).to_f / raw_len * 100).round : 0
        sign      = delta_pct.negative? ? "+" : "-"
        "#{raw_len} &rarr; #{compacted_len} chars (#{sign}#{delta_pct.abs}%)"
      end

      # Signed delta for the request-growth chip, e.g. "+2" / "-1" / "&plusmn;0".
      def fmt_delta(n)
        return nil if n.nil?
        return "&plusmn;0" if n.zero?

        n.positive? ? "+#{n}" : n.to_s
      end

      # Inline SVG sparkline of per-request message_count across the whole
      # session (call order, not reset per turn) — shows context growth and
      # compaction drops at a glance. `markers` are compaction indices from
      # Session#compaction_markers; wrap-up requests get a distinct dot.
      def request_sparkline(points, markers: [], width: 640, height: 48)
        return "" if points.length < 2

        max  = [points.map { |p| p.message_count.to_i }.max, 1].max
        step = width.to_f / (points.length - 1)

        y_for = ->(p) { (height - (p.message_count.to_f / max * (height - 4)) - 2).round(1) }

        coords = points.each_with_index.map do |p, i|
          "#{(i * step).round(1)},#{y_for.call(p)}"
        end.join(" ")

        boundaries = points.each_with_index.select { |p, i| i.positive? && p.iteration == 1 }
        rules = boundaries.map do |_p, i|
          x = (i * step).round(1)
          %(<line class="spark-turn" x1="#{x}" y1="0" x2="#{x}" y2="#{height}"/>)
        end.join

        marks = markers.select { |i| i < points.length }.map do |i|
          x = (i * step).round(1)
          %(<line class="spark-compaction" x1="#{x}" y1="0" x2="#{x}" y2="#{height}"/>)
        end.join

        dots = points.each_with_index.select { |p, _i| p.wrap_up }.map do |p, i|
          %(<circle class="spark-wrapup" cx="#{(i * step).round(1)}" cy="#{y_for.call(p)}" r="3"/>)
        end.join

        <<~SVG
          <svg class="spark" viewBox="0 0 #{width} #{height}" preserveAspectRatio="none" role="img" aria-label="message count per request">
            #{marks}
            #{rules}
            <polyline class="spark-line" points="#{coords}"/>
            #{dots}
          </svg>
        SVG
      end

      # Inline SVG of the system/tools/messages token split per request,
      # across the whole session (call order, not reset per turn) — the
      # token-level counterpart to `request_sparkline`'s message-count view.
      # Drawn as three overlaid (not stacked) lines so a before/after
      # comparison — e.g. the tools line dropping after a schema trim, or
      # Tier 1 caching shrinking the gap between the tools line and cached
      # portion — reads directly off relative height. `points` is
      # Session#request_series; entries without a matched response yet
      # (nil token fields) plot as zero.
      def composition_sparkline(points, width: 640, height: 96)
        return "" if points.length < 2

        max = [points.flat_map { |p| [p.system_tokens.to_i, p.tools_tokens.to_i, p.messages_tokens.to_i] }.max, 1].max
        step = width.to_f / (points.length - 1)

        line = ->(field) do
          points.each_with_index.map do |p, i|
            y = (height - (p.send(field).to_i.to_f / max * (height - 4)) - 2).round(1)
            "#{(i * step).round(1)},#{y}"
          end.join(" ")
        end

        boundaries = points.each_with_index.select { |p, i| i.positive? && p.iteration == 1 }
        rules = boundaries.map do |_p, i|
          x = (i * step).round(1)
          %(<line class="spark-turn" x1="#{x}" y1="0" x2="#{x}" y2="#{height}"/>)
        end.join

        <<~SVG
          <svg class="spark spark-composition" viewBox="0 0 #{width} #{height}" preserveAspectRatio="none" role="img" aria-label="system/tools/messages tokens per request">
            #{rules}
            <polyline class="spark-line-messages" points="#{line.call(:messages_tokens)}"/>
            <polyline class="spark-line-tools" points="#{line.call(:tools_tokens)}"/>
            <polyline class="spark-line-system" points="#{line.call(:system_tokens)}"/>
          </svg>
        SVG
      end

      # Inline SVG sparkline of per-iteration input_tokens across the session.
      # `points` is the Session#usage_series; faint vertical lines mark turn
      # boundaries, a notch marks compactions. No JS, no chart library.
      def sparkline(points, max:, width: 640, height: 48)
        return "" if points.length < 2

        max = 1 if max.to_i < 1
        step = width.to_f / (points.length - 1)

        coords = points.each_with_index.map do |p, i|
          x = (i * step).round(1)
          y = (height - (p.input.to_f / max * (height - 4)) - 2).round(1)
          "#{x},#{y}"
        end.join(" ")

        # Faint vertical rule at each turn's first iteration (after turn 1).
        boundaries = points.each_with_index.select { |p, i| i.positive? && p.iteration == 1 }
        rules = boundaries.map do |_p, i|
          x = (i * step).round(1)
          %(<line class="spark-turn" x1="#{x}" y1="0" x2="#{x}" y2="#{height}"/>)
        end.join

        <<~SVG
          <svg class="spark" viewBox="0 0 #{width} #{height}" preserveAspectRatio="none" role="img" aria-label="input tokens per iteration">
            #{rules}
            <polyline class="spark-line" points="#{coords}"/>
          </svg>
        SVG
      end

      # Compact per-session path glyph for the /players/:name Sessions table
      # (world_map_enhancer.md §5) — "speed up progression of the path...
      # display room as node, no room name required." Deliberately not a
      # scaled-down `map_svg`: no boxes, no labels, no pan/zoom, just one
      # dot per visit in order, evenly spaced left-to-right and connected by
      # a line, same family as `sparkline`/`request_sparkline` above. A
      # revisited room reuses the same dot color (cycled from
      # `LIVE_MARKER_COLORS`) so a there-and-back-again pattern is visible
      # at a glance; the room's name is still available via each dot's
      # `<title>` tooltip. Clicking the glyph (handled by the caller, not
      # this helper) goes to the full interactive time-lapse on
      # /sessions/:id — this is a preview, not a replacement for it.
      def session_path_glyph(visits, width: 160, height: 28)
        return "" if visits.empty?

        step = visits.length > 1 ? width.to_f / (visits.length - 1) : 0
        y = (height / 2.0).round(1)
        distinct = visits.map { |v| v[:room_title] }.uniq

        coords = visits.each_index.map { |i| "#{(i * step).round(1)},#{y}" }.join(" ")
        dots = visits.each_with_index.map do |v, i|
          x = (i * step).round(1)
          color = LIVE_MARKER_COLORS[distinct.index(v[:room_title]) % LIVE_MARKER_COLORS.length]
          %(<circle class="path-glyph-dot" cx="#{x}" cy="#{y}" r="3" style="fill: #{color}"><title>#{text_html(v[:room_title])}</title></circle>)
        end.join

        <<~SVG
          <svg class="path-glyph" viewBox="0 0 #{width} #{height}" width="#{width}" height="#{height}" role="img" aria-label="rooms visited this session, in order">
            <polyline class="path-glyph-line" points="#{coords}"/>
            #{dots}
          </svg>
        SVG
      end

      # Inline location tag on a session-page tool entry (player_journey_map
      # .md §3/§4) — a simple "reached this room" marker, not a new/revisit
      # distinction (that needs the cross-session history only WorldMap has,
      # and lives on /map instead).
      def location_badge(room_title)
        return "" unless room_title

        %(<span class="loc-badge">&rarr; #{text_html(room_title)}</span>)
      end

      # Room-node box size (world_map_visualization.md §1) — fixed, not
      # text-measured (SVG text can't be measured server-side in Ruby
      # without a browser). Overlap between adjacent rooms is prevented by
      # construction: a constant box size plus grid spacing (`map_svg`'s
      # `cell`/`margin` defaults) wider than the box, not by measuring
      # anything. The label itself is `truncate`d to fit; the full title
      # always stays available via the `<title>` hover tooltip and the
      # click-to-inspect panel (§3), never only on the truncated label.
      MAP_NODE_BOX_W = 130
      MAP_NODE_BOX_H = 36
      MAP_NODE_LABEL_CHARS = 18

      # HTML-attribute-safe escaping (adds quote-escaping on top of
      # `text_html`/`Ansi.escape_html`, which only handles `&`/`<`/`>` —
      # needed here because room titles are interpolated inside a
      # double-quoted `data-room="..."` attribute, not just element text).
      def attr_html(text)
        text_html(text).gsub('"', "&quot;")
      end

      # Inline SVG node-link graph of the accumulated world map
      # (player_journey_map.md §2/§4, redesigned per
      # world_map_visualization.md). Room coordinates are precomputed and
      # stored by `WorldMap` from real compass directions, so this is pure
      # rendering — no layout algorithm. Each room renders as a fixed-size
      # labeled box (not a dot+adjacent-label) wrapped in a plain `<a
      # href="/map?room=...">` so clicking a room does something useful
      # (jumps to that room's pre-filtered discoveries/rooms tables) even
      # without JS; `map.erb`'s script progressively enhances that click
      # into an inline detail panel instead of a full navigation. The
      # `<svg>` itself gets explicit pixel `width`/`height` (not just
      # `viewBox`) so `.map-scroll`'s `overflow: auto` produces real
      # scrollbars on a map bigger than its container, instead of the
      # browser shrinking the whole `viewBox` to fit.
      # Rendering-only vertical fan-out gap for rooms that share the
      # identical stored coordinate (see `map_svg`'s cluster-disambiguation
      # comment below). Vertical, not horizontal: `cell`'s grid spacing is
      # 160px but a box is 130px *wide* and only 36px *tall*, so a
      # horizontal fan wide enough to separate 3+ clustered siblings (an
      # earlier version of this fix used one) eats most of the 30px of
      # horizontal slack to the next grid column and collides with whatever
      # unrelated room already lives there — verified against real data:
      # that version *raised* the total overlap count (9 → 11), not lowered
      # it. A vertical fan has ~124px of headroom to the next grid row
      # before the same problem recurs (160 cell − 36 box height), so a
      # small fixed gap comfortably clears it even for a several-room
      # cluster. Still just a fixed offset, not a real layout algorithm.
      MAP_CLUSTER_FAN_GAP = MAP_NODE_BOX_H + 8

      # Generic pairwise overlap resolution (below), for any two boxes that
      # still end up too close after grid placement + cluster fan-out —
      # e.g. a fanned cluster member landing near an unrelated neighbor,
      # or (in principle) two independent fan-outs interacting. Bounded,
      # deterministic passes; see `resolve_node_overlaps!`.
      MAP_OVERLAP_PASSES = 6
      MAP_OVERLAP_PADDING = 6

      # Pushes any two still-overlapping room boxes (after grid placement +
      # cluster fan-out, both above) apart along whichever axis needs the
      # smaller nudge to clear — a standard minimum-translation AABB
      # separation, run for a bounded number of passes rather than to a
      # convergence guarantee. `order` fixes the pairwise-processing order
      # (titles, sorted) so the result is stable across requests — `rooms`
      # itself has no `ORDER BY` in `WorldMap#rooms`, and this is a greedy
      # relaxation whose outcome depends on processing order. Mutates
      # `positions` (title => [x, y]) in place.
      def resolve_node_overlaps!(positions, order)
        min_gap_x = MAP_NODE_BOX_W + MAP_OVERLAP_PADDING
        min_gap_y = MAP_NODE_BOX_H + MAP_OVERLAP_PADDING

        MAP_OVERLAP_PASSES.times do
          moved = false

          order.each_with_index do |title_a, i|
            order[(i + 1)..].each do |title_b|
              ax, ay = positions[title_a]
              bx, by = positions[title_b]
              dx, dy = bx - ax, by - ay
              overlap_x = min_gap_x - dx.abs
              overlap_y = min_gap_y - dy.abs
              next unless overlap_x.positive? && overlap_y.positive?

              moved = true
              if overlap_x < overlap_y
                push = overlap_x / 2.0 + 0.1
                push = -push if dx.negative?
                positions[title_a][0] -= push
                positions[title_b][0] += push
              else
                push = overlap_y / 2.0 + 0.1
                push = -push if dy.negative?
                positions[title_a][1] -= push
                positions[title_b][1] += push
              end
            end
          end

          break unless moved
        end
      end

      # Room `exits` (RoomEcho.parse) are single-letter abbreviations as
      # printed by the MUD ("[ Exits: n s e ]"), but `WorldMap::
      # DIRECTION_DELTA` is keyed by the full compass words a `move` tool
      # call's `direction` arg actually uses ("north") — this is the
      # translation between the two vocabularies, needed only for the
      # unexplored-neighbor stub synthesis below (map_svg never otherwise
      # reads `exits` for real placement; `WorldMap#assign_coordinate`
      # already gets full words directly from the tool call).
      EXIT_DIRECTION_WORDS = {
        "n" => "north", "s" => "south", "e" => "east", "w" => "west",
        "u" => "up", "d" => "down"
      }.freeze

      MAP_NODE_UNEXPLORED_R = 14

      # session_id: nil (default, and mutually exclusive with player:) draws
      # the full accumulated map. A session_id restricts nodes to only the
      # rooms that one session's own `visits` reached, and derives edges
      # from that session's actual room-to-room transitions (in visit
      # order) instead of the global, cross-session `edges` table — two
      # sessions can share a global edge without either having *personally*
      # taken it in this order, which would misrepresent "this session's
      # own path" (see docs/plans/observability/players/
      # multiple_concurrent_players.md §4's per-session time-lapse panel).
      # `player:` (world_map_enhancer.md §5) restricts nodes to
      # `world_map.rooms_visited_by(player)` and edges to the global `edges`
      # table filtered to pairs where both endpoints are in that set — a
      # deliberate approximation (that player's explored *subgraph*, not
      # their real ordered path across possibly many sessions; the
      # session-scoped map above is what draws a real ordered path). Room
      # coordinates are still the same global, stable ones
      # `rooms.coord_x/coord_y` already hold in every scope — only which
      # nodes/edges are drawn changes. Nodes get a `data-seq` visit-order
      # badge only in the session_id: scope (visit order is only
      # well-defined for one session); no live-session markers are drawn in
      # either scoped mode, only on the full map.
      def map_svg(world_map, cell: 160, margin: 90, session_id: nil, player: nil)
        if session_id
          session_visits  = world_map.visits_for(session_id)
          visited_titles  = session_visits.map { |v| v[:room_title] }.uniq
          rooms = world_map.rooms.select { |r| r[:coord] && visited_titles.include?(r[:title]) }
        elsif player
          visited_titles = world_map.rooms_visited_by(player)
          rooms = world_map.rooms.select { |r| r[:coord] && visited_titles.include?(r[:title]) }
        else
          rooms = world_map.rooms.select { |r| r[:coord] }
        end
        return "" if rooms.empty?

        xs = rooms.map { |r| r[:coord][0] }
        ys = rooms.map { |r| r[:coord][1] }
        min_x, min_y = xs.min, ys.min

        raw_px = ->(x) { (x - min_x) * cell }
        raw_py = ->(y) { (y - min_y) * cell }

        # `WorldMap#assign_coordinate` places rooms from real compass deltas
        # (world_map.rb), not a collision-free layout — it's a "documented
        # simplification," not a bug, but it does mean two differently
        # -explored paths can coincidentally compute the identical (x, y)
        # (confirmed against real data: 5 rooms share coordinates with 1-2
        # others out of 45 total). Left alone, that would render as fully
        # overlapping, unclickable boxes — a rendering defect, since this
        # plan's whole point is boxes that don't overlap "by construction."
        # Fix at the rendering layer only (per "Not doing: any layout
        # algorithm change" — `assign_coordinate` itself is untouched): a
        # fixed, deterministic vertical fan-out around the shared point for
        # any coordinate with more than one room at it, followed by a
        # generic overlap-resolution pass (below) as a safety net.
        positions = {}
        rooms.group_by { |r| r[:coord] }.each_value do |group|
          base_x, base_y = raw_px.call(group.first[:coord][0]), raw_py.call(group.first[:coord][1])
          group.sort_by { |r| r[:title] }.each_with_index do |r, i|
            offset = (i - (group.length - 1) / 2.0) * MAP_CLUSTER_FAN_GAP
            positions[r[:title]] = [base_x, base_y + offset]
          end
        end

        resolve_node_overlaps!(positions, rooms.map { |r| r[:title] }.sort)

        # Unexplored-neighbor stubs (world_map_enhancer.md §2) — full
        # accumulated map only (session_id/player both nil); a session- or
        # player-scoped replay stays exactly what was actually visited, per
        # `map_svg`'s own doc above. Purely a rendering-time synthesis: for
        # every visited room's parsed `exits`, compute the neighbor
        # coordinate via the same DIRECTION_DELTA table `assign_coordinate`
        # uses for real placement; if no room occupies that coordinate,
        # remember it as a stub (deduped by coordinate — multiple rooms can
        # exit toward the same unvisited neighbor). No `rooms` row is ever
        # created, nothing is stored.
        stub_targets = {}
        if session_id.nil? && player.nil?
          by_coord = rooms.each_with_object({}) { |r, h| h[r[:coord]] = r }
          rooms.each do |r|
            r[:exits].each do |abbrev|
              direction = EXIT_DIRECTION_WORDS[abbrev.to_s.downcase]
              delta = direction && WorldMap::DIRECTION_DELTA[direction]
              next unless delta

              coord = [r[:coord][0] + delta[0], r[:coord][1] + delta[1]]
              next if by_coord[coord] # already a real, placed room — don't draw a stub on top of it

              stub_targets[coord] ||= { direction: direction, from_title: r[:title] }
            end
          end
        end

        stub_positions = stub_targets.keys.each_with_object({}) do |coord, h|
          h[coord] = [raw_px.call(coord[0]), raw_py.call(coord[1])]
        end

        # Canvas bounds are derived from the actual (post-fan-out)
        # `positions` plus any unexplored stubs, not re-derived from grid
        # math — the fan-out above deliberately perturbs some rooms off
        # their nominal grid cell, so the ground truth for "how big does
        # this canvas need to be" is where things actually ended up, padded
        # by half a box plus the standard margin on every side. Stubs are
        # included here too so a real room's unvisited exit at the map's
        # edge doesn't get clipped by a canvas sized only for visited rooms.
        half_w = MAP_NODE_BOX_W / 2.0
        half_h = MAP_NODE_BOX_H / 2.0
        all_px = positions.values.map(&:first) + stub_positions.values.map(&:first)
        all_py = positions.values.map(&:last) + stub_positions.values.map(&:last)
        min_px, max_px = all_px.minmax
        min_py, max_py = all_py.minmax

        shift_x, shift_y = margin - min_px + half_w, margin - min_py + half_h
        positions.each_value { |pos| pos[0] = (pos[0] + shift_x).round(1); pos[1] = (pos[1] + shift_y).round(1) }
        stub_positions.each_value { |pos| pos[0] = (pos[0] + shift_x).round(1); pos[1] = (pos[1] + shift_y).round(1) }

        svg_w = (max_px + shift_x + half_w + margin).round(1)
        svg_h = (max_py + shift_y + half_h + margin).round(1)

        by_title = rooms.each_with_object({}) { |r, h| h[r[:title]] = r }

        edges_source =
          if session_id
            session_visits.each_cons(2).filter_map do |a, b|
              next if a[:room_title] == b[:room_title]

              { from: a[:room_title], via: b[:arrived_via], to: b[:room_title] }
            end.uniq { |e| [e[:from], e[:via], e[:to]] }
          elsif player
            world_map.edges.select { |e| visited_titles.include?(e[:from]) && visited_titles.include?(e[:to]) }
          else
            world_map.edges
          end

        edges = edges_source.filter_map do |e|
          from, to = positions[e[:from]], positions[e[:to]]
          next unless from && to

          %(<line class="map-edge" x1="#{from[0]}" y1="#{from[1]}" )+
          %(x2="#{to[0]}" y2="#{to[1]}"><title>#{text_html(e[:from])} #{text_html(e[:via])} &rarr; #{text_html(e[:to])}</title></line>)
        end.join

        stubs = stub_targets.map do |coord, info|
          x, y = stub_positions[coord]
          <<~STUB
            <g class="map-node-unexplored">
              <circle class="map-node-unexplored-circle" cx="#{x}" cy="#{y}" r="#{MAP_NODE_UNEXPLORED_R}"/>
              <text class="map-node-unexplored-glyph" x="#{x}" y="#{y + 5}" text-anchor="middle">?</text>
              <title>#{text_html(info[:direction])} of #{text_html(info[:from_title])} &middot; not yet visited</title>
            </g>
          STUB
        end.join

        nodes = rooms.map do |r|
          x, y = positions[r[:title]]
          href = "/map?#{build_query(room: r[:title], room_q: r[:title])}"
          seq  = session_id ? visited_titles.index(r[:title]) + 1 : nil
          badge = seq ? %(<circle class="map-node-seq-badge" cx="#{-half_w + 2}" cy="#{-half_h + 2}" r="9"/>)+
                        %(<text class="map-node-seq" x="#{-half_w + 2}" y="#{-half_h + 5}" text-anchor="middle">#{seq}</text>) : ""
          <<~NODE
            <a href="#{href}" class="map-node-link">
              <g class="map-node" data-room="#{attr_html(r[:title])}" transform="translate(#{x}, #{y})">
                <rect class="map-node-box" x="#{-half_w}" y="#{-half_h}" width="#{MAP_NODE_BOX_W}" height="#{MAP_NODE_BOX_H}" rx="6"/>
                <text class="map-node-label" x="0" y="4" text-anchor="middle">#{text_html(truncate(r[:title], MAP_NODE_LABEL_CHARS))}</text>
                #{badge}
                <title>#{text_html(r[:title])} &middot; visited #{r[:visit_count]}&times;</title>
              </g>
            </a>
          NODE
        end.join

        markers =
          if session_id || player
            ""
          else
            world_map.live_sessions.each_with_index.filter_map do |s, i|
              room = s[:last_room] && by_title[s[:last_room]]
              next unless room

              x, y = positions[room[:title]]
              color = LIVE_MARKER_COLORS[i % LIVE_MARKER_COLORS.length]
              label = [s[:task], s[:model]].compact.join(" / ")
              <<~MARKER
                <circle class="map-live-marker" cx="#{x}" cy="#{y}" r="12" style="stroke: #{color}">
                  <title>#{text_html(s[:session_id])} &middot; #{text_html(label)} &middot; turn #{s[:turn]} iter #{s[:iteration]}</title>
                </circle>
              MARKER
            end.join
          end

        svg_scope_class = session_id ? "map-svg-session" : (player ? "map-svg-player" : nil)
        svg_class = ["map-svg", svg_scope_class].compact.join(" ")
        <<~SVG
          <svg class="#{svg_class}" width="#{svg_w}" height="#{svg_h}" viewBox="0 0 #{svg_w} #{svg_h}" role="img" aria-label="world map">
            #{edges}
            #{stubs}
            #{nodes}
            #{markers}
          </svg>
        SVG
      end
    end

    get "/" do
      @sessions = session_paths.map { |path| Session.load(path) }
      wm = world_map
      @wm_sessions = wm.sessions.each_with_object({}) { |s, h| h[s[:session_id]] = s }
      @wm_live_ids = wm.live_sessions.map { |s| s[:session_id] }
      erb :index
    end

    get "/sessions/:id" do
      id   = File.basename(params[:id])
      path = File.join(settings.sessions_dir, "#{id}.jsonl")
      halt 404, "Session not found: #{id}" unless File.file?(path)

      @session    = Session.load(path)
      @world_map  = world_map
      @visits     = @world_map.visits_for(@session.id)
      erb :session
    end

    # Player roster (docs/plans/observability/players/
    # multiple_concurrent_players.md §3/§4) — one card per distinct tagged
    # `sessions.player`. Untagged (player: NULL) sessions never appear here;
    # they still show up on / same as always.
    get "/players" do
      wm = world_map
      @players = wm.players.map do |row|
        sessions = wm.sessions.select { |s| s[:player] == row[:player] }
                     .filter_map { |s| Session.load(s[:path]) if s[:path] && File.file?(s[:path]) }
        row.merge(
          rooms_discovered: wm.rooms_visited_by(row[:player]).length,
          total_input_tokens: sessions.sum(&:total_input_tokens),
          total_output_tokens: sessions.sum(&:total_output_tokens),
          total_cost: sessions.filter_map(&:estimated_cost).sum
        )
      end
      erb :players
    end

    get "/players/:name" do
      name = params[:name]
      wm   = world_map
      @summary = wm.player_summary(name)
      halt 404, "No sessions found for player: #{name}" if @summary[:sessions].empty?

      # Cost/token totals reuse Session's existing per-session computation
      # (see Session#estimated_cost/#total_input_tokens) rather than
      # recomputing token accounting here — same "cost math lives in
      # Session" boundary player_journey_map.md already established.
      @sessions  = @summary[:sessions].filter_map { |s| Session.load(s[:path]) if s[:path] && File.file?(s[:path]) }
      @world_map = wm
      # Per-session visit lists for the Sessions table's compact path glyph
      # (world_map_enhancer.md §5) — cheap, already-indexed `visits_for`
      # queries, same accessor the full time-lapse panel on /sessions/:id
      # already uses, just computed once per row here instead.
      @visits_by_session = @sessions.each_with_object({}) { |s, h| h[s.id] = wm.visits_for(s.id) }
      erb :player
    end

    PAGE_SIZE = 50

    # World Map overview (room_world_inspector.md §4/§5, trimmed by
    # world_map_enhancer.md §4): the live-sessions banner/table and the
    # zoomable/searchable map SVG itself. The Rooms/Discoveries tables that
    # used to live inline here now have their own pages (`/map/rooms`,
    # `/map/discoveries`, below) — this handler only needs the summary
    # counts its two "N rooms discovered ->"/"N discoveries ->" links show,
    # not the PAGE_SIZE-bounded queries those pages run themselves.
    get "/map" do
      @world_map = world_map
      @discoveries_count = @world_map.discoveries(limit: nil).length
      @live = @world_map.live_sessions
      erb :map
    end

    # Rooms table, split out of /map (world_map_enhancer.md §4) so the map
    # page itself isn't cluttered by it. `room_titles:` (optional,
    # world_map_enhancer.md §5) scopes this same view to one player's own
    # visited rooms for /players/:name/rooms below — @scope_player is only
    # set on that route.
    get "/map/rooms" do
      @world_map    = world_map
      @room_q       = params[:room_q]
      @rooms_before = params[:rooms_before]
      @rooms = @world_map.rooms_matching(q: @room_q, before: @rooms_before, limit: PAGE_SIZE)
      @next_rooms_before = @rooms.last[:first_seen][:at] if @rooms.length == PAGE_SIZE
      erb :rooms
    end

    # Discoveries table, split out of /map the same way. `q`/`kind`/`room`/
    # `examined` filter, `before` is the keyset-pagination cursor — same
    # params /map's form used to post here.
    get "/map/discoveries" do
      @world_map = world_map
      @q        = params[:q]
      @kind     = params[:kind]
      @room     = params[:room]
      @examined = case params[:examined]
                  when "1" then true
                  when "0" then false
                  end
      @before   = params[:before]

      @discoveries = @world_map.discoveries(q: @q, kind: @kind, room: @room, examined: @examined,
                                             before: @before, limit: PAGE_SIZE)
      @next_before = @discoveries.last[:first_seen_at] if @discoveries.length == PAGE_SIZE

      @room_titles = @world_map.rooms.map { |r| r[:title] }.sort
      @kinds       = LogViz::ContentFact::KINDS + ["unknown"]
      erb :discoveries
    end

    # Player-scoped Rooms/Discoveries — the "Knowledge" section's drill-down
    # pages (world_map_enhancer.md §5). Reuses rooms.erb/discoveries.erb
    # verbatim with an extra @scope_player local rather than forking new
    # templates: same tables, same filter/search/pagination behavior, just
    # pre-scoped to `world_map.rooms_visited_by(name)` via the `room_titles:`
    # allowlist those two WorldMap methods gained for exactly this.
    get "/players/:name/rooms" do
      name = params[:name]
      @world_map    = world_map
      @scope_player = name
      @room_q       = params[:room_q]
      @rooms_before = params[:rooms_before]
      @rooms = @world_map.rooms_matching(q: @room_q, before: @rooms_before, limit: PAGE_SIZE,
                                          room_titles: @world_map.rooms_visited_by(name))
      @next_rooms_before = @rooms.last[:first_seen][:at] if @rooms.length == PAGE_SIZE
      erb :rooms
    end

    get "/players/:name/discoveries" do
      name = params[:name]
      @world_map    = world_map
      @scope_player = name
      @q        = params[:q]
      @kind     = params[:kind]
      @room     = params[:room]
      @examined = case params[:examined]
                  when "1" then true
                  when "0" then false
                  end
      @before   = params[:before]

      visited = @world_map.rooms_visited_by(name)
      @discoveries = @world_map.discoveries(q: @q, kind: @kind, room: @room, examined: @examined,
                                             before: @before, limit: PAGE_SIZE, room_titles: visited)
      @next_before = @discoveries.last[:first_seen_at] if @discoveries.length == PAGE_SIZE

      @room_titles = visited.sort
      @kinds       = LogViz::ContentFact::KINDS + ["unknown"]
      erb :discoveries
    end

    # Polling endpoint for /map's live-update script (room_world_inspector
    # .md §5) — live session markers plus "N new since `since`" counters for
    # rooms/discoveries, so the page can patch itself without a full reload.
    # No SSE/held-open connection (deliberately rejected for this scope, see
    # the plan) — just a cheap, already-indexed query per poll.
    get "/map/live.json" do
      content_type :json
      wm = world_map

      by_title = wm.rooms.each_with_object({}) { |r, h| h[r[:title]] = r if r[:coord] }
      live = wm.live_sessions.map do |s|
        room = s[:last_room] && by_title[s[:last_room]]
        {
          session_id: s[:session_id], task: s[:task],
          provider: s[:provider], model: s[:model],
          room: s[:last_room], coord: room && room[:coord],
          turn: s[:turn], iteration: s[:iteration]
        }
      end

      since = params[:since]
      new_rooms       = since ? wm.rooms.count { |r| r[:first_seen][:at].to_s > since } : 0
      new_discoveries = since ? wm.discoveries(limit: nil).count { |d| d[:first_seen_at].to_s > since } : 0

      JSON.generate(live: live, new_rooms: new_rooms, new_discoveries: new_discoveries, at: Time.now.utc.iso8601)
    end

    # Room detail for the map's click-to-inspect panel
    # (world_map_visualization.md §3) — the same fields the Rooms/
    # Discoveries tables already render, scoped to one room. Purely a read
    # over WorldMap accessors that already existed for those tables
    # (`#rooms`, `#discoveries`); no new WorldMap method needed. The `<a
    # href="/map?room=...">` every map node is wrapped in (see `map_svg`)
    # is the no-JS fallback for this same information — this endpoint only
    # exists so map.erb's script can render it inline instead of
    # navigating away.
    get "/map/rooms/:title.json" do
      content_type :json
      wm    = world_map
      title = params[:title]
      room  = wm.rooms.find { |r| r[:title] == title }
      halt 404, JSON.generate(error: "Room not found: #{title}") unless room

      discoveries = wm.discoveries(room: title, limit: nil).map do |d|
        {
          subject: d[:subject] || d[:content], content: d[:content], kind: d[:kind],
          examined: d[:examined], examination_result: d[:examination_result]
        }
      end

      JSON.generate(
        title: room[:title], description: room[:description], exits: room[:exits],
        visit_count: room[:visit_count], first_seen_at: room[:first_seen][:at],
        discoveries: discoveries
      )
    end
  end
end
