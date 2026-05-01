defmodule SymphonyElixir.TrackerServerCommentLogTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TrackerServer.CommentLog

  setup do
    dir = Path.join(System.tmp_dir!(), "tracker-comments-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, %{jsonl_file: Path.join(dir, "comments.jsonl")}}
  end

  defp lines(file), do: file |> File.read!() |> String.split("\n", trim: true)

  defp decode_line(line) do
    {:ok, value} = Jason.decode(line)
    value
  end

  test "append serializes one JSONL line per call", %{jsonl_file: file} do
    name = :"comment_log_one_#{System.unique_integer([:positive])}"
    {:ok, _pid} = CommentLog.start_link(name: name, path: file)

    assert :ok = CommentLog.append(name, "task-1", "hello")
    assert :ok = CommentLog.append(name, "task-1", "world")

    [first, second] = lines(file)
    assert %{"issue_id" => "task-1", "body" => "hello", "at" => at1} = decode_line(first)
    assert %{"issue_id" => "task-1", "body" => "world", "at" => at2} = decode_line(second)
    assert {:ok, _, _} = DateTime.from_iso8601(at1)
    assert {:ok, _, _} = DateTime.from_iso8601(at2)
  end

  test "append auto-creates the file if it does not exist", %{jsonl_file: file} do
    refute File.exists?(file)
    name = :"comment_log_create_#{System.unique_integer([:positive])}"
    {:ok, _pid} = CommentLog.start_link(name: name, path: file)

    assert :ok = CommentLog.append(name, "task-1", "first")
    assert File.exists?(file)
    assert [_one] = lines(file)
  end

  test "append returns error tuple and the process stays alive when the path is unwritable" do
    name = :"comment_log_err_#{System.unique_integer([:positive])}"

    # Use a file path under a non-existent absolute parent that cannot be
    # auto-created (root-owned, not writable by the test user). `/proc` on
    # Linux and `/dev` on macOS are both real read-only mount points where
    # mkdir_p will fail with EACCES or EROFS.
    bad_path = "/dev/symphony-tracker-test-#{System.unique_integer([:positive])}/comments.jsonl"

    {:ok, pid} = CommentLog.start_link(name: name, path: bad_path)
    assert {:error, _reason} = CommentLog.append(name, "task-1", "body")
    assert Process.alive?(pid)
  end

  test "concurrent callers all see :ok and the file ends with N lines", %{jsonl_file: file} do
    name = :"comment_log_conc_#{System.unique_integer([:positive])}"
    {:ok, _pid} = CommentLog.start_link(name: name, path: file)

    tasks =
      for i <- 1..50 do
        Task.async(fn -> CommentLog.append(name, "task-#{i}", "body-#{i}") end)
      end

    assert Enum.all?(Task.await_many(tasks, 5_000), &(&1 == :ok))
    assert length(lines(file)) == 50
  end
end
