defmodule SymphonyElixir.Tracker.CustomHttp do
  @moduledoc """
  HTTP JSON tracker adapter for local or internal issue trackers.
  """

  require Logger

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, Linear.Issue}

  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_issues_by_states(Config.settings!().tracker.active_states)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if states == [] do
      {:ok, []}
    else
      case post_json("/issues/search", %{"states" => states}) do
        {:ok, body} -> decode_issues_response(body)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.map(issue_ids, &to_string/1) |> Enum.uniq()

    if ids == [] do
      {:ok, []}
    else
      case post_json("/issues/by_ids", %{"ids" => ids}) do
        {:ok, body} -> decode_issues_response(body)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case post_json("/issues/#{URI.encode_www_form(issue_id)}/comments", %{"body" => body}) do
      {:ok, response_body} -> decode_success_response(response_body, :comment_create_failed)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    case patch_json("/issues/#{URI.encode_www_form(issue_id)}", %{"state" => state_name}) do
      {:ok, response_body} -> decode_success_response(response_body, :issue_update_failed)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec decode_issues_response_for_test(term()) :: {:ok, [Issue.t()]} | {:error, term()}
  def decode_issues_response_for_test(body), do: decode_issues_response(body)

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue), do: normalize_issue(issue)

  defp post_json(path, payload), do: request(:post, path, payload)
  defp patch_json(path, payload), do: request(:patch, path, payload)

  defp request(method, path, payload) when method in [:post, :patch] do
    request_fun =
      Application.get_env(:symphony_elixir, :custom_http_tracker_request_fun, &Req.request/1)

    request_opts = [
      method: method,
      url: endpoint_url(path),
      headers: headers(),
      json: payload,
      connect_options: [timeout: 30_000]
    ]

    case request_fun.(request_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Custom HTTP tracker request failed status=#{status} body=#{summarize_error_body(body)}")

        {:error, {:custom_http_status, status}}

      {:error, reason} ->
        Logger.error("Custom HTTP tracker request failed: #{inspect(reason)}")
        {:error, {:custom_http_request, reason}}
    end
  end

  defp endpoint_url(path) do
    Config.settings!().tracker.endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp headers do
    base_headers = [{"content-type", "application/json"}]

    case Config.settings!().tracker.api_key do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer #{token}"} | base_headers]

      _ ->
        base_headers
    end
  end

  defp decode_issues_response(%{"issues" => issues}) when is_list(issues), do: normalize_issues(issues)
  defp decode_issues_response(issues) when is_list(issues), do: normalize_issues(issues)
  defp decode_issues_response(_body), do: {:error, :custom_http_unknown_payload}

  defp normalize_issues(issues) when is_list(issues) do
    {:ok,
     issues
     |> Enum.map(&normalize_issue/1)
     |> Enum.reject(&is_nil/1)}
  end

  defp normalize_issue(issue) when is_map(issue) do
    %Issue{
      id: string_field(issue, "id"),
      identifier: string_field(issue, "identifier"),
      title: string_field(issue, "title"),
      description: string_field(issue, "description"),
      priority: parse_priority(field(issue, "priority")),
      state: string_field(issue, "state"),
      branch_name: first_present([string_field(issue, "branch_name"), string_field(issue, "branchName")]),
      url: string_field(issue, "url"),
      assignee_id: first_present([string_field(issue, "assignee_id"), string_field(issue, "assigneeId")]),
      blocked_by: blocked_by(issue),
      labels: labels(issue),
      assigned_to_worker: assigned_to_worker(issue),
      created_at: parse_datetime(first_present([field(issue, "created_at"), field(issue, "createdAt")])),
      updated_at: parse_datetime(first_present([field(issue, "updated_at"), field(issue, "updatedAt")]))
    }
  end

  defp normalize_issue(_issue), do: nil

  defp field(map, name) when is_map(map) and is_binary(name) do
    if Map.has_key?(map, name) do
      Map.get(map, name)
    else
      existing_atom_field(map, name)
    end
  end

  defp existing_atom_field(map, name) do
    Map.get(map, String.to_existing_atom(name))
  rescue
    ArgumentError -> nil
  end

  defp string_field(map, name) do
    case field(map, name) do
      value when is_binary(value) -> value
      value when is_integer(value) -> to_string(value)
      _ -> nil
    end
  end

  defp labels(issue) do
    case field(issue, "labels") do
      labels when is_list(labels) ->
        labels |> Enum.filter(&is_binary/1) |> Enum.map(&String.downcase/1)

      _ ->
        []
    end
  end

  defp blocked_by(issue) do
    case first_present([field(issue, "blocked_by"), field(issue, "blockedBy")]) do
      blockers when is_list(blockers) -> Enum.filter(blockers, &is_map/1)
      _ -> []
    end
  end

  defp assigned_to_worker(issue) do
    case first_present([field(issue, "assigned_to_worker"), field(issue, "assignedToWorker")]) do
      value when is_boolean(value) -> value
      _ -> true
    end
  end

  defp first_present(values) when is_list(values) do
    Enum.find(values, &(!is_nil(&1)))
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil

  defp decode_success_response(%{"success" => false}, fallback), do: {:error, fallback}
  defp decode_success_response(%{"success" => true}, _fallback), do: :ok
  defp decode_success_response(%{}, _fallback), do: :ok
  defp decode_success_response(nil, _fallback), do: :ok
  defp decode_success_response(_body, fallback), do: {:error, fallback}

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
