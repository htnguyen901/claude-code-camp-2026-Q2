module Boukensha
  class UnknownToolError    < StandardError; end
  class ApiError            < StandardError; end
  class LoopError           < StandardError; end
  class UnsupportedModelError < StandardError; end

  # A dispatch was requested for a tool name that exists on some MCP server's
  # catalog but was filtered out by the current task's ToolPolicy at
  # registration time — distinct from UnknownToolError (a name that was never
  # advertised by anything at all), so observability can tell "the model
  # tried something it wasn't allowed to have" apart from "the model
  # hallucinated a tool name."
  class PermissionDeniedError < StandardError; end
end
