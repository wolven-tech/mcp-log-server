defmodule McpLogServer.Tools.Registry do
  @moduledoc """
  Tool definitions for the MCP tools/list response.
  Separated from dispatch logic so schema and execution are independently testable.
  """

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "list_logs",
        description: "List all available log files with size and last modified time",
        inputSchema: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "tail_log",
        description:
          "Get the last N lines from a log file. Use this to see recent output.",
        inputSchema: %{
          type: "object",
          properties: %{
            file: %{type: "string", description: "Log file name (e.g., api.log)"},
            lines: %{type: "integer", description: "Number of lines (default: 50)", default: 50},
            format: %{type: "string", enum: ["toon", "json"], description: "Output format (default: toon)"}
          },
          required: ["file"]
        }
      },
      %{
        name: "search_logs",
        description:
          "Search log file for a regex pattern. Returns matching lines with line numbers.",
        inputSchema: %{
          type: "object",
          properties: %{
            file: %{type: "string", description: "Log file name"},
            pattern: %{type: "string", description: "Regex pattern (case-insensitive)"},
            max_results: %{type: "integer", description: "Max results (default: 50)", default: 50},
            context: %{type: "integer", description: "Context lines around match (default: 0)", default: 0},
            format: %{type: "string", enum: ["toon", "json"], description: "Output format (default: toon)"}
          },
          required: ["file", "pattern"]
        }
      },
      %{
        name: "get_errors",
        description:
          "Extract ERROR, FATAL, WARN, and exception lines from a log file.",
        inputSchema: %{
          type: "object",
          properties: %{
            file: %{type: "string", description: "Log file name"},
            lines: %{type: "integer", description: "Max error lines (default: 100)", default: 100},
            format: %{type: "string", enum: ["toon", "json"], description: "Output format (default: toon)"}
          },
          required: ["file"]
        }
      },
      %{
        name: "log_stats",
        description:
          "Get stats: line count, error count, warn count, file size. Quick overview.",
        inputSchema: %{
          type: "object",
          properties: %{
            file: %{type: "string", description: "Log file name"}
          },
          required: ["file"]
        }
      },
      %{
        name: "all_errors",
        description:
          "Get errors from ALL log files at once. Best first call for health overview. Always returns TOON format.",
        inputSchema: %{
          type: "object",
          properties: %{
            lines: %{type: "integer", description: "Max errors per file (default: 20)", default: 20}
          },
          required: []
        }
      }
    ]
  end
end
