# Wrapper scripts for global `symphony` / `symphony-tracker` / `symphony-up`

These scripts let you call the Symphony binaries from any directory on your machine,
without depending on `mise activate` being set up in your shell.

## Quick start (new machine)

```sh
git clone https://github.com/Treedy2020/symphony && cd symphony
./scripts/install.sh
```

The installer:

1. Builds both escripts (`bin/symphony`, `bin/symphony-tracker`) via `mix build`.
2. Copies the escripts to `~/.local/bin/.{symphony,symphony-tracker}-escript`.
3. Installs three PATH-callable wrappers into `~/.local/bin/`:

   | Wrapper            | Purpose                                                     |
   |--------------------|-------------------------------------------------------------|
   | `symphony`         | Run the orchestrator (reads `WORKFLOW.md`)                  |
   | `symphony-tracker` | Run the local custom_http tracker server                    |
   | `symphony-up`      | One-command launcher: starts both from current project dir  |

## Typical usage

From any project directory containing a `WORKFLOW.md` and `tracker.json`:

```sh
symphony-up --port 4000
```

This starts the tracker on `127.0.0.1:8787`, then starts symphony with the web UI
at `http://127.0.0.1:4000`. Ctrl+C cleanly stops both.

## How the wrappers work

The escript binaries have a `#!/usr/bin/env escript` shebang, so they need an
`escript` executable on the PATH at runtime. mise installs `escript` under
`~/.local/share/mise/installs/erlang/<version>/bin/`, but that path is normally
only added to PATH inside `mise exec` or after `mise activate`.

Each wrapper resolves the latest mise-installed `escript` directly and executes
the corresponding hidden escript file. This means the wrappers work from any
shell, including non-interactive ones.

## Updating after pulling new commits

```sh
cd /path/to/symphony && ./scripts/install.sh
```

The install script rebuilds the escripts and replaces the binaries — wrapper
scripts themselves only need re-copying if their content changed.
