defmodule SymphonyElixir.TrackerServer.Router do
  @moduledoc """
  Plug.Router implementing the four `custom_http` tracker endpoints
  (SPEC §11.3).
  """
  use Plug.Router

  alias SymphonyElixir.TrackerServer.{CommentLog, IssueStore}

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

  post "/issues/by_ids" do
    case read_json_body(conn) do
      {:ok, body, conn} -> handle_by_ids(conn, body)
      {:error, conn} -> bad_request(conn)
    end
  end

  post "/issues/:id/comments" do
    case read_json_body(conn) do
      {:ok, body, conn} -> handle_comment(conn, id, body)
      {:error, conn} -> bad_request(conn)
    end
  end

  patch "/issues/:id" do
    case read_json_body(conn) do
      {:ok, body, conn} -> handle_patch(conn, id, body)
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
