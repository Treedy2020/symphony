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
