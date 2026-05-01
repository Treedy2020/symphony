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

    {:ok, %{tracker_file: file, comments_file: comments}}
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
end
