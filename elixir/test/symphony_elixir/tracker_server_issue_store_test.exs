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

  test "search filters by state, deduplicating states list" do
    issues = [
      %{"id" => "a", "state" => "Todo"},
      %{"id" => "b", "state" => "In Progress"},
      %{"id" => "c", "state" => "Done"}
    ]

    assert IssueStore.search(issues, ["Todo", "In Progress", "Todo"]) == [
             %{"id" => "a", "state" => "Todo"},
             %{"id" => "b", "state" => "In Progress"}
           ]
  end

  test "search returns [] when states is empty" do
    issues = [%{"id" => "a", "state" => "Todo"}]
    assert IssueStore.search(issues, []) == []
  end

  test "search is case-sensitive" do
    issues = [%{"id" => "a", "state" => "Todo"}]
    assert IssueStore.search(issues, ["todo"]) == []
  end

  test "by_ids returns matching issues, silently dropping unknown ids" do
    issues = [
      %{"id" => "a", "state" => "Todo"},
      %{"id" => "b", "state" => "Done"}
    ]

    assert IssueStore.by_ids(issues, ["a", "missing"]) == [%{"id" => "a", "state" => "Todo"}]
  end

  test "by_ids deduplicates the input ids list" do
    issues = [%{"id" => "a", "state" => "Todo"}]
    assert IssueStore.by_ids(issues, ["a", "a"]) == [%{"id" => "a", "state" => "Todo"}]
  end

  test "update_state writes new state and preserves other fields", %{json_file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo","description":"d"}
    ]}))

    assert :ok = IssueStore.update_state(file, "a", "Done")

    {:ok, [issue]} = IssueStore.load(file)
    assert issue["state"] == "Done"
    assert issue["description"] == "d"
  end

  test "update_state refreshes updated_at when present, leaves original timestamp behind", %{json_file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo","updated_at":"2020-01-01T00:00:00Z"}
    ]}))

    assert :ok = IssueStore.update_state(file, "a", "Done")

    {:ok, [issue]} = IssueStore.load(file)
    assert issue["updated_at"] != "2020-01-01T00:00:00Z"
    assert {:ok, _, _} = DateTime.from_iso8601(issue["updated_at"])
  end

  test "update_state does not add updated_at when absent", %{json_file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo"}
    ]}))

    assert :ok = IssueStore.update_state(file, "a", "Done")

    {:ok, [issue]} = IssueStore.load(file)
    refute Map.has_key?(issue, "updated_at")
  end

  test "update_state refreshes camelCase updatedAt when present", %{json_file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo","updatedAt":"2020-01-01T00:00:00Z"}
    ]}))

    assert :ok = IssueStore.update_state(file, "a", "Done")

    {:ok, [issue]} = IssueStore.load(file)
    assert issue["updatedAt"] != "2020-01-01T00:00:00Z"
  end

  test "update_state returns unknown_issue_id when no match", %{json_file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo"}
    ]}))

    assert {:error, :unknown_issue_id} = IssueStore.update_state(file, "missing", "Done")
  end

  test "update_state preserves issue order", %{json_file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo"},
      {"id":"b","identifier":"X-2","title":"t","state":"Todo"},
      {"id":"c","identifier":"X-3","title":"t","state":"Todo"}
    ]}))

    assert :ok = IssueStore.update_state(file, "b", "Done")

    {:ok, issues} = IssueStore.load(file)
    assert Enum.map(issues, & &1["id"]) == ["a", "b", "c"]
  end

  test "update_state leaves no .tmp file behind on success", %{json_file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo"}
    ]}))

    assert :ok = IssueStore.update_state(file, "a", "Done")
    assert Path.wildcard(file <> ".tmp.*") == []
  end

  test "update_state on missing file auto-creates empty store and returns unknown_issue_id", %{json_file: file} do
    refute File.exists?(file)
    assert {:error, :unknown_issue_id} = IssueStore.update_state(file, "anything", "Done")
    assert File.exists?(file)
    assert {:ok, []} = IssueStore.load(file)
  end

  test "load returns error when write_atomic fails due to missing parent directory", %{dir: dir} do
    # A path whose parent does not exist: File.read returns :enoent (hits the
    # auto-create branch), then File.write(tmp) also fails with :enoent because
    # the parent dir never existed — exercising the write_atomic failure path.
    path = Path.join(dir, "nonexistent-sub/tracker.json")
    assert {:error, _} = IssueStore.load(path)
  end

  @tag :unix
  test "load returns file_read error on a non-readable file", %{json_file: file} do
    # Skip when running as root (root can read 0o000 files)
    uid =
      case System.cmd("id", ["-u"]) do
        {out, 0} -> String.trim(out)
        _ -> "unknown"
      end

    unless uid == "0" do
      File.write!(file, "anything")
      File.chmod!(file, 0o000)
      on_exit(fn -> File.chmod!(file, 0o600) end)

      assert {:error, {:file_read, _}} = IssueStore.load(file)
    end
  end
end
