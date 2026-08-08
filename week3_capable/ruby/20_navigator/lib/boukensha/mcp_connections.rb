require_relative "tools/mcp"

module Boukensha
  # Connects to every configured MCP server exactly once per session, and
  # lets any number of tasks each register that same catalog onto their own
  # Registry, filtered by their own ToolPolicy — see docs/plans/tools_policy/
  # mcp_connection_sharing.md. Splits what Tools::Mcp.register used to
  # conflate (spawn + register) into two independently-callable phases:
  # connecting (once, here, at construction) and registering (as many times
  # as there are tasks, via #register).
  #
  # A server that's stateful on login (mud-manager, tied to one character)
  # would otherwise mean a second login per task that wants its tools — this
  # is what makes "one connection per server per session" hold regardless of
  # how many tasks (Player, Judge, Planner, ...) end up using it.
  class McpConnections
    def self.connect(cfg, servers: nil)
      new(servers || cfg.mcp_servers)
    end

    def initialize(server_entries)
      @entries = {}
      server_entries.each do |name, entry|
        client = Tools::Mcp.connect(command: entry[:command], args: entry[:args], env: entry[:env])
        @entries[name] = { client: client, prefix: entry[:prefix] }
      rescue StandardError => e
        raise "boukensha: MCP server '#{name}' failed to start: #{e.message}" if entry[:required]
        warn "[boukensha] optional MCP server '#{name}' failed to start: #{e.message} — continuing without its tools"
      end
    end

    # Registers every connected server's tools onto `registry`, filtered by
    # whatever policy `registry` was built with. Safe to call more than once
    # (once per task) against the same connections — no new spawn, no new
    # handshake, no new login; each call is just a fresh pass of
    # Registry#tool (and therefore that task's own ToolPolicy) over the
    # already-fetched catalog.
    def register(registry)
      @entries.each_value { |e| Tools::Mcp.register_client(registry, e[:client], prefix: e[:prefix]) }
    end

    # {name => tool_count} — for Repl's servers_status_string banner.
    def summary
      @entries.transform_values { |e| e[:client].tools.size }
    end

    def close
      @entries.each_value { |e| e[:client].close rescue nil }
    end
  end
end
