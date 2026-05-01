# Local `custom_http` Tracker Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `bin/symphony-tracker` escript that implements the `custom_http` tracker server contract (SPEC §11.3) over a hand-editable `tracker.json` file plus an append-only `tracker.comments.jsonl` sidecar, so a Symphony user can run a real `custom_http` setup without Linear.

**Architecture:** A new `SymphonyElixir.TrackerServer.*` namespace under the existing Elixir Mix project. A `Plug.Router` with four routes runs under `Bandit`, supervised by a small `Application` module. Reads re-parse `tracker.json` on every request (no in-memory cache). Comment writes go through a single `GenServer` for serialization. A second escript binary is produced by re-running `escript.build` with a `MIX_ESCRIPT_TARGET` env var.

**Tech Stack:** Elixir 1.19, Plug 1.19 (`Plug.Router`, `Plug.Crypto.secure_compare/2`), Bandit 1.10, Jason 1.4. All already in `mix.lock`.

**Spec:** `docs/superpowers/specs/2026-05-01-custom-http-tracker-server-design.md`

**Pre-existing uncommitted work:** Working tree has client-side `custom_http` config wiring (in `config.ex`, `config/schema.ex`, `tracker.ex`, the related tests, and SPEC/README). This plan does **not** touch any of those files except `mix.exs` (Task 13) and `elixir/README.md` (Task 15) and `elixir/test/symphony_elixir/extensions_test.exs` (Task 14, appending after the existing `CustomHttp` test). All other work is purely new files.

---

## File Structure

**Created:**
- `elixir/lib/symphony_elixir/tracker_server/issue_store.ex` — pure functions over `tracker.json` (load/search/by_ids/update_state)
- `elixir/lib/symphony_elixir/tracker_server/comment_log.ex` — `GenServer` that serializes appends to `tracker.comments.jsonl`
- `elixir/lib/symphony_elixir/tracker_server/router.ex` — `Plug.Router` with the 4 routes + bearer auth function plug
- `elixir/lib/symphony_elixir/tracker_server/application.ex` — supervision tree (Bandit + CommentLog)
- `elixir/lib/symphony_elixir/tracker_server/cli.ex` — escript entrypoint, argv parser, banner, deps map
- `elixir/lib/mix/tasks/tracker_server.escript.ex` — Mix task that re-runs `escript.build` with `MIX_ESCRIPT_TARGET=tracker`
- `elixir/test/symphony_elixir/tracker_server_issue_store_test.exs`
- `elixir/test/symphony_elixir/tracker_server_comment_log_test.exs`
- `elixir/test/symphony_elixir/tracker_server_router_test.exs`
- `elixir/test/symphony_elixir/tracker_server_cli_test.exs`

**Modified:**
- `elixir/mix.exs` — `escript/0` becomes target-aware via `MIX_ESCRIPT_TARGET`; `aliases.build` runs both targets; `ignore_modules` adds CLI/Application/Mix task
- `elixir/test/symphony_elixir/extensions_test.exs` — appends one end-to-end test
- `elixir/README.md` — new sub-section after the existing custom_http config block (around line 119)

---

### Task 1: `IssueStore.load/1` — happy path, missing-file auto-create, malformed JSON

**Files:**
- Create: `elixir/lib/symphony_elixir/tracker_server/issue_store.ex`
- Test: `elixir/test/symphony_elixir/tracker_server_issue_store_test.exs`

- [ ] **Step 1: Write failing tests for `load/1`**

```elixir
# elixir/test/symphony_elixir/tracker_server_issue_store_test.exs
defmodule SymphonyElixir.TrackerServerIssueStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TrackerServer.IssueStore

  setup do
    dir = Path.join(System.tmp_dir!(), "tracker-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, %{dir: dir, file: Path.join(dir, "tracker.json")}}
  end

  test "load returns the issues array on a valid file", %{file: file} do
    File.write!(file, ~s({"issues":[{"id":"a","identifier":"X-1","title":"t","state":"Todo"}]}))
    assert {:ok, [%{"id" => "a", "state" => "Todo"}]} = IssueStore.load(file)
  end

  test "load creates an empty file when missing and returns []", %{file: file} do
    refute File.exists?(file)
    assert {:ok, []} = IssueStore.load(file)
    assert File.exists?(file)
    assert {:ok, %{"issues" => []}} = Jason.decode(File.read!(file))
  end

  test "load returns invalid_json error on malformed JSON", %{file: file} do
    File.write!(file, "{this is not json")
    assert {:error, {:invalid_json, _}} = IssueStore.load(file)
  end
end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_issue_store_test.exs`
Expected: FAIL with "module SymphonyElixir.TrackerServer.IssueStore is not loaded".

- [ ] **Step 3: Implement minimal `load/1`**

```elixir
# elixir/lib/symphony_elixir/tracker_server/issue_store.ex
defmodule SymphonyElixir.TrackerServer.IssueStore do
  @moduledoc """
  Pure-function read/write layer over the local `custom_http` tracker's
  `tracker.json` source-of-truth file. No in-memory cache; every read
  re-parses the file.
  """

  @spec load(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:error, :enoent} ->
        with :ok <- write_atomic(path, %{"issues" => []}) do
          {:ok, []}
        end

      {:error, reason} ->
        {:error, {:file_read, reason}}

      {:ok, raw} ->
        with {:ok, decoded} <- decode_json(raw) do
          {:ok, decoded["issues"] || []}
        end
    end
  end

  defp decode_json(raw) do
    case Jason.decode(raw) do
      {:ok, value} -> {:ok, value}
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
    end
  end

  defp write_atomic(path, data) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- Jason.encode(data, pretty: true),
         :ok <- File.write(tmp, encoded <> "\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end
end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_issue_store_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /Users/treedy/Project/symphony
git add elixir/lib/symphony_elixir/tracker_server/issue_store.ex \
        elixir/test/symphony_elixir/tracker_server_issue_store_test.exs
git commit -m "feat(tracker-server): IssueStore.load with file auto-create"
```

---

### Task 2: `IssueStore.load/1` — schema validation

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker_server/issue_store.ex`
- Modify: `elixir/test/symphony_elixir/tracker_server_issue_store_test.exs`

- [ ] **Step 1: Append failing tests**

```elixir
  # add to tracker_server_issue_store_test.exs

  test "load rejects top-level array form", %{file: file} do
    File.write!(file, ~s([{"id":"a","identifier":"X-1","title":"t","state":"Todo"}]))
    assert {:error, :top_level_must_be_object_with_issues_array} = IssueStore.load(file)
  end

  test "load rejects top-level non-list issues", %{file: file} do
    File.write!(file, ~s({"issues":"oops"}))
    assert {:error, :top_level_must_be_object_with_issues_array} = IssueStore.load(file)
  end

  test "load rejects an issue missing required fields", %{file: file} do
    File.write!(file, ~s({"issues":[{"id":"a","identifier":"X-1","title":"t"}]}))
    assert {:error, {:missing_or_blank_field, "state", _}} = IssueStore.load(file)
  end

  test "load rejects blank required field", %{file: file} do
    File.write!(file, ~s({"issues":[{"id":"a","identifier":"","title":"t","state":"Todo"}]}))
    assert {:error, {:missing_or_blank_field, "identifier", _}} = IssueStore.load(file)
  end

  test "load rejects duplicate ids", %{file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"dup","identifier":"X-1","title":"t","state":"Todo"},
      {"id":"dup","identifier":"X-2","title":"t","state":"Todo"}
    ]}))
    assert {:error, {:duplicate_ids, ["dup"]}} = IssueStore.load(file)
  end

  test "load rejects an issue that is not a map", %{file: file} do
    File.write!(file, ~s({"issues":["nope"]}))
    assert {:error, :issue_must_be_object} = IssueStore.load(file)
  end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_issue_store_test.exs`
Expected: 6 new failures.

- [ ] **Step 3: Add validation pipeline to `load/1`**

Replace the body of `load/1` and add validators (in `issue_store.ex`):

```elixir
  @spec load(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:error, :enoent} ->
        with :ok <- write_atomic(path, %{"issues" => []}) do
          {:ok, []}
        end

      {:error, reason} ->
        {:error, {:file_read, reason}}

      {:ok, raw} ->
        with {:ok, decoded} <- decode_json(raw),
             {:ok, issues} <- validate_top_level(decoded),
             :ok <- validate_each(issues),
             :ok <- validate_unique_ids(issues) do
          {:ok, issues}
        end
    end
  end

  defp validate_top_level(%{"issues" => issues}) when is_list(issues), do: {:ok, issues}
  defp validate_top_level(_), do: {:error, :top_level_must_be_object_with_issues_array}

  defp validate_each(issues) do
    Enum.reduce_while(issues, :ok, fn issue, :ok ->
      case validate_issue(issue) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_issue(issue) when is_map(issue) do
    Enum.reduce_while(["id", "identifier", "title", "state"], :ok, fn field, :ok ->
      case Map.get(issue, field) do
        value when is_binary(value) and value != "" ->
          {:cont, :ok}

        _ ->
          {:halt, {:error, {:missing_or_blank_field, field, issue_summary(issue)}}}
      end
    end)
  end

  defp validate_issue(_), do: {:error, :issue_must_be_object}

  defp issue_summary(issue) when is_map(issue), do: Map.take(issue, ["id", "identifier"])
  defp issue_summary(_), do: %{}

  defp validate_unique_ids(issues) do
    ids = Enum.map(issues, &Map.get(&1, "id"))
    duplicates = ids -- Enum.uniq(ids)

    if duplicates == [] do
      :ok
    else
      {:error, {:duplicate_ids, Enum.uniq(duplicates)}}
    end
  end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_issue_store_test.exs`
Expected: 9 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker_server/issue_store.ex \
        elixir/test/symphony_elixir/tracker_server_issue_store_test.exs
git commit -m "feat(tracker-server): IssueStore schema validation"
```

---

### Task 3: `IssueStore.search/2` and `IssueStore.by_ids/2`

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker_server/issue_store.ex`
- Modify: `elixir/test/symphony_elixir/tracker_server_issue_store_test.exs`

- [ ] **Step 1: Append failing tests**

```elixir
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
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_issue_store_test.exs`
Expected: 5 new failures (`search/2` and `by_ids/2` undefined).

- [ ] **Step 3: Implement `search/2` and `by_ids/2`**

Add to `issue_store.ex`:

```elixir
  @spec search([map()], [String.t()]) :: [map()]
  def search(_issues, []), do: []

  def search(issues, states) when is_list(issues) and is_list(states) do
    set = MapSet.new(states)
    Enum.filter(issues, fn issue -> Map.get(issue, "state") in set end)
  end

  @spec by_ids([map()], [String.t()]) :: [map()]
  def by_ids(issues, ids) when is_list(issues) and is_list(ids) do
    set = MapSet.new(ids)
    Enum.filter(issues, fn issue -> Map.get(issue, "id") in set end)
  end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_issue_store_test.exs`
Expected: 14 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker_server/issue_store.ex \
        elixir/test/symphony_elixir/tracker_server_issue_store_test.exs
git commit -m "feat(tracker-server): IssueStore.search and by_ids"
```

---

### Task 4: `IssueStore.update_state/3`

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker_server/issue_store.ex`
- Modify: `elixir/test/symphony_elixir/tracker_server_issue_store_test.exs`

- [ ] **Step 1: Append failing tests**

```elixir
  test "update_state writes new state and preserves other fields", %{file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo","description":"d"}
    ]}))

    assert :ok = IssueStore.update_state(file, "a", "Done")

    {:ok, [issue]} = IssueStore.load(file)
    assert issue["state"] == "Done"
    assert issue["description"] == "d"
  end

  test "update_state refreshes updated_at when present, leaves original timestamp behind", %{file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo","updated_at":"2020-01-01T00:00:00Z"}
    ]}))

    assert :ok = IssueStore.update_state(file, "a", "Done")

    {:ok, [issue]} = IssueStore.load(file)
    assert issue["updated_at"] != "2020-01-01T00:00:00Z"
    assert {:ok, _, _} = DateTime.from_iso8601(issue["updated_at"])
  end

  test "update_state does not add updated_at when absent", %{file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo"}
    ]}))

    assert :ok = IssueStore.update_state(file, "a", "Done")

    {:ok, [issue]} = IssueStore.load(file)
    refute Map.has_key?(issue, "updated_at")
  end

  test "update_state refreshes camelCase updatedAt when present", %{file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo","updatedAt":"2020-01-01T00:00:00Z"}
    ]}))

    assert :ok = IssueStore.update_state(file, "a", "Done")

    {:ok, [issue]} = IssueStore.load(file)
    assert issue["updatedAt"] != "2020-01-01T00:00:00Z"
  end

  test "update_state returns unknown_issue_id when no match", %{file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo"}
    ]}))

    assert {:error, :unknown_issue_id} = IssueStore.update_state(file, "missing", "Done")
  end

  test "update_state preserves issue order", %{file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo"},
      {"id":"b","identifier":"X-2","title":"t","state":"Todo"},
      {"id":"c","identifier":"X-3","title":"t","state":"Todo"}
    ]}))

    assert :ok = IssueStore.update_state(file, "b", "Done")

    {:ok, issues} = IssueStore.load(file)
    assert Enum.map(issues, & &1["id"]) == ["a", "b", "c"]
  end

  test "update_state leaves no .tmp file behind on success", %{file: file} do
    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"t","state":"Todo"}
    ]}))

    assert :ok = IssueStore.update_state(file, "a", "Done")
    refute File.exists?(file <> ".tmp")
  end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_issue_store_test.exs`
Expected: 7 new failures.

- [ ] **Step 3: Implement `update_state/3`**

Add to `issue_store.ex`:

```elixir
  @spec update_state(Path.t(), String.t(), String.t()) ::
          :ok | {:error, :unknown_issue_id | term()}
  def update_state(path, id, new_state)
      when is_binary(path) and is_binary(id) and is_binary(new_state) do
    with {:ok, issues} <- load(path),
         {:ok, updated} <- replace_state(issues, id, new_state) do
      write_atomic(path, %{"issues" => updated})
    end
  end

  defp replace_state(issues, id, new_state) do
    {updated, found?} =
      Enum.map_reduce(issues, false, fn issue, acc ->
        if Map.get(issue, "id") == id do
          new_issue =
            issue
            |> Map.put("state", new_state)
            |> maybe_refresh_updated_at()

          {new_issue, true}
        else
          {issue, acc}
        end
      end)

    if found?, do: {:ok, updated}, else: {:error, :unknown_issue_id}
  end

  defp maybe_refresh_updated_at(issue) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    cond do
      Map.has_key?(issue, "updated_at") -> Map.put(issue, "updated_at", now)
      Map.has_key?(issue, "updatedAt") -> Map.put(issue, "updatedAt", now)
      true -> issue
    end
  end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_issue_store_test.exs`
Expected: 21 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker_server/issue_store.ex \
        elixir/test/symphony_elixir/tracker_server_issue_store_test.exs
git commit -m "feat(tracker-server): IssueStore.update_state with atomic write"
```

---

### Task 5: `CommentLog` GenServer

**Files:**
- Create: `elixir/lib/symphony_elixir/tracker_server/comment_log.ex`
- Create: `elixir/test/symphony_elixir/tracker_server_comment_log_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
defmodule SymphonyElixir.TrackerServerCommentLogTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TrackerServer.CommentLog

  setup do
    dir = Path.join(System.tmp_dir!(), "tracker-comments-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, %{file: Path.join(dir, "comments.jsonl")}}
  end

  defp lines(file), do: file |> File.read!() |> String.split("\n", trim: true)

  defp decode_line(line) do
    {:ok, value} = Jason.decode(line)
    value
  end

  test "append serializes one JSONL line per call", %{file: file} do
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

  test "append auto-creates the file if it does not exist", %{file: file} do
    refute File.exists?(file)
    name = :"comment_log_create_#{System.unique_integer([:positive])}"
    {:ok, _pid} = CommentLog.start_link(name: name, path: file)

    assert :ok = CommentLog.append(name, "task-1", "first")
    assert File.exists?(file)
    assert [_one] = lines(file)
  end

  test "concurrent callers all see :ok and the file ends with N lines", %{file: file} do
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
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_comment_log_test.exs`
Expected: FAIL with "module SymphonyElixir.TrackerServer.CommentLog is not loaded".

- [ ] **Step 3: Implement `CommentLog`**

```elixir
# elixir/lib/symphony_elixir/tracker_server/comment_log.ex
defmodule SymphonyElixir.TrackerServer.CommentLog do
  @moduledoc """
  Serialized append-only writer for the local custom_http tracker's
  `tracker.comments.jsonl` sidecar.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    path = Keyword.fetch!(opts, :path)
    GenServer.start_link(__MODULE__, %{path: path}, name: name)
  end

  @spec append(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def append(server \\ __MODULE__, issue_id, body)
      when is_binary(issue_id) and is_binary(body) do
    GenServer.call(server, {:append, issue_id, body})
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:append, issue_id, body}, _from, state) do
    entry = %{
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "issue_id" => issue_id,
      "body" => body
    }

    case do_append(state.path, entry) do
      :ok -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  defp do_append(path, entry) do
    with {:ok, encoded} <- Jason.encode(entry),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, encoded <> "\n", [:append]) do
      :ok
    end
  end
end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_comment_log_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker_server/comment_log.ex \
        elixir/test/symphony_elixir/tracker_server_comment_log_test.exs
git commit -m "feat(tracker-server): CommentLog GenServer for append-only JSONL"
```

---

### Task 6: `Router` skeleton + bearer auth + `POST /issues/search`

**Files:**
- Create: `elixir/lib/symphony_elixir/tracker_server/router.ex`
- Create: `elixir/test/symphony_elixir/tracker_server_router_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
defmodule SymphonyElixir.TrackerServerRouterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias SymphonyElixir.TrackerServer.{CommentLog, Router}

  setup do
    dir = Path.join(System.tmp_dir!(), "tracker-router-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "tracker.json")
    comments = Path.join(dir, "comments.jsonl")

    File.write!(file, ~s({"issues":[
      {"id":"a","identifier":"X-1","title":"todo task","state":"Todo"},
      {"id":"b","identifier":"X-2","title":"done task","state":"Done"}
    ]}))

    name = :"router_log_#{System.unique_integer([:positive])}"
    {:ok, _pid} = CommentLog.start_link(name: name, path: comments)

    Application.put_env(:symphony_elixir, :tracker_server_file, file)
    Application.put_env(:symphony_elixir, :tracker_server_comment_log, name)
    Application.delete_env(:symphony_elixir, :tracker_server_token)

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.delete_env(:symphony_elixir, :tracker_server_file)
      Application.delete_env(:symphony_elixir, :tracker_server_comment_log)
      Application.delete_env(:symphony_elixir, :tracker_server_token)
    end)

    {:ok, %{file: file, comments: comments}}
  end

  defp call(method, path, body, headers \\ []) do
    payload = if is_binary(body), do: body, else: Jason.encode!(body)

    conn =
      conn(method, path, payload)
      |> put_req_header("content-type", "application/json")

    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> Router.call(Router.init([]))
  end

  test "POST /issues/search returns issues filtered by state" do
    conn = call(:post, "/issues/search", %{"states" => ["Todo"]})
    assert conn.status == 200
    assert %{"issues" => [issue]} = Jason.decode!(conn.resp_body)
    assert issue["id"] == "a"
  end

  test "POST /issues/search with empty states returns empty array" do
    conn = call(:post, "/issues/search", %{"states" => []})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"issues" => []}
  end

  test "POST /issues/search with non-array states returns 400" do
    conn = call(:post, "/issues/search", %{"states" => "Todo"})
    assert conn.status == 400
  end

  test "POST /issues/search with malformed JSON returns 400" do
    conn = call(:post, "/issues/search", "{not json")
    assert conn.status == 400
  end

  test "POST /issues/search with token configured and missing header returns 401" do
    Application.put_env(:symphony_elixir, :tracker_server_token, "secret")
    conn = call(:post, "/issues/search", %{"states" => ["Todo"]})
    assert conn.status == 401
  end

  test "POST /issues/search with token configured and matching header returns 200" do
    Application.put_env(:symphony_elixir, :tracker_server_token, "secret")
    conn = call(:post, "/issues/search", %{"states" => ["Todo"]}, [{"authorization", "Bearer secret"}])
    assert conn.status == 200
  end

  test "POST /issues/search with token configured and wrong header returns 401" do
    Application.put_env(:symphony_elixir, :tracker_server_token, "secret")
    conn = call(:post, "/issues/search", %{"states" => ["Todo"]}, [{"authorization", "Bearer wrong"}])
    assert conn.status == 401
  end
end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_router_test.exs`
Expected: FAIL — Router module not loaded.

- [ ] **Step 3: Implement Router skeleton with auth + search**

```elixir
# elixir/lib/symphony_elixir/tracker_server/router.ex
defmodule SymphonyElixir.TrackerServer.Router do
  @moduledoc """
  Plug.Router implementing the four `custom_http` tracker endpoints
  (SPEC §11.3).
  """
  use Plug.Router

  alias SymphonyElixir.TrackerServer.IssueStore

  plug :match
  plug Plug.Logger, log: :info
  plug :authenticate
  plug :dispatch

  post "/issues/search" do
    case read_json_body(conn) do
      {:ok, body, conn} -> handle_search(conn, body)
      {:error, conn} -> bad_request(conn)
    end
  end

  match _ do
    send_json(conn, 404, %{"success" => false, "error" => "not_found"})
  end

  defp handle_search(conn, body) do
    case fetch_string_array(body, "states") do
      {:ok, states} ->
        file = Application.fetch_env!(:symphony_elixir, :tracker_server_file)

        case IssueStore.load(file) do
          {:ok, issues} ->
            send_json(conn, 200, %{"issues" => IssueStore.search(issues, states)})

          {:error, reason} ->
            send_json(conn, 500, %{"success" => false, "error" => inspect(reason)})
        end

      :error ->
        bad_request(conn)
    end
  end

  defp authenticate(conn, _opts) do
    case Application.get_env(:symphony_elixir, :tracker_server_token) do
      token when is_binary(token) and token != "" ->
        verify_token(conn, token)

      _ ->
        conn
    end
  end

  defp verify_token(conn, expected) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> presented] ->
        if Plug.Crypto.secure_compare(presented, expected) do
          conn
        else
          conn |> unauthorized() |> halt()
        end

      _ ->
        conn |> unauthorized() |> halt()
    end
  end

  defp unauthorized(conn) do
    send_json(conn, 401, %{"success" => false, "error" => "unauthorized"})
  end

  defp bad_request(conn) do
    send_json(conn, 400, %{"success" => false, "error" => "bad_request"})
  end

  defp read_json_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, raw, conn} ->
        case Jason.decode(raw) do
          {:ok, %{} = decoded} -> {:ok, decoded, conn}
          _ -> {:error, conn}
        end

      {:more, _partial, conn} ->
        {:error, conn}

      {:error, _reason} ->
        {:error, conn}
    end
  end

  defp fetch_string_array(body, key) do
    case Map.get(body, key) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: :error

      _ ->
        :error
    end
  end

  defp fetch_non_empty_string(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp send_json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end
end
```

(`fetch_non_empty_string/2` is added now even though it isn't used until Tasks 8/9; that keeps the helper section stable so later tasks don't have to repeat its definition.)

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_router_test.exs`
Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker_server/router.ex \
        elixir/test/symphony_elixir/tracker_server_router_test.exs
git commit -m "feat(tracker-server): Router with bearer auth and /issues/search"
```

---

### Task 7: `POST /issues/by_ids` route

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker_server/router.ex`
- Modify: `elixir/test/symphony_elixir/tracker_server_router_test.exs`

- [ ] **Step 1: Append failing tests**

```elixir
  test "POST /issues/by_ids returns matching issues, drops unknown ids" do
    conn = call(:post, "/issues/by_ids", %{"ids" => ["a", "missing"]})
    assert conn.status == 200
    assert %{"issues" => [issue]} = Jason.decode!(conn.resp_body)
    assert issue["id"] == "a"
  end

  test "POST /issues/by_ids with non-array ids returns 400" do
    conn = call(:post, "/issues/by_ids", %{"ids" => "a"})
    assert conn.status == 400
  end

  test "POST /issues/by_ids with empty ids returns empty array" do
    conn = call(:post, "/issues/by_ids", %{"ids" => []})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"issues" => []}
  end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_router_test.exs`
Expected: 3 new failures (404 from match-all).

- [ ] **Step 3: Add route handler**

Insert before the `match _ do` clause in `router.ex`:

```elixir
  post "/issues/by_ids" do
    case read_json_body(conn) do
      {:ok, body, conn} -> handle_by_ids(conn, body)
      {:error, conn} -> bad_request(conn)
    end
  end
```

And add the helper alongside `handle_search/2`:

```elixir
  defp handle_by_ids(conn, body) do
    case fetch_string_array(body, "ids") do
      {:ok, ids} ->
        file = Application.fetch_env!(:symphony_elixir, :tracker_server_file)

        case IssueStore.load(file) do
          {:ok, issues} ->
            send_json(conn, 200, %{"issues" => IssueStore.by_ids(issues, ids)})

          {:error, reason} ->
            send_json(conn, 500, %{"success" => false, "error" => inspect(reason)})
        end

      :error ->
        bad_request(conn)
    end
  end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_router_test.exs`
Expected: 10 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker_server/router.ex \
        elixir/test/symphony_elixir/tracker_server_router_test.exs
git commit -m "feat(tracker-server): /issues/by_ids route"
```

---

### Task 8: `POST /issues/:id/comments` route

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker_server/router.ex`
- Modify: `elixir/test/symphony_elixir/tracker_server_router_test.exs`

- [ ] **Step 1: Append failing tests**

```elixir
  test "POST /issues/:id/comments writes a JSONL line and returns success", %{comments: comments} do
    conn = call(:post, "/issues/a/comments", %{"body" => "agent: starting"})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"success" => true}

    [line] = comments |> File.read!() |> String.split("\n", trim: true)
    assert %{"issue_id" => "a", "body" => "agent: starting", "at" => _} = Jason.decode!(line)
  end

  test "POST /issues/:id/comments with empty body returns 400" do
    conn = call(:post, "/issues/a/comments", %{"body" => ""})
    assert conn.status == 400
  end

  test "POST /issues/:id/comments with missing body returns 400" do
    conn = call(:post, "/issues/a/comments", %{})
    assert conn.status == 400
  end

  test "POST /issues/:id/comments does not validate id existence" do
    conn = call(:post, "/issues/does-not-exist/comments", %{"body" => "stray"})
    assert conn.status == 200
  end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_router_test.exs`
Expected: 4 new failures.

- [ ] **Step 3: Add route handler and `CommentLog` alias**

Add `CommentLog` to the existing alias at the top of `router.ex`:

```elixir
  alias SymphonyElixir.TrackerServer.{CommentLog, IssueStore}
```

Insert before the `match _ do` clause:

```elixir
  post "/issues/:id/comments" do
    case read_json_body(conn) do
      {:ok, body, conn} -> handle_comment(conn, id, body)
      {:error, conn} -> bad_request(conn)
    end
  end
```

And the helper alongside the others:

```elixir
  defp handle_comment(conn, id, body) do
    case fetch_non_empty_string(body, "body") do
      {:ok, comment_body} ->
        log = Application.fetch_env!(:symphony_elixir, :tracker_server_comment_log)

        case CommentLog.append(log, id, comment_body) do
          :ok ->
            send_json(conn, 200, %{"success" => true})

          {:error, reason} ->
            send_json(conn, 500, %{"success" => false, "error" => inspect(reason)})
        end

      :error ->
        bad_request(conn)
    end
  end
```

(`fetch_non_empty_string/2` was added in Task 6's helper block, no new helper needed here.)

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_router_test.exs`
Expected: 14 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker_server/router.ex \
        elixir/test/symphony_elixir/tracker_server_router_test.exs
git commit -m "feat(tracker-server): /issues/:id/comments route"
```

---

### Task 9: `PATCH /issues/:id` route

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker_server/router.ex`
- Modify: `elixir/test/symphony_elixir/tracker_server_router_test.exs`

- [ ] **Step 1: Append failing tests**

```elixir
  test "PATCH /issues/:id updates state and returns success", %{file: file} do
    conn = call(:patch, "/issues/a", %{"state" => "Done"})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"success" => true}

    {:ok, %{"issues" => issues}} = Jason.decode(File.read!(file))
    assert Enum.find(issues, &(&1["id"] == "a"))["state"] == "Done"
  end

  test "PATCH /issues/:id with empty state returns 400" do
    conn = call(:patch, "/issues/a", %{"state" => ""})
    assert conn.status == 400
  end

  test "PATCH /issues/:id with missing state returns 400" do
    conn = call(:patch, "/issues/a", %{})
    assert conn.status == 400
  end

  test "PATCH /issues/:id with unknown id returns 404" do
    conn = call(:patch, "/issues/missing", %{"state" => "Done"})
    assert conn.status == 404
    assert %{"success" => false, "error" => "unknown_issue_id"} = Jason.decode!(conn.resp_body)
  end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_router_test.exs`
Expected: 4 new failures.

- [ ] **Step 3: Add route handler**

Insert before the `match _ do` clause:

```elixir
  patch "/issues/:id" do
    case read_json_body(conn) do
      {:ok, body, conn} -> handle_patch(conn, id, body)
      {:error, conn} -> bad_request(conn)
    end
  end
```

And the helper:

```elixir
  defp handle_patch(conn, id, body) do
    case fetch_non_empty_string(body, "state") do
      {:ok, new_state} ->
        file = Application.fetch_env!(:symphony_elixir, :tracker_server_file)

        case IssueStore.update_state(file, id, new_state) do
          :ok ->
            send_json(conn, 200, %{"success" => true})

          {:error, :unknown_issue_id} ->
            send_json(conn, 404, %{"success" => false, "error" => "unknown_issue_id"})

          {:error, reason} ->
            send_json(conn, 500, %{"success" => false, "error" => inspect(reason)})
        end

      :error ->
        bad_request(conn)
    end
  end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_router_test.exs`
Expected: 18 tests, 0 failures.

- [ ] **Step 5: Verify 404 fallback still works (regression check)**

Append one final test:

```elixir
  test "unknown route returns 404" do
    conn = call(:get, "/no-such-thing", %{})
    assert conn.status == 404
  end
```

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_router_test.exs`
Expected: 19 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker_server/router.ex \
        elixir/test/symphony_elixir/tracker_server_router_test.exs
git commit -m "feat(tracker-server): PATCH /issues/:id route + 404 fallback"
```

---

### Task 10: `Application` supervision tree

**Files:**
- Create: `elixir/lib/symphony_elixir/tracker_server/application.ex`

No test (this module is in `ignore_modules` per the design).

- [ ] **Step 1: Implement the supervision tree**

```elixir
# elixir/lib/symphony_elixir/tracker_server/application.ex
defmodule SymphonyElixir.TrackerServer.Application do
  @moduledoc false
  use Application

  alias SymphonyElixir.TrackerServer.{CommentLog, Router}

  @impl Application
  def start(_type, _args) do
    bandit_opts = Application.fetch_env!(:symphony_elixir, :tracker_server_bandit_opts)
    comment_log_path = Application.fetch_env!(:symphony_elixir, :tracker_server_comments_path)

    children = [
      {CommentLog, name: CommentLog, path: comment_log_path},
      {Bandit, [plug: Router] ++ bandit_opts}
    ]

    Application.put_env(:symphony_elixir, :tracker_server_comment_log, CommentLog)

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
```

- [ ] **Step 2: Verify it compiles**

Run: `cd elixir && mise exec -- mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 3: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker_server/application.ex
git commit -m "feat(tracker-server): supervision tree"
```

---

### Task 11: `CLI` argv parser + main entrypoint

**Files:**
- Create: `elixir/lib/symphony_elixir/tracker_server/cli.ex`
- Create: `elixir/test/symphony_elixir/tracker_server_cli_test.exs`

- [ ] **Step 1: Write failing tests for the pure parser**

```elixir
defmodule SymphonyElixir.TrackerServerCliTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TrackerServer.CLI

  setup do
    previous = System.get_env("SYMPHONY_TRACKER_API_KEY")
    System.delete_env("SYMPHONY_TRACKER_API_KEY")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("SYMPHONY_TRACKER_API_KEY")
        value -> System.put_env("SYMPHONY_TRACKER_API_KEY", value)
      end
    end)

    :ok
  end

  test "parse returns defaults when no args" do
    assert {:ok, config} = CLI.parse([])
    assert config.file == Path.expand("./tracker.json")
    assert config.comments_path == Path.expand("./tracker.comments.jsonl")
    assert config.port == 8787
    assert config.bind == "127.0.0.1"
    assert is_nil(config.token)
  end

  test "parse honors flags" do
    assert {:ok, config} =
             CLI.parse([
               "--file",
               "/tmp/x.json",
               "--port",
               "9999",
               "--bind",
               "0.0.0.0",
               "--token",
               "secret"
             ])

    assert config.file == "/tmp/x.json"
    assert config.comments_path == "/tmp/x.comments.jsonl"
    assert config.port == 9999
    assert config.bind == "0.0.0.0"
    assert config.token == "secret"
  end

  test "parse derives sidecar from non-.json filename" do
    assert {:ok, config} = CLI.parse(["--file", "/tmp/store.db"])
    assert config.comments_path == "/tmp/store.db.comments.jsonl"
  end

  test "parse expands ~ in --file" do
    assert {:ok, config} = CLI.parse(["--file", "~/tracker.json"])
    refute String.starts_with?(config.file, "~")
    assert String.ends_with?(config.file, "/tracker.json")
  end

  test "parse falls back to SYMPHONY_TRACKER_API_KEY when --token absent" do
    System.put_env("SYMPHONY_TRACKER_API_KEY", "envtoken")
    assert {:ok, config} = CLI.parse([])
    assert config.token == "envtoken"
  end

  test "parse prefers --token over env var" do
    System.put_env("SYMPHONY_TRACKER_API_KEY", "envtoken")
    assert {:ok, config} = CLI.parse(["--token", "flagtoken"])
    assert config.token == "flagtoken"
  end

  test "parse rejects unknown flag" do
    assert {:error, message} = CLI.parse(["--bogus"])
    assert message =~ "Usage:"
  end

  test "parse rejects --port that is not an integer" do
    assert {:error, _message} = CLI.parse(["--port", "abc"])
  end

  test "parse handles --help" do
    assert {:help, message} = CLI.parse(["--help"])
    assert message =~ "Usage:"
  end
end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_cli_test.exs`
Expected: FAIL — module not loaded.

- [ ] **Step 3: Implement `CLI`**

```elixir
# elixir/lib/symphony_elixir/tracker_server/cli.ex
defmodule SymphonyElixir.TrackerServer.CLI do
  @moduledoc """
  Escript entrypoint for `bin/symphony-tracker`. Parses argv into a config
  map and starts the tracker server supervision tree.
  """

  @switches [file: :string, port: :integer, bind: :string, token: :string, help: :boolean]
  @aliases [h: :help]

  @type config :: %{
          file: Path.t(),
          comments_path: Path.t(),
          port: non_neg_integer(),
          bind: String.t(),
          token: String.t() | nil
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case parse(args) do
      {:ok, config} ->
        :ok = start_application(config)
        print_banner(config)
        Process.sleep(:infinity)

      {:help, message} ->
        IO.puts(message)
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(2)
    end
  end

  @spec parse([String.t()]) :: {:ok, config()} | {:help, String.t()} | {:error, String.t()}
  def parse(args) do
    try do
      case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
        {opts, [], []} ->
          if Keyword.get(opts, :help, false) do
            {:help, usage()}
          else
            build_config(opts)
          end

        {_opts, _positional, [_ | _] = invalid} ->
          {:error, "Invalid flag: #{inspect(invalid)}\n#{usage()}"}

        {_opts, [_ | _] = positional, _} ->
          {:error, "Unexpected positional args: #{inspect(positional)}\n#{usage()}"}
      end
    rescue
      error in OptionParser.ParseError ->
        {:error, "#{Exception.message(error)}\n#{usage()}"}
    end
  end

  defp build_config(opts) do
    file =
      opts
      |> Keyword.get(:file, "./tracker.json")
      |> Path.expand()

    comments_path = derive_comments_path(file)

    {:ok,
     %{
       file: file,
       comments_path: comments_path,
       port: Keyword.get(opts, :port, 8787),
       bind: Keyword.get(opts, :bind, "127.0.0.1"),
       token: Keyword.get(opts, :token) || System.get_env("SYMPHONY_TRACKER_API_KEY")
     }}
  end

  defp derive_comments_path(file) do
    if String.ends_with?(file, ".json") do
      String.replace_suffix(file, ".json", ".comments.jsonl")
    else
      file <> ".comments.jsonl"
    end
  end

  defp start_application(config) do
    bandit_opts = [
      scheme: :http,
      port: config.port,
      ip: parse_bind(config.bind)
    ]

    Application.put_env(:symphony_elixir, :tracker_server_file, config.file)
    Application.put_env(:symphony_elixir, :tracker_server_comments_path, config.comments_path)
    Application.put_env(:symphony_elixir, :tracker_server_bandit_opts, bandit_opts)

    if is_binary(config.token) and config.token != "" do
      Application.put_env(:symphony_elixir, :tracker_server_token, config.token)
    else
      Application.delete_env(:symphony_elixir, :tracker_server_token)
    end

    # Start only the libs we need; do NOT start :symphony_elixir, which
    # would boot the orchestrator. :bandit pulls in :plug, :plug_crypto,
    # :thousand_island, :telemetry transitively.
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:jason)

    case SymphonyElixir.TrackerServer.Application.start(:normal, []) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp parse_bind("127.0.0.1"), do: {127, 0, 0, 1}
  defp parse_bind("0.0.0.0"), do: {0, 0, 0, 0}

  defp parse_bind(other) do
    case :inet.parse_address(String.to_charlist(other)) do
      {:ok, addr} -> addr
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  defp print_banner(config) do
    {:ok, issues} = SymphonyElixir.TrackerServer.IssueStore.load(config.file)
    state_counts = issues |> Enum.frequencies_by(& &1["state"])

    IO.puts("""
    Symphony Tracker listening on http://#{config.bind}:#{config.port}
      file:     #{config.file}
      comments: #{config.comments_path}
      auth:     #{auth_banner(config.token)}
      issues:   #{length(issues)} (#{format_state_counts(state_counts)})
    """)
  end

  defp auth_banner(nil), do: "open (no token configured)"
  defp auth_banner(""), do: "open (no token configured)"
  defp auth_banner(token), do: "bearer token (length #{String.length(token)})"

  defp format_state_counts(counts) when map_size(counts) == 0, do: "no issues"

  defp format_state_counts(counts) do
    counts
    |> Enum.sort()
    |> Enum.map_join(", ", fn {state, n} -> "#{state}×#{n}" end)
  end

  defp usage do
    """
    Usage: symphony-tracker [--file PATH] [--port N] [--bind ADDR] [--token TOKEN]

      --file   Path to tracker.json. Default: ./tracker.json
      --port   HTTP listen port. Default: 8787
      --bind   Listen address. Default: 127.0.0.1
      --token  Bearer token. Falls back to SYMPHONY_TRACKER_API_KEY.
      --help   Print this message and exit.
    """
  end
end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_server_cli_test.exs`
Expected: 9 tests, 0 failures.

- [ ] **Step 5: Verify whole test suite still passes**

Run: `cd elixir && mise exec -- mix test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker_server/cli.ex \
        elixir/test/symphony_elixir/tracker_server_cli_test.exs
git commit -m "feat(tracker-server): CLI argv parser and main entrypoint"
```

---

### Task 12: Mix task `tracker_server.escript`

**Files:**
- Create: `elixir/lib/mix/tasks/tracker_server.escript.ex`

No test (in `ignore_modules`).

- [ ] **Step 1: Implement the Mix task**

```elixir
# elixir/lib/mix/tasks/tracker_server.escript.ex
defmodule Mix.Tasks.TrackerServer.Escript do
  @shortdoc "Builds bin/symphony-tracker by re-running escript.build with MIX_ESCRIPT_TARGET=tracker"
  @moduledoc @shortdoc

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    System.put_env("MIX_ESCRIPT_TARGET", "tracker")
    Mix.Task.reenable("escript.build")

    try do
      Mix.Task.run("escript.build", args)
    after
      System.delete_env("MIX_ESCRIPT_TARGET")
    end
  end
end
```

- [ ] **Step 2: Verify the task is recognized**

Run: `cd elixir && mise exec -- mix help tracker_server.escript`
Expected: prints the shortdoc.

- [ ] **Step 3: Commit**

```bash
git add elixir/lib/mix/tasks/tracker_server.escript.ex
git commit -m "feat(tracker-server): mix task to build bin/symphony-tracker"
```

---

### Task 13: `mix.exs` — dual-target escript, build alias, ignore_modules

**Files:**
- Modify: `elixir/mix.exs`

- [ ] **Step 1: Update `escript/0` to switch by env var**

In `elixir/mix.exs`, replace the existing `escript/0` body with:

```elixir
  defp escript do
    case System.get_env("MIX_ESCRIPT_TARGET") do
      "tracker" ->
        [
          app: nil,
          main_module: SymphonyElixir.TrackerServer.CLI,
          name: "symphony-tracker",
          path: "bin/symphony-tracker"
        ]

      _ ->
        [
          app: nil,
          main_module: SymphonyElixir.CLI,
          name: "symphony",
          path: "bin/symphony"
        ]
    end
  end
```

- [ ] **Step 2: Update the `build` alias to produce both binaries**

Find:

```elixir
      build: ["escript.build"],
```

Replace with:

```elixir
      build: ["escript.build", "tracker_server.escript"],
```

- [ ] **Step 3: Add new modules to `ignore_modules`**

In the `:test_coverage` keyword list, append to `ignore_modules`:

```elixir
          SymphonyElixir.TrackerServer.Application,
          SymphonyElixir.TrackerServer.CLI,
          Mix.Tasks.TrackerServer.Escript,
```

The full updated `ignore_modules` list should keep all existing entries and add the three new ones.

- [ ] **Step 4: Verify both binaries build**

Run: `cd elixir && rm -f bin/symphony bin/symphony-tracker && mise exec -- mix build`
Expected: both `bin/symphony` and `bin/symphony-tracker` exist.

```bash
ls -l elixir/bin/symphony elixir/bin/symphony-tracker
```

- [ ] **Step 5: Verify the tracker escript boots and accepts --help**

Run: `cd elixir && ./bin/symphony-tracker --help`
Expected: prints usage, exits 0.

- [ ] **Step 6: Verify test suite still passes**

Run: `cd elixir && mise exec -- mix test`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add elixir/mix.exs
git commit -m "build(tracker-server): produce bin/symphony-tracker via dual-target escript"
```

---

### Task 14: End-to-end test against real Bandit listener

**Files:**
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

This test brings up real Bandit + the new Router on `127.0.0.1` with a free port and points the existing `SymphonyElixir.Tracker.CustomHttp` *client* at it, exercising all four operations.

- [ ] **Step 1: Append the new test**

Append to the bottom of the existing `extensions_test.exs` (above the closing `end` of the module), but inside the existing `describe`/test list. Following the pattern of the existing `"tracker delegates to custom http adapter"` test:

```elixir
  test "custom http adapter talks to a real local tracker server end-to-end" do
    dir = Path.join(System.tmp_dir!(), "tracker-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    file = Path.join(dir, "tracker.json")
    comments = Path.join(dir, "tracker.comments.jsonl")

    File.write!(file, ~s({"issues":[
      {"id":"e2e-1","identifier":"E2E-1","title":"end to end","state":"Todo"}
    ]}))

    log_name = :"e2e_log_#{System.unique_integer([:positive])}"
    {:ok, _log_pid} = SymphonyElixir.TrackerServer.CommentLog.start_link(name: log_name, path: comments)

    Application.put_env(:symphony_elixir, :tracker_server_file, file)
    Application.put_env(:symphony_elixir, :tracker_server_comment_log, log_name)
    Application.delete_env(:symphony_elixir, :tracker_server_token)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :tracker_server_file)
      Application.delete_env(:symphony_elixir, :tracker_server_comment_log)
    end)

    port = find_free_port()

    {:ok, server_pid} =
      Bandit.start_link(
        plug: SymphonyElixir.TrackerServer.Router,
        scheme: :http,
        port: port,
        ip: {127, 0, 0, 1}
      )

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :normal)
    end)

    # Reset client request fun to the real Req.request so HTTP actually flows.
    Application.delete_env(:symphony_elixir, :custom_http_tracker_request_fun)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "custom_http",
      tracker_endpoint: "http://127.0.0.1:#{port}",
      tracker_api_token: nil
    )

    assert :ok = Config.validate!()

    assert {:ok, [issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert issue.id == "e2e-1"
    assert issue.state == "Todo"

    assert :ok = SymphonyElixir.Tracker.update_issue_state("e2e-1", "Done")

    assert {:ok, [refreshed]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["e2e-1"])
    assert refreshed.state == "Done"

    assert :ok = SymphonyElixir.Tracker.create_comment("e2e-1", "agent: e2e ran")

    # CommentLog uses GenServer.call, so the HTTP 200 already implies the
    # disk write completed; no sleep needed.
    [line] = comments |> File.read!() |> String.split("\n", trim: true)
    assert %{"issue_id" => "e2e-1", "body" => "agent: e2e ran"} = Jason.decode!(line)
  end

  defp find_free_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end
```

Note: `find_free_port/0` must be defined as a regular module function (not inside `setup`). If the module already has a private helper section, append it there; otherwise add it just above the closing `end`.

- [ ] **Step 2: Run the new test**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/extensions_test.exs`
Expected: all tests in the module pass, including the new e2e case.

- [ ] **Step 3: Run the full suite**

Run: `cd elixir && mise exec -- mix test`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add elixir/test/symphony_elixir/extensions_test.exs
git commit -m "test(tracker-server): end-to-end CustomHttp client against real server"
```

---

### Task 15: README documentation

**Files:**
- Modify: `elixir/README.md`

- [ ] **Step 1: Add the tracker server section after the existing custom_http config block**

Open `elixir/README.md`. Find the line:

```
  terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"]
```

(end of the YAML config example, around line 119 in the working tree; locate by content, not absolute line number, since other in-flight changes may have shifted lines).

Immediately **after** the closing ` ``` ` of that fenced block (and before the line `The custom HTTP tracker expects a small JSON API:`), insert:

```markdown
### Running a local tracker server

If you don't have an existing `custom_http` server, the bundled
`bin/symphony-tracker` escript implements the contract above against a
hand-editable JSON file:

```bash
./bin/symphony-tracker --file ./tracker.json --port 8787
```

Flags:

- `--file` — path to the tracker JSON. Default `./tracker.json`. Created
  empty (`{"issues": []}`) on first start if missing.
- `--port` — HTTP listen port. Default `8787`.
- `--bind` — listen address. Default `127.0.0.1`. Use `0.0.0.0` only when
  you also set `--token`; the server has no other auth.
- `--token` — Bearer token. Falls back to `SYMPHONY_TRACKER_API_KEY`. When
  unset, requests are not authenticated.

The server reads from two files:

- `tracker.json` — your source of truth. Edit by hand to add/remove issues;
  `PATCH /issues/:id` from Symphony writes back here atomically. Each issue
  must have non-empty string `id`, `identifier`, `title`, and `state`; `id`
  must be unique within the file.
- `tracker.comments.jsonl` — append-only log of agent comments, one JSON
  object per line. Created on the first comment.

Minimal `tracker.json` to get started:

```json
{
  "issues": [
    {
      "id": "task-1",
      "identifier": "LOCAL-1",
      "title": "Try the local tracker",
      "state": "Todo"
    }
  ]
}
```

Caveat: hand-editing the same `state` field that Symphony is concurrently
PATCHing can clobber the agent's write. Prefer to edit issues that are not
currently being worked.
```

(The triple-backtick fences inside the markdown block above are intentional.)

- [ ] **Step 2: Verify rendered output**

Run: `cd elixir && grep -A 3 'Running a local tracker server' README.md`
Expected: section heading and following paragraph appear.

- [ ] **Step 3: Commit**

```bash
git add elixir/README.md
git commit -m "docs(tracker-server): add bin/symphony-tracker usage section"
```

---

## Final Verification

- [ ] **Run full test suite**

```bash
cd /Users/treedy/Project/symphony/elixir && mise exec -- mix test
```

Expected: all tests pass, no warnings.

- [ ] **Verify coverage threshold holds**

```bash
cd /Users/treedy/Project/symphony/elixir && mise exec -- mix test --cover
```

Expected: 100% summary threshold satisfied.

- [ ] **Verify both escripts build clean from scratch**

```bash
cd /Users/treedy/Project/symphony/elixir && rm -f bin/symphony bin/symphony-tracker && mise exec -- mix build
ls -l bin/symphony bin/symphony-tracker
```

Expected: both binaries present, executable.

- [ ] **Smoke-test the binary**

```bash
cd /tmp && /Users/treedy/Project/symphony/elixir/bin/symphony-tracker --help
```

Expected: usage banner, exit 0.

```bash
cd /tmp && /Users/treedy/Project/symphony/elixir/bin/symphony-tracker --port 18787 &
SERVER_PID=$!
sleep 1
curl -s -X POST http://127.0.0.1:18787/issues/search -H 'content-type: application/json' -d '{"states":["Todo"]}'
kill $SERVER_PID
```

Expected: `{"issues":[]}` (empty since `/tmp/tracker.json` was just auto-created).
