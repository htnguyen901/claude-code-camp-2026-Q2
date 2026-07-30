require_relative "primitives"

module MudManager
  # Reflects MudManager::Primitives' public methods into MCP tool
  # definitions and back again. There is deliberately no hand-maintained
  # list of tools: every public method module_function on Primitives
  # becomes a tool, so a new primitive is automatically a new tool with no
  # change needed here.
  #
  # Two small pieces of hand-authored metadata sit on top of that
  # reflection, because they can't be recovered from the method signature
  # alone:
  #
  #   ENUM_PARAMS — which parameter of which primitive is constrained to a
  #   fixed set of values. These mirror the same constants Primitives'
  #   check_enum! validates against (DIRECTIONS, POSITIONS, ...), so the
  #   tool schema and the runtime validation can't drift apart.
  #
  #   INTEGER_PARAMS — the two parameters Primitives itself requires to be
  #   an Integer (Primitives raises ArgumentError otherwise). MCP arguments
  #   arrive as strings; these get coerced before dispatch.
  #
  #   DEFAULTS — ergonomic defaults for required parameters an agent will
  #   usually omit. `attack` requires a style, but "kill" is what an agent
  #   means by "attack" in the overwhelming majority of calls, so it's
  #   optional here even though Primitives.attack itself requires it.
  module ToolCatalog
    ENUM_PARAMS = {
      move: { direction: Primitives::DIRECTIONS },
      set_position: { pos: Primitives::POSITIONS },
      attack: { style: Primitives::ATTACK_STYLES },
      skill_strike: { skill: Primitives::STRIKE_SKILLS },
      say_local: { mode: Primitives::LOCAL_SAY },
      say_targeted: { mode: Primitives::TARGETED_SAY },
      say_channel: { channel: Primitives::CHANNELS },
      report_player: { kind: Primitives::REPORT_KINDS },
      drop: { mode: Primitives::DROP_MODES },
      equip: { slot_op: Primitives::EQUIP_OPS },
      consume: { mode: Primitives::CONSUME_MODES },
      transfer_liquid: { mode: Primitives::LIQUID_MODES },
      door: { verb: Primitives::DOOR_VERBS, direction: Primitives::DIRECTIONS },
      look: { mode: Primitives::LOOK_MODES, preposition: Primitives::LOOK_PREPS },
      info_self: { kind: Primitives::INFO_SELF },
      info_world: { kind: Primitives::INFO_WORLD },
      list_commands: { kind: Primitives::LIST_KINDS },
      set_color: { level: Primitives::COLOR_LEVELS },
      toggle_pref: { flag: Primitives::PREF_FLAGS },
      stealth: { mode: Primitives::STEALTH_MODES },
      use_magic_item: { mode: Primitives::SPELL_ITEM },
      group_manage: { op: Primitives::GROUP_OPS },
      shop: { op: Primitives::SHOP_OPS },
      bank: { op: Primitives::BANK_OPS },
      mail: { op: Primitives::MAIL_OPS }
    }.freeze

    INTEGER_PARAMS = {
      split_gold: [:amount],
      set_wimpy: [:hp]
    }.freeze

    DEFAULTS = {
      attack: { style: "kill" }
    }.freeze

    # Hand-authored overrides for tools whose auto-generated description
    # ("MudManager primitive `look` (mode, target, preposition)") doesn't say
    # enough for an agent to use them correctly.
    DESCRIPTIONS = {
      look: "Look at your surroundings — call with no arguments (or omit target/preposition) " \
            "for a plain room look. To look at/in/on something specific, set `target` and " \
            "(optionally) `preposition`. `preposition` only makes sense together with " \
            "`target`; a bare `look at` with nothing to look at is not a valid MUD command."
    }.freeze

    # Per-tool argument cleanup that can't be expressed as a JSON Schema
    # constraint: `look`'s `preposition` is only meaningful paired with a
    # `target`. An agent that sends `preposition: "at"` with an empty/absent
    # `target` means "just look", not the literal (invalid) MUD command
    # "look at" — so preposition is dropped rather than forwarded verbatim.
    NORMALIZERS = {
      look: lambda { |kw| kw.delete(:preposition) if kw[:target].to_s.strip.empty? }
    }.freeze

    # Every gameplay tool gets this in addition to its Primitives-derived
    # parameters, so one daemon process can hold more than one logged-in
    # character (see McpServer#connect / #disconnect).
    SESSION_PARAM = {
      "type" => "string",
      "description" => "Which connected session (see the `connect` tool) to act on. Defaults to \"default\"."
    }.freeze

    def self.tools
      primitive_names.map { |name| build_spec(name) }
    end

    def self.find(name)
      return nil unless name
      sym = name.to_sym
      return nil unless primitive_names.include?(sym)
      build_spec(sym)
    end

    def self.primitive_names
      Primitives.methods(false).sort
    end

    def self.build_spec(name)
      params     = Primitives.method(name).parameters
      enums      = ENUM_PARAMS[name] || {}
      defaults   = DEFAULTS[name] || {}
      properties = {}
      required   = []

      params.each do |(kind, pname)|
        next if pname.nil? # anonymous splat/block params — no primitive uses these
        properties[pname.to_s] = property_for(name, pname, enums[pname])
        if (kind == :req || kind == :keyreq) && !defaults.key?(pname)
          required << pname.to_s
        end
      end
      properties["session_id"] = SESSION_PARAM

      {
        name: name.to_s,
        description: DESCRIPTIONS[name] || "MudManager primitive `#{name}`" \
                     "#{params.empty? ? '' : " (#{params.map { |_, p| p }.compact.join(', ')})"}.",
        params: params,
        defaults: defaults,
        input_schema: { "type" => "object", "properties" => properties, "required" => required }
      }
    end

    def self.property_for(name, pname, enum)
      integer = (INTEGER_PARAMS[name] || []).include?(pname)
      prop = { "type" => integer ? "integer" : "string", "description" => pname.to_s.tr("_", " ") }
      prop["enum"] = enum if enum
      prop
    end

    # Build a MudManager::Primitives::Command from MCP tool arguments
    # (string keys, string-or-number values) using the parameter shape
    # captured in `spec`. Missing required args are passed through as nil
    # (or the DEFAULTS value) rather than rejected here — Primitives' own
    # check_enum!/require_str! produce the clearer error message.
    def self.build(spec, args)
      positional = []
      keywords   = {}
      name       = spec[:name].to_sym
      defaults   = spec[:defaults] || {}

      spec[:params].each do |(kind, pname)|
        next if pname.nil?
        key     = pname.to_s
        has_arg = args.key?(key)
        has_default = defaults.key?(pname)
        next unless has_arg || has_default || kind == :req || kind == :keyreq

        value = has_arg ? coerce(name, pname, args[key]) : defaults[pname]

        case kind
        when :req, :opt
          positional << value
        when :key, :keyreq
          keywords[pname] = value
        end
      end

      NORMALIZERS[name]&.call(keywords)

      Primitives.public_send(name, *positional, **keywords)
    end

    def self.coerce(name, pname, value)
      return value unless value.is_a?(String)
      return value unless (INTEGER_PARAMS[name] || []).include?(pname)

      Integer(value)
    rescue ArgumentError, TypeError
      value
    end
  end
end
