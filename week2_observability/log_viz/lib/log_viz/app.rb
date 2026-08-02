require "sinatra/base"
require "time"
require "json"

require_relative "session"
require_relative "ansi"
require_relative "world_map"

module LogViz
  class App < Sinatra::Base
    set :root, File.expand_path("../..", __dir__)
    set :sessions_dir, ENV.fetch("LOG_VIZ_SESSIONS_DIR") {
      File.expand_path("../../../../.boukensha/sessions", __dir__)
    }
    set :world_map_db, ENV["LOG_VIZ_WORLD_MAP_DB"]

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

      def fmt_bytes(n)
        n = n.to_i
        return "#{n}b" if n < 1024

        format("%.1fkb", n / 1024.0)
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

      # Inline location tag on a session-page tool entry (player_journey_map
      # .md §3/§4) — a simple "reached this room" marker, not a new/revisit
      # distinction (that needs the cross-session history only WorldMap has,
      # and lives on /map instead).
      def location_badge(room_title)
        return "" unless room_title

        %(<span class="loc-badge">&rarr; #{text_html(room_title)}</span>)
      end

      # Inline SVG node-link graph of the accumulated world map
      # (player_journey_map.md §2/§4). Room coordinates are precomputed and
      # stored by `WorldMap` from real compass directions, so this is pure
      # rendering — no layout algorithm, no JS, same house style as the
      # sparkline helpers above.
      def map_svg(world_map, cell: 90, margin: 70)
        rooms = world_map.rooms.select { |r| r[:coord] }
        return "" if rooms.empty?

        xs = rooms.map { |r| r[:coord][0] }
        ys = rooms.map { |r| r[:coord][1] }
        min_x, max_x = xs.min, xs.max
        min_y, max_y = ys.min, ys.max

        svg_w = ((max_x - min_x) * cell + margin * 2).round(1)
        svg_h = ((max_y - min_y) * cell + margin * 2).round(1)

        px = ->(x) { ((x - min_x) * cell + margin).round(1) }
        py = ->(y) { ((y - min_y) * cell + margin).round(1) }

        by_title = rooms.each_with_object({}) { |r, h| h[r[:title]] = r }

        edges = world_map.edges.filter_map do |e|
          from, to = by_title[e[:from]], by_title[e[:to]]
          next unless from && to

          %(<line class="map-edge" x1="#{px.call(from[:coord][0])}" y1="#{py.call(from[:coord][1])}" )+
          %(x2="#{px.call(to[:coord][0])}" y2="#{py.call(to[:coord][1])}"><title>#{text_html(e[:from])} #{text_html(e[:via])} &rarr; #{text_html(e[:to])}</title></line>)
        end.join

        nodes = rooms.map do |r|
          x, y = px.call(r[:coord][0]), py.call(r[:coord][1])
          <<~NODE
            <g class="map-node" transform="translate(#{x}, #{y})">
              <circle r="7" class="map-node-dot"/>
              <text class="map-node-label" x="10" y="4">#{text_html(r[:title])}</text>
              <title>#{text_html(r[:title])} &middot; visited #{r[:visit_count]}&times;</title>
            </g>
          NODE
        end.join

        live = world_map.live_sessions
        markers = live.each_with_index.filter_map do |s, i|
          room = s[:last_room] && by_title[s[:last_room]]
          next unless room

          x, y = px.call(room[:coord][0]), py.call(room[:coord][1])
          color = LIVE_MARKER_COLORS[i % LIVE_MARKER_COLORS.length]
          label = [s[:task], s[:model]].compact.join(" / ")
          <<~MARKER
            <circle class="map-live-marker" cx="#{x}" cy="#{y}" r="12" style="stroke: #{color}">
              <title>#{text_html(s[:session_id])} &middot; #{text_html(label)} &middot; turn #{s[:turn]} iter #{s[:iteration]}</title>
            </circle>
          MARKER
        end.join

        <<~SVG
          <svg class="map-svg" viewBox="0 0 #{svg_w} #{svg_h}" role="img" aria-label="world map">
            #{edges}
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

      @session = Session.load(path)
      erb :session
    end

    get "/map" do
      @world_map   = world_map
      @rooms       = @world_map.rooms.sort_by { |r| r[:first_seen][:at].to_s }
      @discoveries = @world_map.discoveries
      @live        = @world_map.live_sessions
      erb :map
    end
  end
end
