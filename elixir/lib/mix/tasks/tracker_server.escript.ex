defmodule Mix.Tasks.TrackerServer.Escript do
  @shortdoc "Builds bin/symphony-tracker by re-running escript.build with MIX_ESCRIPT_TARGET=tracker"
  @moduledoc @shortdoc

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    System.put_env("MIX_ESCRIPT_TARGET", "tracker")

    Mix.ProjectStack.merge_config(
      escript: [
        app: nil,
        main_module: SymphonyElixir.TrackerServer.CLI,
        name: "symphony-tracker",
        path: "bin/symphony-tracker"
      ]
    )

    Mix.Task.reenable("escript.build")

    try do
      Mix.Task.run("escript.build", args)
    after
      System.delete_env("MIX_ESCRIPT_TARGET")
    end
  end
end
