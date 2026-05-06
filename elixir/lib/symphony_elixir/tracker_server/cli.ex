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
