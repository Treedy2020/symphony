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

    {:ok, %{tracker_file: file, comments_file: comments, dir: dir}}
  end

  defp set_corrupted_tracker_file(dir) do
    path = Path.join(dir, "corrupted.json")
    File.write!(path, "{not actually json")
    Application.put_env(:symphony_elixir, :tracker_server_file, path)
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

  test "POST /issues/by_ids with malformed JSON returns 400" do
    conn = call(:post, "/issues/by_ids", "{not json")
    assert conn.status == 400
  end

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

  test "POST /issues/:id/comments with malformed JSON returns 400" do
    conn = call(:post, "/issues/a/comments", "{not json")
    assert conn.status == 400
  end

  test "POST /issues/:id/comments writes a JSONL line and returns success", %{comments_file: comments} do
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

  test "PATCH /issues/:id with malformed JSON returns 400" do
    conn = call(:patch, "/issues/a", "{not json")
    assert conn.status == 400
  end

  test "PATCH /issues/:id updates state and returns success", %{tracker_file: file} do
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

  test "POST /issues/search returns 500 when tracker.json is malformed", %{dir: dir} do
    set_corrupted_tracker_file(dir)
    conn = call(:post, "/issues/search", %{"states" => ["Todo"]})
    assert conn.status == 500
    assert %{"success" => false} = Jason.decode!(conn.resp_body)
  end

  test "POST /issues/by_ids returns 500 when tracker.json is malformed", %{dir: dir} do
    set_corrupted_tracker_file(dir)
    conn = call(:post, "/issues/by_ids", %{"ids" => ["a"]})
    assert conn.status == 500
    assert %{"success" => false} = Jason.decode!(conn.resp_body)
  end

  test "PATCH /issues/:id returns 500 when tracker.json is malformed", %{dir: dir} do
    set_corrupted_tracker_file(dir)
    conn = call(:patch, "/issues/a", %{"state" => "Done"})
    assert conn.status == 500
    assert %{"success" => false} = Jason.decode!(conn.resp_body)
  end

  test "POST /issues/:id/comments returns 500 when comment log path is unwritable" do
    bad_name = :"router_bad_log_#{System.unique_integer([:positive])}"
    bad_path = "/dev/symphony-tracker-test-#{System.unique_integer([:positive])}/comments.jsonl"
    {:ok, _pid} = CommentLog.start_link(name: bad_name, path: bad_path)
    Application.put_env(:symphony_elixir, :tracker_server_comment_log, bad_name)

    conn = call(:post, "/issues/a/comments", %{"body" => "stray"})
    assert conn.status == 500
    assert %{"success" => false} = Jason.decode!(conn.resp_body)
  end

  # POST /issues/batch

  test "POST /issues/batch creates issues and returns count" do
    new_issues = [
      %{"id" => "c", "identifier" => "X-3", "title" => "new task", "state" => "Todo"}
    ]

    conn = call(:post, "/issues/batch", %{"issues" => new_issues})
    assert conn.status == 200
    assert %{"success" => true, "created" => 1} = Jason.decode!(conn.resp_body)
  end

  test "POST /issues/batch returns 409 on id conflict with existing", %{tracker_file: file} do
    _ = file

    clash = [%{"id" => "a", "identifier" => "X-99", "title" => "dupe", "state" => "Todo"}]
    conn = call(:post, "/issues/batch", %{"issues" => clash})
    assert conn.status == 409
    assert %{"error" => "conflicting_ids"} = Jason.decode!(conn.resp_body)
  end

  test "POST /issues/batch returns 400 when issues field is missing" do
    conn = call(:post, "/issues/batch", %{})
    assert conn.status == 400
  end

  test "POST /issues/batch returns 400 when issues is not a list of objects" do
    conn = call(:post, "/issues/batch", %{"issues" => ["not-an-object"]})
    assert conn.status == 400
  end

  test "POST /issues/batch returns 400 when an issue is missing a required field" do
    bad = [%{"id" => "x", "identifier" => "X-1", "title" => "no state"}]
    conn = call(:post, "/issues/batch", %{"issues" => bad})
    assert conn.status == 400
  end

  test "POST /issues/batch returns 400 on malformed JSON body" do
    conn =
      conn(:post, "/issues/batch", "not json {{{")
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 400
  end

  test "POST /issues/batch returns 400 on corrupted tracker file", %{dir: dir} do
    set_corrupted_tracker_file(dir)

    new = [%{"id" => "z", "identifier" => "X-9", "title" => "t", "state" => "Todo"}]
    conn = call(:post, "/issues/batch", %{"issues" => new})
    assert conn.status == 400
  end

  test "unknown route returns 404" do
    conn = call(:get, "/no-such-thing", %{})
    assert conn.status == 404
  end

  test "PATCH on an unknown route with token configured and wrong header still returns 401" do
    Application.put_env(:symphony_elixir, :tracker_server_token, "secret")
    conn = call(:patch, "/no-such-thing", %{"state" => "Done"}, [{"authorization", "Bearer wrong"}])
    assert conn.status == 401
  end
end
