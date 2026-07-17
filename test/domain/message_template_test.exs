defmodule McpLogServer.Domain.MessageTemplateTest do
  @moduledoc """
  Issue #7 P2: normalization corpus for message templates. Volatile tokens
  (timestamps, UUIDs, IPs, hex ids, numbers, optionally quoted strings)
  collapse into placeholders; stable words survive untouched.
  """

  use ExUnit.Case, async: true

  alias McpLogServer.Domain.MessageTemplate

  describe "timestamps" do
    test "ISO 8601 with millis and zone" do
      assert MessageTemplate.template("2026-07-17T10:00:00.123Z ERROR conn lost") ==
               "<TS> ERROR conn lost"
    end

    test "ISO 8601 with offset" do
      assert MessageTemplate.template("2026-07-17T10:00:00+02:00 boot") == "<TS> boot"
    end

    test "date space time" do
      assert MessageTemplate.template("2026-01-15 10:30:00 WARN slow query") ==
               "<TS> WARN slow query"
    end

    test "common log format" do
      assert MessageTemplate.template(~s(127.0.0.1 - - [20/Mar/2026:14:00:00 +0000] "GET /health" 200)) ==
               ~s(<IP> - - [<TS>] "GET /health" <N>)
    end

    test "syslog" do
      assert MessageTemplate.template("Mar 20 14:00:00 host sshd[123]: auth fail") ==
               "<TS> host sshd[<N>]: auth fail"
    end

    test "bare time-only dev-server prefix" do
      assert MessageTemplate.template("[10:30:00] hmr update /src/App.tsx") ==
               "[<TS>] hmr update /src/App.tsx"
    end
  end

  describe "ids and addresses" do
    test "UUID" do
      assert MessageTemplate.template("user 550e8400-e29b-41d4-a716-446655440000 logged in") ==
               "user <UUID> logged in"
    end

    test "IP with port" do
      assert MessageTemplate.template("connect to 10.0.0.7:5432 refused") ==
               "connect to <IP> refused"
    end

    test "IP without port" do
      assert MessageTemplate.template("peer 192.168.1.1 gone") == "peer <IP> gone"
    end

    test "0x hex literal" do
      assert MessageTemplate.template("segfault at 0xDEADBEEF") == "segfault at <HEX>"
    end

    test "long hex run with digits" do
      assert MessageTemplate.template("req a3f9c2d871b4 done") == "req <HEX> done"
    end

    test "all-digit run of hex length is a number, not hex" do
      assert MessageTemplate.template("order 12345678 shipped") == "order <N> shipped"
    end

    test "hex-alphabet word without digits survives" do
      assert MessageTemplate.template("deadbeef is a word here") == "deadbeef is a word here"
    end
  end

  describe "numbers" do
    test "standalone integers and decimals" do
      assert MessageTemplate.template("retried 3 times, ratio 0.95") ==
               "retried <N> times, ratio <N>"
    end

    test "digits with trailing unit normalize" do
      assert MessageTemplate.template("lost after 30s, took 1300ms") ==
               "lost after <N>s, took <N>ms"
    end

    test "digits glued to the end of an identifier stay" do
      assert MessageTemplate.template("handler error404 fired") == "handler error404 fired"
    end
  end

  describe "quoted strings (opt-in)" do
    test "off by default" do
      assert MessageTemplate.template(~s(said "hello world")) == ~s(said "hello world")
    end

    test "collapsed when quoted: true" do
      assert MessageTemplate.template(~s(said "hello world" and 'bye'), quoted: true) ==
               "said <STR> and <STR>"
    end
  end

  describe "noise stripping" do
    test "ANSI escapes are stripped" do
      assert MessageTemplate.template("\e[2m10:00:01\e[0m \e[36mready\e[0m in 120ms") ==
               "<TS> ready in <N>ms"
    end

    test "source tags are stripped (the instance dimension is NOT part of the template)" do
      a = MessageTemplate.normalize("[src:fly-a] conn 4f9a12cd lost after 30s")
      b = MessageTemplate.normalize("[src:fly-b] conn 77b1e0f2 lost after 12s")
      assert a.template == b.template
      assert a.hash == b.hash
      assert a.template == "conn <HEX> lost after <N>s"
    end
  end

  describe "the incident shape: near-identical lines from N machines" do
    test "collapse to one template" do
      lines = [
        "2026-07-17T17:59:21Z proxy[a1b2c3d4] upstream 10.0.0.7:8080 timed out after 30s",
        "2026-07-17T18:02:03Z proxy[99ffe012] upstream 10.0.1.9:8080 timed out after 12s",
        "2026-07-17T18:11:40.501Z proxy[0f0f0f0f] upstream 10.0.2.2:8080 timed out after 7s"
      ]

      templates = lines |> Enum.map(&MessageTemplate.template/1) |> Enum.uniq()
      assert templates == ["<TS> proxy[<HEX>] upstream <IP> timed out after <N>s"]
    end
  end

  describe "determinism and hashing" do
    test "same input, same output, always" do
      line = "2026-07-17T10:00:00Z conn 4f9a12cd lost to 10.0.0.7:5432 after 30s"

      results = for _ <- 1..50, do: MessageTemplate.normalize(line)
      assert length(Enum.uniq(results)) == 1
    end

    test "hash is 8 lowercase hex chars and template-stable" do
      %{template: template, hash: hash} = MessageTemplate.normalize("x 42 y")
      assert hash =~ ~r/^[0-9a-f]{8}$/
      assert MessageTemplate.hash(template) == hash
    end

    test "different templates get different hashes" do
      h1 = MessageTemplate.normalize("connection refused") |> Map.fetch!(:hash)
      h2 = MessageTemplate.normalize("connection accepted") |> Map.fetch!(:hash)
      refute h1 == h2
    end
  end
end
