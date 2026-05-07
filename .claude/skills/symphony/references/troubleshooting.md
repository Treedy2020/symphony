# Symphony troubleshooting

Symptoms grouped by where they tend to come from. For each entry: what you'll see, what's actually wrong, how to fix it.

## Install / wrappers

### `Error: escript not found. Run: mise install erlang`

The wrapper looks under `~/.local/share/mise/installs/erlang/*/bin/escript`. mise hasn't populated the toolchain yet.

```bash
cd path/to/symphony/elixir && mise install
cd path/to/symphony && ./scripts/install.sh
```

### `command not found: symphony`

`~/.local/bin` isn't on `PATH`. The installer prints the exact line; the typical fix:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

### Wrappers exist but break after a `git pull` of symphony

The escripts are stale. Re-run the installer to rebuild them:

```bash
cd path/to/symphony && ./scripts/install.sh
```

The wrapper scripts themselves only need replacement if `scripts/symphony*` changed.

---

## Boot / configuration

### Symphony refuses to start with a YAML error

Invalid front matter at startup is fatal. Validate by hand:

```bash
python3 -c '
import sys, yaml
parts = open("WORKFLOW.md").read().split("---", 2)
print(yaml.safe_load(parts[1]))
'
```

Fix the YAML and re-run. After boot, the same edit at runtime would be rejected non-fatally and Symphony would keep using the previous good config.

### "WORKFLOW.md not found in current directory"

`symphony-up` requires the file in the cwd, or pass it explicitly:

```bash
symphony-up /abs/path/to/WORKFLOW.md
```

### Hot-reload "didn't take"

The reload either errored (check the log — Symphony keeps the last good config) or your edit was to a field that only takes effect on future events (most do). Some fields (like `polling.interval_ms`) only affect the *next* tick. To force-apply, restart with `Ctrl+C` then `symphony-up`.

---

## Tracker (custom_http)

### Port 8787 already in use

`symphony-up` will detect this and reuse the existing tracker. If you want a clean restart:

```bash
lsof -ti :8787 | xargs -r kill
symphony-up
```

### `401 Unauthorized` from the tracker

`SYMPHONY_TRACKER_API_KEY` is set somewhere (Symphony or the tracker) but not the other side. Either set it in both shells, or unset it everywhere for local-only use:

```bash
unset SYMPHONY_TRACKER_API_KEY
```

When `--bind 0.0.0.0`, an unset token is dangerous — only do this for `127.0.0.1`.

### Tracker bound, but Symphony doesn't see issues

Cross-check three things:

1. `WORKFLOW.md` `tracker.endpoint` matches the tracker's `--port` (default `http://127.0.0.1:8787`).
2. The issues' `state` values are listed in `active_states`.
3. `id`, `identifier`, `title`, `state` are all non-empty strings on each issue, and `id` is unique. The tracker rejects writes that violate this.

Test from a shell:

```bash
curl -s http://127.0.0.1:8787/issues/search \
  -H "Authorization: Bearer $SYMPHONY_TRACKER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"states":["Todo","In Progress"]}' | python3 -m json.tool
```

### My hand-edit got clobbered

You edited the `state` field of an issue Symphony was actively working on; its agent PATCHed back. Edit only `Todo` or terminal issues. For everything else, change state via the agent's flow or stop Symphony first.

---

## Tracker (Linear)

### "missing project_slug" or "missing api_key"

`tracker.kind: linear` requires both `project_slug` and a resolvable `api_key`. The slug comes from the Linear project URL (right-click project → Copy URL → the slug is the trailing path segment). The token comes from Linear → Settings → Security & access → Personal API keys.

```bash
export LINEAR_API_KEY=lin_api_...
```

### Custom states "Rework" / "Human Review" don't exist

The reference Elixir workflow uses non-standard Linear states. Either add them in Team Settings → Workflow, or edit `WORKFLOW.md` to use only the states your team has.

---

## Agent / Codex

### Agent crashes immediately

Almost always `codex` is missing or `codex.command` is malformed.

```bash
which codex
codex app-server --help
```

Run the exact `codex.command` you configured in a shell to confirm it boots and speaks app-server protocol on stdio. If you set `--config` flags, escape quoting carefully.

### Sandbox/permission errors mid-turn

`codex.thread_sandbox` or `codex.turn_sandbox_policy` is too restrictive for what the agent is trying to do. Either widen the sandbox or change the agent's behavior. Common defaults:

```yaml
codex:
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
```

For tightly controlled environments, use `read-only` for thread sandbox and rely on explicit approvals.

### Agent gets stuck retrying

Symphony retries with exponential backoff up to `agent.max_retry_backoff_ms` (default 5 min). If retries keep failing, the underlying tool/auth issue is real — read the log, fix the cause, then move the issue to a terminal state to break the loop, or stop Symphony.

---

## Workspaces

### Workspace not deleted after issue moved to Done

`hooks.before_remove` errored. Failure is logged and ignored, but cleanup may still have proceeded — check the log. If the workspace really persists, delete by hand:

```bash
rm -rf ~/code/workspaces/<issue-id>
```

Then fix the hook so it doesn't recur.

### `after_create` clone fails

The issue dir is now a half-baked workspace and the attempt aborts. Symphony will retry. Inspect the issue log for the clone error (auth, network, repo URL). Common: SSH agent not forwarded, or a typo in the URL inside `WORKFLOW.md`.

### Multiple workspaces racing on the same issue

This shouldn't happen — Symphony serializes per-issue. If you see it, you probably have two `symphony` processes running against the same `WORKFLOW.md`. Kill one:

```bash
pgrep -fa "\.symphony-escript"
```

---

## Logs and observability

### "Where do my logs live?"

Default: `./log` relative to the cwd where Symphony was started. Override with `--logs-root`. One file per issue/session. The web dashboard (`--port`) gives a faster live view at `http://127.0.0.1:<port>/` and JSON state at `/api/v1/state`.

### Comments not showing in the tracker

For `custom_http`: comments are stored in `tracker.comments.jsonl` (append-only), not `tracker.json`. Tail it:

```bash
tail -f tracker.comments.jsonl
```

For `linear`: confirm the agent has comment-write permission on the project; the API returns silently on auth issues sometimes.
