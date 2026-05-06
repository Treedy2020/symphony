defmodule SymphonyElixir.TrackerServer.Application do
  @moduledoc false
  use Application

  alias SymphonyElixir.TrackerServer.{CommentLog, Router}

  @impl Application
  def start(_type, _args) do
    bandit_opts = Application.fetch_env!(:symphony_elixir, :tracker_server_bandit_opts)
    comment_log_path = Application.fetch_env!(:symphony_elixir, :tracker_server_comments_path)

    # Pin the registered name *before* the supervisor starts so a request
    # arriving the instant Bandit accepts can find the comment log.
    Application.put_env(:symphony_elixir, :tracker_server_comment_log, CommentLog)

    children = [
      {CommentLog, name: CommentLog, path: comment_log_path},
      {Bandit, [plug: Router] ++ bandit_opts}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
