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
        with {:ok, decoded} <- decode_json(raw),
             {:ok, issues} <- validate_top_level(decoded),
             :ok <- validate_each(issues),
             :ok <- validate_unique_ids(issues) do
          {:ok, issues}
        end
    end
  end

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

  @spec update_state(Path.t(), String.t(), String.t()) ::
          :ok | {:error, :unknown_issue_id | term()}
  def update_state(path, id, new_state)
      when is_binary(path) and is_binary(id) and is_binary(new_state) do
    with {:ok, issues} <- load(path),
         {:ok, updated} <- replace_state(issues, id, new_state) do
      write_atomic(path, %{"issues" => updated})
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

  defp validate_unique_ids(issues) do
    ids = Enum.map(issues, &Map.get(&1, "id"))
    duplicates = ids -- Enum.uniq(ids)

    if duplicates == [] do
      :ok
    else
      {:error, {:duplicate_ids, Enum.uniq(duplicates)}}
    end
  end

  defp decode_json(raw) do
    case Jason.decode(raw) do
      {:ok, value} -> {:ok, value}
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
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

  defp write_atomic(path, data) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    result =
      with {:ok, encoded} <- Jason.encode(data, pretty: true),
           :ok <- File.write(tmp, encoded <> "\n"),
           :ok <- File.rename(tmp, path) do
        :ok
      end

    if result != :ok, do: _ = File.rm(tmp)
    result
  end
end
