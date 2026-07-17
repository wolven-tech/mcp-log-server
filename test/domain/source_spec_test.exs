defmodule McpLogServer.Domain.SourceSpecTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.SourceSpec

  describe "parse_declarations/1" do
    test "nil and blank mean no sources" do
      assert {:ok, []} = SourceSpec.parse_declarations(nil)
      assert {:ok, []} = SourceSpec.parse_declarations("")
      assert {:ok, []} = SourceSpec.parse_declarations("  ; ")
    end

    test "parses the documented Fly/k8s example" do
      raw = "fly:cmd=flyctl logs -a my-app; k8s:cmd=kubectl logs -f deploy/api"

      assert {:ok, [fly, k8s]} = SourceSpec.parse_declarations(raw)

      assert fly.name == "fly"
      assert fly.cmd == "flyctl logs -a my-app"
      assert fly.argv == ["flyctl", "logs", "-a", "my-app"]

      assert k8s.name == "k8s"
      assert k8s.argv == ["kubectl", "logs", "-f", "deploy/api"]
    end

    test "quoted arguments tokenize as single argv entries (no shell involved)" do
      raw = ~S(demo:cmd=sh -c "while true; do date; sleep 1; done")

      assert {:ok, [demo]} = SourceSpec.parse_declarations(raw)
      assert demo.argv == ["sh", "-c", "while true; do date; sleep 1; done"]
    end

    test "quoted semicolons do not split entries" do
      raw = ~S(demo:cmd=sh -c "date; sleep 1"; fly:cmd=flyctl logs -a x)

      assert {:ok, [demo, fly]} = SourceSpec.parse_declarations(raw)
      assert demo.argv == ["sh", "-c", "date; sleep 1"]
      assert fly.name == "fly"
    end

    test "single quotes are literal" do
      assert {:ok, [spec]} = SourceSpec.parse_declarations("a:cmd=echo 'hello world'")
      assert spec.argv == ["echo", "hello world"]
    end

    test "rejects a malformed entry" do
      assert {:error, msg} = SourceSpec.parse_declarations("just-a-name")
      assert msg =~ "name:cmd=command"
    end

    test "rejects a missing cmd= marker" do
      assert {:error, msg} = SourceSpec.parse_declarations("fly:flyctl logs")
      assert msg =~ "name:cmd=command"
    end

    test "rejects invalid source names" do
      assert {:error, msg} = SourceSpec.parse_declarations("bad name:cmd=echo hi")
      assert msg =~ "invalid source name"

      assert {:error, _} = SourceSpec.parse_declarations("../evil:cmd=echo hi")
    end

    test "rejects empty commands" do
      assert {:error, msg} = SourceSpec.parse_declarations("fly:cmd=  ")
      assert msg =~ "empty command"
    end

    test "rejects duplicate names" do
      assert {:error, msg} = SourceSpec.parse_declarations("a:cmd=echo 1; a:cmd=echo 2")
      assert msg =~ "duplicate source name"
      assert msg =~ "a"
    end

    test "rejects unterminated quotes" do
      assert {:error, msg} = SourceSpec.parse_declarations(~S(a:cmd=sh -c "unterminated))
      assert msg =~ "unterminated"
    end
  end

  describe "tokenize/1" do
    test "splits on whitespace runs" do
      assert {:ok, ["a", "b", "c"]} = SourceSpec.tokenize("a   b\tc")
    end

    test "backslash escapes outside quotes" do
      assert {:ok, ["a b"]} = SourceSpec.tokenize(~S(a\ b))
    end

    test "escaped double quote inside double quotes" do
      assert {:ok, ["say \"hi\""]} = SourceSpec.tokenize(~S("say \"hi\""))
    end

    test "backslash is literal inside double quotes except before quote/backslash" do
      assert {:ok, ["a\\nb"]} = SourceSpec.tokenize(~S("a\nb"))
    end

    test "empty quoted string is a token" do
      assert {:ok, ["echo", ""]} = SourceSpec.tokenize(~S(echo ""))
    end
  end
end
