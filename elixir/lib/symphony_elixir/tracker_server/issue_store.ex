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
