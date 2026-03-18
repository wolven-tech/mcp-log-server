defmodule McpLogServer.IntegrationTest do
  @moduledoc """
  Integration test that exercises the full MCP server over stdio,
  exactly as Claude Code would use it.
  """

  def run do
    IO.puts("=== MCP Log Server Integration Test ===\n")

    # Setup: create test log files
    log_dir = "/tmp/galactic-logs-test-#{:rand.uniform(100_000)}"
    File.mkdir_p!(log_dir)

    File.write!(Path.join(log_dir, "api.log"), """
    [2026-03-16 21:00:00] INFO: API started on port 5500
    [2026-03-16 21:00:01] INFO: Connected to Redis
    [2026-03-16 21:00:02] ERROR: Failed to connect to Kalshi WebSocket
    [2026-03-16 21:00:03] WARN: RedLock quorum failed for tenant predictor
    [2026-03-16 21:00:04] INFO: Fetched 4856 events across 25 pages
    [2026-03-16 21:00:05] ERROR: Kalshi WebSocket max reconnection attempts reached
    [2026-03-16 21:00:06] DEBUG: Processing market update for BTC-USD
    """)

    File.write!(Path.join(log_dir, "recommendation.log"), """
    [2026-03-16 21:00:00] INFO: Recommendation service started on port 5503
    [2026-03-16 21:00:01] ERROR: All 4690 embeddings failed
    [2026-03-16 21:00:02] INFO: Qdrant connected for tenant predictor
    """)

    # Start the server as a subprocess
    port = Port.open(
      {:spawn_executable, System.find_executable("elixir")},
      [
        :binary,
        :use_stdio,
        {:args, ["--no-halt", "-S", "mix", "run"]},
        {:cd, to_charlist(File.cwd!())},
        {:env, [
          {~c"LOG_DIR", to_charlist(log_dir)},
          {~c"MIX_ENV", ~c"dev"},
          {~c"HOME", to_charlist(System.get_env("HOME"))},
          {~c"PATH", to_charlist(System.get_env("PATH"))}
        ]}
      ]
    )

    # Give it time to start
    Process.sleep(3000)

    results = []

    # Test 1: Initialize
    result = send_and_receive(port, %{
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: %{protocolVersion: "2024-11-05", capabilities: %{}}
    })
    results = results ++ [assert_test("initialize", fn ->
      assert_field(result, ["result", "serverInfo", "name"], "galactic-log-server") &&
      assert_field(result, ["result", "protocolVersion"], "2024-11-05")
    end)]

    # Test 2: tools/list
    result = send_and_receive(port, %{
      jsonrpc: "2.0", id: 2, method: "tools/list"
    })
    results = results ++ [assert_test("tools/list returns 6 tools", fn ->
      tools = get_in_result(result, ["result", "tools"])
      is_list(tools) && length(tools) == 6
    end)]

    # Test 3: list_logs
    result = send_and_receive(port, %{
      jsonrpc: "2.0", id: 3, method: "tools/call",
      params: %{name: "list_logs", arguments: %{}}
    })
    results = results ++ [assert_test("list_logs finds 2 files", fn ->
      text = get_text(result)
      text != nil && String.contains?(text, "api.log") && String.contains?(text, "recommendation.log")
    end)]

    # Test 4: tail_log
    result = send_and_receive(port, %{
      jsonrpc: "2.0", id: 4, method: "tools/call",
      params: %{name: "tail_log", arguments: %{"file" => "api.log", "lines" => 3}}
    })
    results = results ++ [assert_test("tail_log returns last 3 lines", fn ->
      text = get_text(result)
      text != nil &&
        String.contains?(text, "max reconnection") &&
        String.contains?(text, "DEBUG") &&
        !String.contains?(text, "API started")
    end)]

    # Test 5: get_errors
    result = send_and_receive(port, %{
      jsonrpc: "2.0", id: 5, method: "tools/call",
      params: %{name: "get_errors", arguments: %{"file" => "api.log"}}
    })
    results = results ++ [assert_test("get_errors finds errors in TOON format", fn ->
      text = get_text(result)
      text != nil &&
        String.contains?(text, "ERROR") &&
        String.contains?(text, "WARN") &&
        String.contains?(text, "|") &&  # TOON pipe separator
        !String.contains?(text, "INFO")  # should not include INFO lines
    end)]

    # Test 6: search_logs
    result = send_and_receive(port, %{
      jsonrpc: "2.0", id: 6, method: "tools/call",
      params: %{name: "search_logs", arguments: %{"file" => "api.log", "pattern" => "Kalshi"}}
    })
    results = results ++ [assert_test("search_logs finds Kalshi mentions", fn ->
      text = get_text(result)
      text != nil &&
        String.contains?(text, "Kalshi") &&
        String.contains?(text, "|")  # TOON format
    end)]

    # Test 7: log_stats
    result = send_and_receive(port, %{
      jsonrpc: "2.0", id: 7, method: "tools/call",
      params: %{name: "log_stats", arguments: %{"file" => "api.log"}}
    })
    results = results ++ [assert_test("log_stats returns counts", fn ->
      text = get_text(result)
      text != nil &&
        String.contains?(text, "line_count") &&
        String.contains?(text, "error_count") &&
        String.contains?(text, "warn_count")
    end)]

    # Test 8: all_errors
    result = send_and_receive(port, %{
      jsonrpc: "2.0", id: 8, method: "tools/call",
      params: %{name: "all_errors", arguments: %{"lines" => 10}}
    })
    results = results ++ [assert_test("all_errors aggregates across files", fn ->
      text = get_text(result)
      text != nil &&
        String.contains?(text, "api.log") &&
        String.contains?(text, "recommendation.log") &&
        String.contains?(text, "embeddings failed")
    end)]

    # Test 9: error handling - missing file
    result = send_and_receive(port, %{
      jsonrpc: "2.0", id: 9, method: "tools/call",
      params: %{name: "tail_log", arguments: %{"file" => "nonexistent.log"}}
    })
    results = results ++ [assert_test("missing file returns error", fn ->
      text = get_text(result)
      text != nil && String.contains?(text, "not found")
    end)]

    # Test 10: unknown tool
    result = send_and_receive(port, %{
      jsonrpc: "2.0", id: 10, method: "tools/call",
      params: %{name: "fake_tool", arguments: %{}}
    })
    results = results ++ [assert_test("unknown tool returns error", fn ->
      text = get_text(result)
      text != nil && String.contains?(text, "Unknown tool")
    end)]

    # Cleanup
    Port.close(port)
    File.rm_rf!(log_dir)

    # Report
    IO.puts("\n=== Results ===")
    passed = Enum.count(results, & &1)
    failed = Enum.count(results, &(!&1))
    IO.puts("#{passed} passed, #{failed} failed out of #{length(results)} tests")

    if failed > 0 do
      System.halt(1)
    else
      IO.puts("\nAll tests passed!")
      System.halt(0)
    end
  end

  defp send_and_receive(port, request) do
    json = Jason.encode!(request) <> "\n"
    Port.command(port, json)
    receive do
      {^port, {:data, data}} ->
        data
        |> String.split("\n", trim: true)
        |> List.last()
        |> Jason.decode()
        |> case do
          {:ok, parsed} -> parsed
          {:error, _} -> nil
        end
    after
      5000 ->
        IO.puts("  TIMEOUT waiting for response to id=#{request[:id]}")
        nil
    end
  end

  defp get_text(nil), do: nil
  defp get_text(response) do
    case get_in_result(response, ["result", "content"]) do
      [%{"text" => text} | _] -> text
      _ -> nil
    end
  end

  defp get_in_result(nil, _), do: nil
  defp get_in_result(map, []), do: map
  defp get_in_result(map, [key | rest]) when is_map(map) do
    get_in_result(Map.get(map, key), rest)
  end
  defp get_in_result(_, _), do: nil

  defp assert_field(response, path, expected) do
    get_in_result(response, path) == expected
  end

  defp assert_test(name, test_fn) do
    try do
      if test_fn.() do
        IO.puts("  ✓ #{name}")
        true
      else
        IO.puts("  ✗ #{name} - assertion failed")
        false
      end
    rescue
      e ->
        IO.puts("  ✗ #{name} - #{Exception.message(e)}")
        false
    end
  end
end

McpLogServer.IntegrationTest.run()
