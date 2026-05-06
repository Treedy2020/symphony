defmodule SymphonyElixir.TrackerServerCliTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TrackerServer.CLI

  setup do
    previous = System.get_env("SYMPHONY_TRACKER_API_KEY")
    System.delete_env("SYMPHONY_TRACKER_API_KEY")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("SYMPHONY_TRACKER_API_KEY")
        value -> System.put_env("SYMPHONY_TRACKER_API_KEY", value)
      end
    end)

    :ok
  end

  test "parse returns defaults when no args" do
    assert {:ok, config} = CLI.parse([])
    assert config.file == Path.expand("./tracker.json")
    assert config.comments_path == Path.expand("./tracker.comments.jsonl")
    assert config.port == 8787
    assert config.bind == "127.0.0.1"
    assert is_nil(config.token)
  end

  test "parse honors flags" do
    assert {:ok, config} =
             CLI.parse([
               "--file",
               "/tmp/x.json",
               "--port",
               "9999",
               "--bind",
               "0.0.0.0",
               "--token",
               "secret"
             ])

    assert config.file == "/tmp/x.json"
    assert config.comments_path == "/tmp/x.comments.jsonl"
    assert config.port == 9999
    assert config.bind == "0.0.0.0"
    assert config.token == "secret"
  end

  test "parse derives sidecar from non-.json filename" do
    assert {:ok, config} = CLI.parse(["--file", "/tmp/store.db"])
    assert config.comments_path == "/tmp/store.db.comments.jsonl"
  end

  test "parse expands ~ in --file" do
    assert {:ok, config} = CLI.parse(["--file", "~/tracker.json"])
    refute String.starts_with?(config.file, "~")
    assert String.ends_with?(config.file, "/tracker.json")
  end

  test "parse falls back to SYMPHONY_TRACKER_API_KEY when --token absent" do
    System.put_env("SYMPHONY_TRACKER_API_KEY", "envtoken")
    assert {:ok, config} = CLI.parse([])
    assert config.token == "envtoken"
  end

  test "parse prefers --token over env var" do
    System.put_env("SYMPHONY_TRACKER_API_KEY", "envtoken")
    assert {:ok, config} = CLI.parse(["--token", "flagtoken"])
    assert config.token == "flagtoken"
  end

  test "parse rejects unknown flag" do
    assert {:error, message} = CLI.parse(["--bogus"])
    assert message =~ "Usage:"
  end

  test "parse rejects --port that is not an integer" do
    assert {:error, _message} = CLI.parse(["--port", "abc"])
  end

  test "parse handles --help" do
    assert {:help, message} = CLI.parse(["--help"])
    assert message =~ "Usage:"
  end
end
