require_relative "tool"
require_relative "message"

module Boukensha
  class Context
    # Fixed wording for the "## Active Route" block effective_system folds
    # in whenever `route` is set — see docs/plans/agent_loop/
    # player_route_adherence.md §3b. A static constant (not parsed from or
    # checked against the route text) so the enforcement instruction only
    # ever enters the payload alongside an actual route to enforce.
    ROUTE_INSTRUCTION = <<~TEXT.strip
      You asked for and received this route — treat it as a committed sequence,
      not a suggestion: execute each hop in order via tbamud__move before doing
      anything else, and check the result of each move against what you expected
      before issuing the next hop. If a move doesn't take you where this says it
      would, stop and consult_navigator again with your new current room rather
      than improvising the rest of the way.
    TEXT

    ROUTE_FOOTER = <<~TEXT.strip
      (Cleared automatically once you ask consult_navigator again, or you can
      treat it as done once you've reached the destination.)
    TEXT

    attr_reader :system, :messages, :tools, :context_window, :working_dir,
                :turn_tokens, :compaction_threshold
    attr_accessor :current_tokens, :plan, :route

    def initialize(system:, context_window: 200_000, working_dir: nil, compaction_threshold: 0.85)
      @system               = system
      @context_window       = context_window
      @working_dir          = working_dir ? File.expand_path(working_dir) : nil
      @compaction_threshold = compaction_threshold
      @messages             = []
      @tools                = {}
      @current_tokens       = 0
      @turn_tokens          = 0
    end

    def register_tool(tool)
      @tools[tool.name] = tool
    end

    # The system prompt actually sent to the model: `system` plus, once a
    # Planner has run, the current plan, plus, once a route has been
    # consulted, the active route — each appended as its own block. Every
    # backend must read this instead of `system` directly — see
    # docs/plans/agent_loop/orchestrator.md §2 (plan) and
    # docs/plans/agent_loop/player_route_adherence.md §3b (route). A
    # nil/blank plan or route is a no-op for that block, so a session that
    # never plans/navigates gets a byte-identical payload.
    def effective_system
      parts = [system]
      parts << "## Current Plan\n#{plan}" unless plan.nil? || plan.strip.empty?
      parts << "## Active Route\n#{ROUTE_INSTRUCTION}\n\n#{route}\n\n#{ROUTE_FOOTER}" unless route.nil? || route.strip.empty?
      parts.join("\n\n")
    end

    def add_message(role, content, tool_use_id: nil)
      @messages << Message.new(role, content, tool_use_id)
    end

    # Update the known context size from the last API response's input_tokens.
    def update_tokens(n)
      @current_tokens = n.to_i
    end

    # Reset the cumulative per-turn spend counter. Called at the top of a turn.
    def reset_turn_tokens
      @turn_tokens = 0
    end

    # Add one API call's input+output tokens to the cumulative per-turn total.
    # This is the spend budget — distinct from current_tokens (window pressure).
    def add_turn_tokens(input, output)
      @turn_tokens += input.to_i + output.to_i
    end

    # Fraction of the context window currently in use (0.0–1.0).
    def usage_fraction
      @context_window > 0 ? @current_tokens.to_f / @context_window : 0.0
    end

    # Integer percentage (0–100).
    def usage_pct
      (usage_fraction * 100).round
    end

    # True when we should compact before the next API call. Defaults to the
    # configured compaction_threshold (a fraction of context_window).
    def needs_compaction?(threshold: compaction_threshold)
      usage_fraction >= threshold
    end

    # Drop the oldest 40% of messages to free space, keeping at least 2.
    # Resets current_tokens to 0 (will be updated by the next API response).
    # Pairing-safe (see #safe_drop_count) — never separates a tool_use-bearing
    # :assistant message from its own :tool_result(s), docs/plans/memory/
    # context_lifecycle.md §2/§3c. Returns the number of messages dropped.
    def compact_messages!(target_fraction: 0.60)
      drop_count = [(@messages.size * 0.40).ceil, @messages.size - 2].min
      drop_count = [drop_count, 0].max
      drop_count = safe_drop_count(drop_count)
      @messages = @messages.drop(drop_count)
      @current_tokens = 0
      drop_count
    end

    # Mechanical, checkpoint-triggered trim — docs/plans/memory/
    # context_lifecycle.md §3b. Keeps only the most recent `tail` messages
    # (the in-progress exchange plus a fixed window), dropping everything
    # older than that once a Judge checkpoint has already captured whatever
    # preceded it elsewhere (a fresh plan, a Chronicler digest). Pairing-safe
    # like #compact_messages! — shares the same #safe_drop_count boundary
    # logic, so it never separates a tool_use-bearing :assistant message from
    # its own :tool_result(s) either. Unlike #compact_messages!, this is not
    # a token-pressure response, so it does not reset current_tokens — the
    # next API response will refresh it regardless. Returns the number of
    # messages dropped (0 when there's nothing to trim).
    def checkpoint_trim!(tail: 20)
      drop_count = [@messages.size - tail, 0].max
      drop_count = safe_drop_count(drop_count)
      @messages = @messages.drop(drop_count)
      drop_count
    end

    # Drop all conversation history, keeping tools and system prompt intact.
    def clear_messages!
      @messages = []
      @current_tokens = 0
    end

    def tool_count = @tools.size
    def turn_count = @messages.size

    def to_s
      "#<Context turns=#{turn_count} tools=#{tool_count} window=#{context_window} current=#{current_tokens}>"
    end

    private

    # Every contiguous tool_use/tool_result group in @messages, as inclusive
    # index ranges: one :assistant message carrying one or more tool_use
    # content blocks (Agent#handle_tool_calls), followed immediately by up to
    # that many :tool_result messages. Used by #safe_drop_count so a trim
    # never cuts through the middle of one — see docs/plans/memory/
    # context_lifecycle.md §2.
    def tool_use_groups
      groups = []
      i = 0
      while i < @messages.size
        msg = @messages[i]
        tool_use_count = (msg.role == :assistant && msg.content.is_a?(Array)) ? msg.content.count { |b| b["type"] == "tool_use" } : 0

        if tool_use_count.positive?
          j = i + 1
          found = 0
          while j < @messages.size && found < tool_use_count && @messages[j].role == :tool_result
            found += 1
            j += 1
          end
          groups << (i..(j - 1))
          i = j
        else
          i += 1
        end
      end
      groups
    end

    # Adjusts a naive drop_count (number of oldest messages to drop) to the
    # nearest boundary that doesn't land inside a tool_use_groups range —
    # i.e. one that either drops a tool_use/tool_result group entirely or
    # keeps it entirely, never half of it. Ties round up (drop the whole
    # group) since a trim's purpose is to free space. drop_count values that
    # already fall on a boundary (including 0 or @messages.size) pass
    # through unchanged.
    def safe_drop_count(drop_count)
      tool_use_groups.each do |range|
        next unless drop_count > range.first && drop_count <= range.last

        start_dist = drop_count - range.first
        end_dist   = (range.last + 1) - drop_count
        return end_dist <= start_dist ? range.last + 1 : range.first
      end
      drop_count
    end
  end
end
