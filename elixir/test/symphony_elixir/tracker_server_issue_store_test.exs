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

  test "load rejects top-level array form", %{json_file: file} do
    File.write!(file, ~s([{"id":"a","identifier":"X-1","title":"t","state":"Todo"}]))
    assert {:error, :top_level_must_be_object_with_issues_array} = IssueStore.load(file)
  end

  test "load rejects top-level non-list issues", %{json_file: file} do
    File.write!(file, ~s({"issues":"oops"}))
    assert {:error, :top_level_must_be_object_with_issues_array} = IssueStore.load(file)
  end

  test "load rejects an issue missing required fields", %{json_file: file} do
    File.write!(file, ~s({"issues":[{"id":"a","identifier":"X-1","title":"t"}]}))
    assert {:error, {:missing_or_blank_field, "state", _}} = IssueStore.load(file)
  end

  test "load rejects blank required field", %{json_file: file} do
    File.write!(file, ~s({"issues":[{"id":"a","identifier":"","title":"t","state":"Todo"}]}))
    assert {:error, {:missing_or_blank_field, "identifier", _}} = IssueStore.load(file)
  end

  test "load rejects duplicate ids", %{json_file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"dup","identifier":"X-1","title":"t","state":"Todo"},
      {"id":"dup","identifier":"X-2","title":"t","state":"Todo"}
    ]}))
    assert {:error, {:duplicate_ids, ["dup"]}} = IssueStore.load(file)
  end

  test "load accepts multiple valid issues", %{json_file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo"},
      {"id":"b","identifier":"X-2","title":"t","state":"Done"}
    ]}))

    assert {:ok, [_, _]} = IssueStore.load(file)
  end

  test "load accepts an explicitly empty issues array", %{json_file: file} do
    File.write!(file, ~s({"issues":[]}))
    assert {:ok, []} = IssueStore.load(file)
  end

  test "load deduplicates the duplicate ids list when an id appears 3+ times", %{json_file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"dup","identifier":"X-1","title":"t","state":"Todo"},
      {"id":"dup","identifier":"X-2","title":"t","state":"Todo"},
      {"id":"dup","identifier":"X-3","title":"t","state":"Todo"}
    ]}))

    assert {:error, {:duplicate_ids, ["dup"]}} = IssueStore.load(file)
  end

  test "load rejects an issue that is not a map", %{json_file: file} do
    File.write!(file, ~s({"issues":["nope"]}))
    assert {:error, :issue_must_be_object} = IssueStore.load(file)
  end
end
