defmodule SymphonyElixir.TrackerServerIssueStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TrackerServer.IssueStore

  setup do
    dir = Path.join(System.tmp_dir!(), "tracker-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, %{dir: dir, json_file: Path.join(dir, "tracker.json")}}
  end

  test "load returns the issues array on a valid file", %{json_file: file} do
    File.write!(file, ~s({"issues":[{"id":"a","identifier":"X-1","title":"t","state":"Todo"}]}))
    assert {:ok, [%{"id" => "a", "state" => "Todo"}]} = IssueStore.load(file)
  end

  test "load creates an empty file when missing and returns []", %{json_file: file} do
    refute File.exists?(file)
    assert {:ok, []} = IssueStore.load(file)
    assert File.exists?(file)
    assert {:ok, %{"issues" => []}} = Jason.decode(File.read!(file))
  end

  test "load returns invalid_json error on malformed JSON", %{json_file: file} do
    File.write!(file, "{this is not json")
    assert {:error, {:invalid_json, _}} = IssueStore.load(file)
  end
end
