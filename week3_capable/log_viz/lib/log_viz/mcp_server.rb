require "json"
require_relative "world_map"
require_relative "version"

module LogViz
  # A JSON-RPC 2.0 / MCP stdio server (`log_viz --mcp`) — the world-
  # knowledge half of docs/plans/world_knowledge/world_knowledge.md.
  # Structured like MudManager::McpServer
  # (week0_explore/mud_manager/lib/mud_manager/mcp_server.rb): initialize/
  # tools/list/tools/call over stdin/stdout, protocol "2025-06-18". Much
  # smaller — two hand-written tool defs over one read-only WorldMap
  # instance, not a reflected catalog of dozens of MUD commands.
  #
  # Player identity travels via WORLD_MAP_PLAYER, read once at startup —
  # never a tool-call argument the model could fill in or spoof (see the
  # plan's decision 4). nil/absent means "no player identity for this
  # run" — the historical, un-scoped, whole-map-visible behavior, same
  # default WorldMap#room_knowledge/#route_to already use.
  class McpServer
    PROTOCOL_VERSION = "2025-06-18".freeze

    TOOLS = [
      {
        "name" => "room_knowledge",
        "description" => "Check what you know about a room you've discovered: which " \
                          "items/mobs/NPCs/scenery you've already examined (via examine/ " \
                          "look at) versus not yet — each examined entry includes the actual " \
                          "text the room printed back, reuse that as a remembered clue " \
                          "instead of spending a turn re-examining it — plus its exits, each " \
                          "resolved to the room it leads to if you've ever walked it (or " \
                          "`null` if it's a listed exit you've never actually taken). This is " \
                          "a passive record of your own past exploration, not a live scan.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "room_title" => { "type" => "string",
                               "description" => "The exact room title, as it appeared in your most recent look/move result (e.g. 'The Temple Square')." }
          },
          "required" => ["room_title"]
        }
      },
      {
        "name" => "route_to",
        "description" => "Find the shortest known path (a sequence of directions) between " \
                          "two rooms you've discovered, based on exits you've actually " \
                          "walked. Only knows about connections you've personally traveled — " \
                          "if the path you need has never been walked (even if both rooms " \
                          "are individually known), this returns no route.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "from" => { "type" => "string", "description" => "Starting room title (e.g. your current room)." },
            "to"   => { "type" => "string", "description" => "Destination room title." }
          },
          "required" => %w[from to]
        }
      }
    ].freeze

    def initialize(input: $stdin, output: $stdout)
      @input  = input
      @output = output
      @player = present?(ENV["WORLD_MAP_PLAYER"]) ? ENV["WORLD_MAP_PLAYER"] : nil
      @world_map = build_world_map
    end

    def run
      @input.each_line do |line|
        line = line.strip
        next if line.empty?

        dispatch(JSON.parse(line))
      end
    end

    private

    def present?(value)
      !value.to_s.strip.empty?
    end

    def build_world_map
      sessions_dir = ENV["LOG_VIZ_SESSIONS_DIR"] || File.expand_path("../../../../.boukensha/sessions", __dir__)
      db_path      = present?(ENV["LOG_VIZ_WORLD_MAP_DB"]) ? ENV["LOG_VIZ_WORLD_MAP_DB"] : nil
      WorldMap.new(sessions_dir: sessions_dir, db_path: db_path, readonly: true)
    end

    # ---------- JSON-RPC dispatch ----------

    def dispatch(msg)
      id     = msg["id"]
      method = msg["method"].to_s
      case method
      when "initialize"
        respond(id, initialize_result)
      when "tools/list"
        respond(id, { "tools" => TOOLS })
      when "tools/call"
        respond(id, call_tool(msg["params"] || {}))
      when %r{\Anotifications/}
        nil # client-initiated notifications carry no id and need no reply
      else
        respond_error(id, -32601, "method not found: #{method}") if id
      end
    end

    def initialize_result
      {
        "protocolVersion" => PROTOCOL_VERSION,
        "capabilities"    => { "tools" => {} },
        "serverInfo"      => { "name" => "log-viz", "version" => VERSION }
      }
    end

    def call_tool(params)
      name = params["name"].to_s
      args = params["arguments"] || {}
      result, error =
        case name
        when "room_knowledge" then handle_room_knowledge(args)
        when "route_to"       then handle_route_to(args)
        else ["unknown tool '#{name}'", true]
        end
      { "content" => [{ "type" => "text", "text" => result.is_a?(String) ? result : JSON.generate(result) }],
        "isError" => !!error }
    end

    def handle_room_knowledge(args)
      [@world_map.room_knowledge(room_title: args["room_title"].to_s, player: @player), false]
    end

    def handle_route_to(args)
      [@world_map.route_to(from: args["from"].to_s, to: args["to"].to_s, player: @player), false]
    end

    def respond(id, result)
      return unless id

      write("jsonrpc" => "2.0", "id" => id, "result" => result)
    end

    def respond_error(id, code, message)
      write("jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message })
    end

    def write(obj)
      @output.puts(JSON.generate(obj))
      @output.flush
    end
  end
end
