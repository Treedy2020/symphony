---
name: symphony
description: |
  How to set up, run, and configure Symphony — the orchestrator that polls a tracker for issues, spawns Codex agents in isolated workspaces, and lands their work autonomously. Use this skill whenever the user mentions Symphony, asks to "start/run/launch symphony", "set up symphony", "configure symphony for this project", touches `WORKFLOW.md` or `tracker.json`, runs `symphony` / `symphony-up` / `symphony-tracker`, or hits an error from any of those. Trigger even when the user implies the workflow indirectly ("hook this repo up to my agents", "let codex pick up todos", "where do I add a tracker token").
---

## What Symphony is

Symphony reads `WORKFLOW.md` from the current directory, polls the configured tracker for active issues, creates a per-issue workspace (a clean directory under `workspace.root`), and runs `codex app-server` inside it with the Markdown body of `WORKFLOW.md` as the per-issue prompt. When an issue moves to a terminal state, Symphony stops the agent and cleans up the workspace.

Three globally installed wrappers drive everything (installed by `./scripts/install.sh` from the symphony repo into `~/.local/bin`):

| Command            | Purpose                                                            |
|--------------------|--------------------------------------------------------------------|
| `symphony`         | Orchestrator — reads `WORKFLOW.md`, dispatches Codex per issue     |
| `symphony-tracker` | Local `custom_http` tracker server backed by `tracker.json`        |
| `symphony-up`      | One-shot launcher — starts both from the current project directory |

The user's setup uses these wrappers plus the local `custom_http` tracker by default; Linear is the alternative tracker backend. Existing skill `push-to-symphony` already handles converting plans → tracker issues, so do **not** re-implement that flow here; defer to it.

## Pick the right flow

Before touching anything, decide which task the user is actually asking for:

| User says…                                                              | Go to        |
|-------------------------------------------------------------------------|--------------|
| "set up symphony for this repo", "first-time install"                   | **Flow A**   |
| "start / run / launch symphony", "kick off the agents", "symphony-up"   | **Flow B**   |
| "edit WORKFLOW.md", "change tracker / agent / codex / hooks config"     | **Flow C**   |
| Something errored, port conflict, agent stuck, Codex won't start        | **Flow D**   |
| Convert a plan/spec into tracker issues                                 | Use the `push-to-symphony` skill instead |

Read `references/workflow-md.md` whenever you need exact field semantics for `WORKFLOW.md` — it's the schema source of truth and avoids guessing. Read `references/troubleshooting.md` for known failure modes.

---

## Flow A: First-time setup in a new project

The goal is to leave the target repo with a runnable `WORKFLOW.md` + `tracker.json` and confirm `symphony-up` boots cleanly. Don't run an agent against real work until the user has reviewed the workflow.

### A.1 Verify the wrappers exist

```bash
command -v symphony && command -v symphony-tracker && command -v symphony-up
```

If any are missing, the user hasn't installed yet. Direct them to:

```bash
# from a clone of github.com/Treedy2020/symphony:
cd path/to/symphony && ./scripts/install.sh
```

The installer needs `mise` with Erlang/Elixir toolchain available. If `escript` errors come up on first run, ask the user to `cd elixir && mise install` once, then re-run the installer.

### A.2 Pick the tracker backend

Ask the user (or infer from context) which tracker to use. Default to `custom_http` if they want to start fast and locally. Pick `linear` only when they already have a Linear project and `LINEAR_API_KEY` set.

| Backend       | Needs                                          | When to choose                                       |
|---------------|------------------------------------------------|------------------------------------------------------|
| `custom_http` | `tracker.json` + `symphony-tracker` running    | Local dev, no external SaaS, hand-editable issues    |
| `linear`      | `LINEAR_API_KEY`, a Linear project slug        | Real team workflow already lives in Linear           |

### A.3 Create `tracker.json` (custom_http only)

Minimum starter file at the project root. The server creates an empty one if absent, but seeding makes the user feel something is happening:

```json
{
  "issues": [
    {
      "id": "task-1",
      "identifier": "LOCAL-1",
      "title": "Try the local tracker",
      "state": "Todo"
    }
  ]
}
```

Each issue MUST have non-empty string `id`, `identifier`, `title`, `state`; `id` must be unique. To populate from a plan, hand off to the `push-to-symphony` skill.

### A.4 Create `WORKFLOW.md`

Write it to the project root. Start from this minimal template, then ask the user what they want to customize. Keep the prompt body small until something is working end-to-end.

```md
---
tracker:
  kind: custom_http
  endpoint: "http://127.0.0.1:8787"
  api_key: $SYMPHONY_TRACKER_API_KEY
  active_states: ["Todo", "In Progress"]
  terminal_states: ["Done", "Closed", "Cancelled"]
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:OWNER/REPO.git .
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: codex app-server
---

You are working on issue {{ issue.identifier }}.

Title: {{ issue.title }}
State: {{ issue.state }}

{% if issue.description %}
Description:
{{ issue.description }}
{% endif %}

Implement the change end-to-end. Open a PR when done.
```

For the Linear variant, swap `tracker` to:

```yaml
tracker:
  kind: linear
  project_slug: "your-project-slug"
  api_key: $LINEAR_API_KEY
```

Confirm with the user before you guess `OWNER/REPO`, the `workspace.root`, or any custom hook commands. The Markdown body fails rendering if you reference any `issue.*` field that isn't part of the normalized issue payload — keep it to documented fields (see `references/workflow-md.md`).

### A.5 Set the tracker token (custom_http only)

`symphony-up` passes `$SYMPHONY_TRACKER_API_KEY` to the tracker as a Bearer token if it's set. For local-only use, an empty token disables auth — fine for `127.0.0.1`. For anything binding to `0.0.0.0`, require a real token.

```bash
export SYMPHONY_TRACKER_API_KEY="$(openssl rand -hex 16)"
```

Persist by adding the export to `~/.zshrc` if the user wants it across sessions.

### A.6 Smoke test

```bash
symphony-up --port 4000
```

Expected output:
- "→ tracker started (pid …) on port 8787"
- "→ starting symphony (./WORKFLOW.md) with web UI at http://127.0.0.1:4000"
- the issue from `tracker.json` flips to `In Progress` shortly after

If the user wants to stop, `Ctrl+C` cleans up both processes. If the agent doesn't pick up the issue within ~10s, jump to Flow D.

---

## Flow B: Day-to-day running

### B.1 Common case — `symphony-up`

From the project directory containing `WORKFLOW.md` and `tracker.json`:

```bash
symphony-up                  # tracker on 8787, no web UI
symphony-up --port 4000      # also enables web UI at http://127.0.0.1:4000
symphony-up --tracker-port 9000 --file ./other-tracker.json
```

`symphony-up` skips starting a new tracker if one is already bound to the requested port. `Ctrl+C` stops both processes cleanly.

### B.2 When you need them separate

Run the tracker and orchestrator in different terminals when you want to attach a debugger, restart one without the other, or run the tracker as a long-lived service:

```bash
# terminal 1 — tracker (long-lived)
symphony-tracker --file ./tracker.json --port 8787

# terminal 2 — orchestrator
symphony --port 4000 ./WORKFLOW.md
```

The orchestrator looks at `./WORKFLOW.md` by default if you omit the path.

### B.3 Inspecting state

| What                           | How                                                              |
|--------------------------------|------------------------------------------------------------------|
| Active issues + their states   | Read `tracker.json` directly, or hit `POST /issues/search`       |
| Agent comments per issue       | `tracker.comments.jsonl` (append-only, one JSON per line)        |
| Per-issue logs                 | `./log/` (override with `--logs-root` on `symphony`)             |
| Live workspace contents        | The `workspace.root` you configured (one subdirectory per issue) |
| Web dashboard                  | `http://127.0.0.1:<port>/` when started with `--port`            |

To query a running tracker:

```bash
curl -s http://127.0.0.1:8787/issues/search \
  -H "Authorization: Bearer $SYMPHONY_TRACKER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"states":["Todo","In Progress"]}' | python3 -m json.tool
```

### B.4 Adding/changing issues

For ad-hoc tweaks, edit `tracker.json` by hand. **Avoid editing the `state` field of an issue Symphony is currently working on** — concurrent PATCHes from the agent will clobber your change. Pick issues that are `Todo` or already terminal.

For bulk creation from a planning doc, invoke the `push-to-symphony` skill — it understands the description template, ID assignment, and `POST /issues/batch`. Don't reimplement that here.

### B.5 Stopping cleanly

`Ctrl+C` on `symphony-up` propagates SIGTERM to both children. If you only have stray PIDs:

```bash
lsof -ti :8787 | xargs -r kill        # tracker
pgrep -f "\.symphony-escript" | xargs -r kill   # orchestrator
```

When an issue reaches a terminal state, Symphony deletes its workspace via the `before_remove` hook (if any). If the workspace persists after termination, the hook errored — check logs.

---

## Flow C: Editing `WORKFLOW.md`

Symphony hot-reloads the workflow file. Saved valid edits apply to the next polling tick **without** restarting; saved invalid edits are rejected and Symphony keeps running on the last good config (the failure is logged). At startup, an invalid `WORKFLOW.md` prevents boot.

### C.1 Map the user's intent to the right key

| User wants                              | Edit                                              |
|-----------------------------------------|---------------------------------------------------|
| Switch from local to Linear (or back)   | `tracker.kind` + related fields                   |
| Throttle/expand parallelism             | `agent.max_concurrent_agents`, `_by_state`        |
| Change agent reasoning model / sandbox  | `codex.command`, `codex.thread_sandbox`           |
| Change polling cadence                  | `polling.interval_ms`                             |
| Move where workspaces live              | `workspace.root`                                  |
| Bootstrap workspace (clone repo, etc.)  | `hooks.after_create`                              |
| Custom per-attempt setup                | `hooks.before_run`                                |
| Tear-down cleanup                       | `hooks.before_remove`                             |
| Rephrase the per-issue prompt           | The Markdown body (Liquid template)               |

For the full field schema, read `references/workflow-md.md` before writing. Don't invent fields — Symphony ignores unknown top-level keys silently, so typos go undetected.

### C.2 Prompt body rules

- Liquid-compatible templating. `{{ issue.identifier }}`, `{{ issue.title }}`, `{{ issue.state }}`, `{{ issue.description }}`, `{{ issue.url }}`, `{{ issue.labels }}` are reliably populated.
- `attempt` is `null` on first run, an integer on retry/continuation. Use `{% if attempt %}…{% endif %}` to add resume context.
- Unknown variables and unknown filters fail rendering. If you reference a custom tracker field, confirm the tracker emits it.
- An empty body falls back to a minimal default; don't depend on it for production runs.

### C.3 Validation loop

After editing:

1. Save the file.
2. Watch the orchestrator log for either "config reloaded" (good) or a parse/validation error (bad — keep last good config).
3. For confidence, `Ctrl+C` and re-run `symphony-up`; a fresh start surfaces validation failures hard.

If you must run a validator without restarting Symphony, parse the YAML frontmatter with `python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]).read().split("---")[1])' WORKFLOW.md` as a sanity check.

---

## Flow D: Things go wrong

Read `references/troubleshooting.md` for the full table. Quick triage:

| Symptom                                    | First check                                                |
|--------------------------------------------|------------------------------------------------------------|
| "escript not found" on `symphony` start    | `mise install` inside `elixir/`, then re-run `install.sh`  |
| Tracker port 8787 already in use           | `lsof -ti :8787` — `symphony-up` will reuse a live tracker |
| Issue stays `Todo`, no agent picks it up   | Check `active_states` and `tracker.kind`/`endpoint` match  |
| Agent crashes immediately                  | `codex` not on PATH, or `codex.command` malformed          |
| WORKFLOW.md changes "didn't take"          | Validation error — check log; fix YAML; reload             |
| Workspace lingering after issue done       | `hooks.before_remove` failed — inspect log                 |

---

## Boundaries — what this skill does not do

- **Authoring plans / specs**: use `superpowers:writing-plans` or `superpowers:brainstorming` first.
- **Pushing issues into the tracker from a plan**: that's `push-to-symphony`. Hand off to it cleanly.
- **Editing the agent's per-issue behavior at runtime** (e.g. PR review, commit hygiene, landing): those live in repo-level skills like `commit`, `push`, `land`, and the agent's own AGENTS/CLAUDE files — not in `WORKFLOW.md`.

If the user's request spans these boundaries, name the right skill and invoke it rather than improvising.
