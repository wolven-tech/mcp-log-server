defmodule McpLogServer.Infrastructure.CloudSyncTest do
  # async: false — tests prepend a stub-CLI directory to the global PATH.
  use ExUnit.Case, async: false

  alias McpLogServer.Infrastructure.CloudSync

  @moduletag :tmp_dir

  @gsutil_listing """
        2276  2026-07-01T10:15:30Z  gs://bucket/logs/api-old.log
         123  2026-07-05T12:00:00Z  gs://bucket/logs/api-new.log
  TOTAL: 2 objects, 2399 bytes (2.34 KiB)
  """

  @aws_listing """
  2026-07-01 10:15:30       2276 logs/api-old.log
  2026-07-05 12:00:00        123 logs/api-new.log
  """

  @az_listing "logs/api-old.log\t2026-07-01T10:15:30+00:00\n" <>
                "logs/api-new.log\t2026-07-05T12:00:00+00:00\n"

  @since ~U[2026-07-03 00:00:00Z]

  setup %{tmp_dir: tmp_dir} do
    bin = Path.join(tmp_dir, "bin")
    log_dir = Path.join(tmp_dir, "logs")
    File.mkdir_p!(bin)
    File.mkdir_p!(log_dir)

    argv_log = Path.join(tmp_dir, "argv.log")

    original_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> original_path)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    %{bin: bin, log_dir: log_dir, argv_log: argv_log}
  end

  # Writes a stub CLI script into `bin` that appends its argv (tab-joined,
  # one line per invocation) to `argv_log`, then runs `body`.
  defp write_stub(bin, argv_log, name, body) do
    script = """
    #!/bin/sh
    {
      printf '%s' "#{name}"
      for a in "$@"; do printf '\\t%s' "$a"; done
      printf '\\n'
    } >> "#{argv_log}"
    #{body}
    """

    path = Path.join(bin, name)
    File.write!(path, script)
    File.chmod!(path, 0o755)
  end

  defp invocations(argv_log) do
    argv_log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "\t"))
  end

  defp stub_emitting(bin, argv_log, name, listing) do
    listing_file = Path.join(bin, "#{name}_listing.txt")
    File.write!(listing_file, listing)

    body =
      case name do
        "gsutil" -> ~s(if [ "$1" = "ls" ]; then cat "#{listing_file}"; fi\nexit 0)
        "aws" -> ~s(if [ "$3" = "ls" ] || [ "$2" = "ls" ]; then cat "#{listing_file}"; fi\nexit 0)
        "az" -> ~s(if [ "$3" = "list" ]; then cat "#{listing_file}"; fi\nexit 0)
      end

    write_stub(bin, argv_log, name, body)
  end

  test "rejects unsupported URI schemes without shelling out", %{log_dir: log_dir} do
    assert {:error, msg} = CloudSync.sync("ftp://bucket/logs/", log_dir, [])
    assert msg =~ "Unsupported URI scheme"
    assert msg =~ "gs://, s3://, or az://"
  end

  describe "bulk paths (no since)" do
    test "gs:// runs gsutil -m rsync -r", ctx do
      write_stub(ctx.bin, ctx.argv_log, "gsutil", "exit 0")

      assert {:ok, msg} =
               CloudSync.sync("gs://bucket/logs/", ctx.log_dir, prefix: nil, since: nil)

      assert msg =~ "Sync complete."

      assert [["gsutil", "-m", "rsync", "-r", "gs://bucket/logs/", dir]] =
               invocations(ctx.argv_log)

      assert dir == ctx.log_dir
    end

    test "s3:// with prefix keeps exclude/include args", ctx do
      write_stub(ctx.bin, ctx.argv_log, "aws", "exit 0")

      assert {:ok, _} = CloudSync.sync("s3://bucket/logs/", ctx.log_dir, prefix: "api-")

      assert [
               [
                 "aws",
                 "s3",
                 "sync",
                 "s3://bucket/logs/",
                 _dir,
                 "--exclude",
                 "*",
                 "--include",
                 "api-*"
               ]
             ] = invocations(ctx.argv_log)
    end
  end

  describe "gs:// with since" do
    test "lists, filters strictly-after, copies survivors", ctx do
      stub_emitting(ctx.bin, ctx.argv_log, "gsutil", @gsutil_listing)

      assert {:ok, msg} = CloudSync.sync("gs://bucket/logs/", ctx.log_dir, since: @since)
      assert msg == "Sync complete. 1 of 2 files modified after 2026-07-03T00:00:00Z copied."

      assert [
               ["gsutil", "ls", "-l", "gs://bucket/logs/"],
               ["gsutil", "-m", "cp", "gs://bucket/logs/api-new.log", dir]
             ] = invocations(ctx.argv_log)

      assert dir == ctx.log_dir
    end

    test "prefix narrows the listing target", ctx do
      stub_emitting(ctx.bin, ctx.argv_log, "gsutil", @gsutil_listing)

      assert {:ok, _} =
               CloudSync.sync("gs://bucket/logs/", ctx.log_dir, prefix: "api-", since: @since)

      assert [["gsutil", "ls", "-l", "gs://bucket/logs/api-*"] | _] = invocations(ctx.argv_log)
    end

    test "zero survivors is success, and no copy is attempted", ctx do
      stub_emitting(ctx.bin, ctx.argv_log, "gsutil", @gsutil_listing)

      assert {:ok, "Sync complete. 0 files matched since filter."} =
               CloudSync.sync("gs://bucket/logs/", ctx.log_dir, since: ~U[2026-07-10 00:00:00Z])

      assert [["gsutil", "ls", "-l" | _]] = invocations(ctx.argv_log)
    end

    test "copies are chunked at 500 urls per gsutil invocation", ctx do
      listing =
        Enum.map_join(1..1200, "\n", fn i ->
          "      100  2026-07-05T12:00:00Z  gs://bucket/logs/api-#{i}.log"
        end) <> "\nTOTAL: 1200 objects, 120000 bytes (117.19 KiB)\n"

      stub_emitting(ctx.bin, ctx.argv_log, "gsutil", listing)

      assert {:ok, msg} = CloudSync.sync("gs://bucket/logs/", ctx.log_dir, since: @since)
      assert msg =~ "1200 of 1200 files"

      assert [["gsutil", "ls" | _] | copies] = invocations(ctx.argv_log)

      url_counts =
        Enum.map(copies, fn ["gsutil", "-m", "cp" | rest] ->
          # last element is the destination dir
          length(rest) - 1
        end)

      assert url_counts == [500, 500, 200]
    end

    test "listing failure fails the call with the CLI output", ctx do
      write_stub(ctx.bin, ctx.argv_log, "gsutil", "echo 'AccessDeniedException: 403'\nexit 1")

      assert {:error, msg} = CloudSync.sync("gs://bucket/logs/", ctx.log_dir, since: @since)
      assert msg =~ "gsutil exited with code 1"
      assert msg =~ "AccessDeniedException"
    end

    test "copy failure fails the call with the CLI output", ctx do
      listing_file = Path.join(ctx.bin, "listing.txt")
      File.write!(listing_file, @gsutil_listing)

      write_stub(ctx.bin, ctx.argv_log, "gsutil", """
      if [ "$1" = "ls" ]; then cat "#{listing_file}"; exit 0; fi
      echo 'CommandException: copy blew up'
      exit 1
      """)

      assert {:error, msg} = CloudSync.sync("gs://bucket/logs/", ctx.log_dir, since: @since)
      assert msg =~ "gsutil exited with code 1"
      assert msg =~ "copy blew up"
    end
  end

  describe "s3:// with since" do
    test "lists recursively, filters, copies per key", ctx do
      stub_emitting(ctx.bin, ctx.argv_log, "aws", @aws_listing)

      assert {:ok, msg} = CloudSync.sync("s3://bucket/logs/", ctx.log_dir, since: @since)
      assert msg == "Sync complete. 1 of 2 files modified after 2026-07-03T00:00:00Z copied."

      assert [
               ["aws", "s3", "ls", "s3://bucket/logs/", "--recursive"],
               ["aws", "s3", "cp", "s3://bucket/logs/api-new.log", dest]
             ] = invocations(ctx.argv_log)

      assert dest == ctx.log_dir <> "/"
    end

    test "prefix filters listed keys locally", ctx do
      stub_emitting(ctx.bin, ctx.argv_log, "aws", @aws_listing)

      assert {:ok, "Sync complete. 0 files matched since filter."} =
               CloudSync.sync("s3://bucket/logs/", ctx.log_dir, prefix: "other-", since: @since)

      assert [["aws", "s3", "ls" | _]] = invocations(ctx.argv_log)
    end
  end

  describe "az:// with since" do
    test "lists blobs as tsv, filters, downloads per blob", ctx do
      stub_emitting(ctx.bin, ctx.argv_log, "az", @az_listing)

      assert {:ok, msg} = CloudSync.sync("az://container/logs/", ctx.log_dir, since: @since)
      assert msg == "Sync complete. 1 of 2 files modified after 2026-07-03T00:00:00Z copied."

      assert [
               [
                 "az",
                 "storage",
                 "blob",
                 "list",
                 "--container-name",
                 "container",
                 "--query",
                 "[].[name,properties.lastModified]",
                 "--output",
                 "tsv",
                 "--prefix",
                 "logs/"
               ],
               [
                 "az",
                 "storage",
                 "blob",
                 "download-batch",
                 "--source",
                 "container",
                 "--destination",
                 dir,
                 "--pattern",
                 "logs/api-new.log"
               ]
             ] = invocations(ctx.argv_log)

      assert dir == ctx.log_dir
    end

    test "prefix is appended to the blob path prefix", ctx do
      stub_emitting(ctx.bin, ctx.argv_log, "az", @az_listing)

      assert {:ok, _} =
               CloudSync.sync("az://container/logs/", ctx.log_dir, prefix: "api-", since: @since)

      assert [["az" | list_args] | _] = invocations(ctx.argv_log)
      assert ["--prefix", "logs/api-"] = Enum.take(list_args, -2)
    end
  end
end
