require "json"
require_relative "session"
require_relative "primitives"
require_relative "tool_catalog"
require_relative "version"

module MudManager
  # A JSON-RPC 2.0 / MCP stdio server (`mud-manager --mcp`). This is the
  # generic protocol layer this project needed so that any MCP host — the
  # Ruby `boukensha` agent, a Python agent, anything that can spawn a
  # subprocess and speak JSON-RPC over stdin/stdout — can drive a MUD
  # session without reimplementing MudManager::Session's telnet handling.
  #
  # One process can hold several logged-in characters at once: every
  # gameplay tool takes an optional `session_id` (default "default"), and
  # `connect`/`disconnect` open and close additional sessions. If
  # MUD_NAME/MUD_PASSWORD are present in the environment at startup, the
  # "default" session logs in eagerly — the same env-credentials
  # convention every other `mcp_servers:` entry in boukensha uses.
  class McpServer
    PROTOCOL_VERSION = "2025-06-18".freeze
    DEFAULT_SESSION  = "default".freeze

    class Error < StandardError; end

    def initialize(input: $stdin, output: $stdout)
      @input       = input
      @output      = output
      @sessions    = {}
      @sessions_mu = Mutex.new
    end

    def run
      open_default_session_from_env
      @input.each_line do |line|
        line = line.strip
        next if line.empty?

        dispatch(JSON.parse(line))
      end
    ensure
      @sessions_mu.synchronize { @sessions.each_value { |s| s.close rescue nil } }
    end

    private

    def open_default_session_from_env
      name = ENV["MUD_NAME"]
      pass = ENV["MUD_PASSWORD"]
      return unless name && pass

      opts = {}
      opts[:host] = ENV["MUD_HOST"] if ENV["MUD_HOST"]
      opts[:port] = ENV["MUD_PORT"].to_i if ENV["MUD_PORT"] && !ENV["MUD_PORT"].empty?
      connect_session(DEFAULT_SESSION, name: name, password: pass, **opts)
    end

    def connect_session(session_id, name:, password:, **opts)
      raise Error, "session '#{session_id}' already connected" if @sessions.key?(session_id)

      session = Session.new(**opts).open
      session.login(name, password)
      @sessions_mu.synchronize { @sessions[session_id] = session }
      session
    end

    def create_character_session(session_id, name:, password:, sex:, char_class:, **opts)
      raise Error, "session '#{session_id}' already connected" if @sessions.key?(session_id)

      session = Session.new(**opts).open
      session.create_character(name, password, sex: sex, char_class: char_class)
      @sessions_mu.synchronize { @sessions[session_id] = session }
      session
    end

    # ---------- JSON-RPC dispatch ----------

    def dispatch(msg)
      id     = msg["id"]
      method = msg["method"].to_s
      case method
      when "initialize"
        respond(id, initialize_result)
      when "tools/list"
        respond(id, { "tools" => tool_definitions })
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
        "serverInfo"      => { "name" => "mud-manager", "version" => MudManager::VERSION }
      }
    end

    def tool_definitions
      ToolCatalog.tools.map { |t| tool_json(t) } + session_lifecycle_tools
    end

    def tool_json(spec)
      { "name" => spec[:name], "description" => spec[:description], "inputSchema" => spec[:input_schema] }
    end

    def session_lifecycle_tools
      [
        {
          "name" => "connect",
          "description" => "Log a new character into the MUD and register its session under " \
                            "an id so other tools can address it via `session_id`.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "session_id" => { "type" => "string", "description" => "id to register this session under" },
              "name"       => { "type" => "string", "description" => "character name" },
              "password"   => { "type" => "string", "description" => "character password" },
              "host"       => { "type" => "string", "description" => "MUD host (default: #{Session::DEFAULT_HOST})" },
              "port"       => { "type" => "integer", "description" => "MUD port (default: #{Session::DEFAULT_PORT})" }
            },
            "required" => %w[session_id name password]
          }
        },
        {
          "name" => "disconnect",
          "description" => "Close a previously-opened session.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "session_id" => { "type" => "string", "description" => "session to close (default: \"default\")" }
            },
            "required" => []
          }
        },
        {
          "name" => "create_character",
          "description" => "Create a brand-new character and register its session under an id so " \
                            "other tools can address it via `session_id`. Fails if the name is " \
                            "already taken — use `connect` for an existing character instead.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "session_id" => { "type" => "string", "description" => "id to register this session under" },
              "name"       => { "type" => "string", "description" => "new character name" },
              "password"   => { "type" => "string", "description" => "password to set for the new character" },
              "sex"        => { "type" => "string", "description" => "\"M\" or \"F\"" },
              "char_class" => { "type" => "string", "description" => "class menu letter: \"C\" Cleric, \"T\" Thief, \"W\" Warrior, \"M\" Magic-user" },
              "host"       => { "type" => "string", "description" => "MUD host (default: #{Session::DEFAULT_HOST})" },
              "port"       => { "type" => "integer", "description" => "MUD port (default: #{Session::DEFAULT_PORT})" }
            },
            "required" => %w[session_id name password sex char_class]
          }
        },
        {
          "name" => "delete_character",
          "description" => "Permanently delete the character behind an already-connected session " \
                            "(via `connect` or `create_character`), then close that session.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "session_id" => { "type" => "string", "description" => "session whose character to delete (default: \"default\")" },
              "password"   => { "type" => "string", "description" => "character password, re-verified by the server" }
            },
            "required" => %w[password]
          }
        }
      ]
    end

    def call_tool(params)
      name = params["name"].to_s
      args = params["arguments"] || {}
      text, error =
        case name
        when "connect"          then handle_connect(args)
        when "disconnect"       then handle_disconnect(args)
        when "create_character" then handle_create_character(args)
        when "delete_character" then handle_delete_character(args)
        else handle_primitive(name, args)
        end
      { "content" => [{ "type" => "text", "text" => text }], "isError" => !!error }
    end

    def handle_connect(args)
      session_id = (args["session_id"] || DEFAULT_SESSION).to_s
      opts = {}
      opts[:host] = args["host"] if args["host"]
      opts[:port] = Integer(args["port"]) if args["port"]
      connect_session(session_id, name: args["name"].to_s, password: args["password"].to_s, **opts)
      ["connected session '#{session_id}'", false]
    rescue Session::Error, Error, ArgumentError => e
      [format_error(e), true]
    end

    def handle_disconnect(args)
      session_id = (args["session_id"] || DEFAULT_SESSION).to_s
      session = @sessions_mu.synchronize { @sessions.delete(session_id) }
      return ["no such session '#{session_id}'", true] unless session

      session.close
      ["disconnected '#{session_id}'", false]
    end

    def handle_create_character(args)
      session_id = (args["session_id"] || DEFAULT_SESSION).to_s
      opts = {}
      opts[:host] = args["host"] if args["host"]
      opts[:port] = Integer(args["port"]) if args["port"]
      create_character_session(
        session_id,
        name: args["name"].to_s, password: args["password"].to_s,
        sex: args["sex"].to_s, char_class: args["char_class"].to_s,
        **opts
      )
      ["created and connected session '#{session_id}'", false]
    rescue Session::Error, Error, ArgumentError => e
      [format_error(e), true]
    end

    def handle_delete_character(args)
      session_id = (args["session_id"] || DEFAULT_SESSION).to_s
      session = @sessions_mu.synchronize { @sessions[session_id] }
      return ["no such session '#{session_id}' — call connect or create_character first", true] unless session

      session.delete_character(args["password"].to_s)
      @sessions_mu.synchronize { @sessions.delete(session_id) }
      session.close
      ["deleted character and closed session '#{session_id}'", false]
    rescue Session::Error => e
      [format_error(e), true]
    end

    def handle_primitive(name, args)
      spec = ToolCatalog.find(name)
      return ["unknown tool '#{name}'", true] unless spec

      session_id = (args["session_id"] || DEFAULT_SESSION).to_s
      session = @sessions_mu.synchronize { @sessions[session_id] }
      return ["no such session '#{session_id}' — call connect first", true] unless session

      command = ToolCatalog.build(spec, args)
      [session.command(command), false]
    rescue ArgumentError => e
      [format_error(e), true]
    rescue Session::Error => e
      [format_error(e), true]
    end

    def format_error(e)
      "#{tag_for(e.class)}: #{e.message}"
    end

    def tag_for(klass)
      klass.name.split("::").last.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
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
