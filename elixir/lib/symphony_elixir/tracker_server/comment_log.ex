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
