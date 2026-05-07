# `WORKFLOW.md` schema reference

`WORKFLOW.md` is a Markdown file with a YAML front-matter block that configures the Symphony runtime, plus a Markdown body that is rendered as the per-issue Codex prompt. Symphony hot-reloads it: saved valid edits apply to subsequent polling ticks without a restart, while invalid edits are rejected (Symphony keeps running on the last good config and logs the error). At startup, an invalid `WORKFLOW.md` prevents boot.

## File shape

```md
---
# YAML front matter — runtime config
tracker: { ... }
polling: { ... }
workspace: { ... }
hooks: { ... }
agent: { ... }
codex: { ... }
---

Markdown body — the per-issue prompt template (Liquid).
```

Unknown top-level keys are **silently ignored** for forward compatibility, so typos do not error. Double-check spelling.

`~` expands in path values. `$VAR` substitution is supported in `tracker.api_key` and (per-runtime) in path-typed values like `workspace.root` — `codex.command` is a shell command string and any `$VAR` there expands inside the launched shell, not at config load.

---

## `tracker` (object)

| Field             | Type     | Required                                        | Notes                                                                                                                            |
|-------------------|----------|-------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| `kind`            | string   | yes                                             | `linear` or `custom_http`.                                                                                                       |
| `endpoint`        | string   | required when `kind == custom_http`             | For `linear`, defaults to `https://api.linear.app/graphql`.                                                                      |
| `api_key`         | string   | yes for `linear`, optional for `custom_http`    | Literal token or `$VAR_NAME`. Empty resolved value = treated as missing. Defaults: `LINEAR_API_KEY` for linear, `SYMPHONY_TRACKER_API_KEY` for custom_http. |
| `project_slug`    | string   | required when `kind == linear`                  | The Linear project's URL slug.                                                                                                   |
| `active_states`   | string[] | no — defaults to `["Todo", "In Progress"]`      | Issues in these states are eligible for dispatch.                                                                                |
| `terminal_states` | string[] | no — defaults to `["Closed","Cancelled","Canceled","Duplicate","Done"]` | Moving an active issue into one of these stops its agent and removes its workspace.                |

### `custom_http` HTTP contract

The local `symphony-tracker` server implements this; any drop-in replacement must too:

- `POST /issues/search` body `{"states":["Todo"]}` → `{"issues":[…]}` or bare array
- `POST /issues/by_ids` body `{"ids":["…"]}` → same shape
- `POST /issues/:id/comments` body `{"body":"…"}` → 2xx
- `PATCH /issues/:id` body `{"state":"…"}` → 2xx

Issue object fields: required `id`, `identifier`, `title`, `state`. Optional `description`, `priority`, `branch_name` / `branchName`, `url`, `assignee_id` / `assigneeId`, `labels`, `blocked_by` / `blockedBy`, `assigned_to_worker` / `assignedToWorker`, `created_at` / `createdAt`, `updated_at` / `updatedAt`. Snake- and camel-case forms are interchangeable.

---

## `polling` (object)

| Field         | Type    | Default | Notes                                                                                |
|---------------|---------|---------|--------------------------------------------------------------------------------------|
| `interval_ms` | integer | `30000` | How often Symphony polls the tracker. Reapplies on hot-reload for future ticks only. |

For local `custom_http` development a faster cadence (e.g. `5000`) is fine; for Linear, respect API rate limits.

---

## `workspace` (object)

| Field  | Type            | Default                            | Notes                                                                              |
|--------|-----------------|------------------------------------|------------------------------------------------------------------------------------|
| `root` | path or `$VAR`  | `<system-temp>/symphony_workspaces`| `~` expands. Relative paths resolve against the directory holding `WORKFLOW.md`. Normalized to absolute before use. |

Each issue gets its own subdirectory under `root`. Symphony deletes the directory when the issue moves to a terminal state.

**Safety invariant**: never set `workspace.root` to your source repo or any path that contains uncommitted work. Symphony assumes its workspace dirs are disposable.

---

## `hooks` (object)

All hook scripts run via shell, in the issue's workspace directory. Stdout/stderr land in the per-issue log file.

| Field           | Type                       | When it runs                                                              | Failure behavior                       |
|-----------------|----------------------------|---------------------------------------------------------------------------|----------------------------------------|
| `after_create`  | shell script (multiline)   | Once, immediately after a fresh workspace dir is created.                 | **Aborts workspace creation.**         |
| `before_run`    | shell script (multiline)   | Before every agent attempt, after the workspace is prepared.              | **Aborts the current attempt.**        |
| `after_run`     | shell script (multiline)   | After every agent attempt (success/failure/timeout/cancellation).         | Logged and ignored.                    |
| `before_remove` | shell script (multiline)   | Just before workspace deletion.                                           | Logged and ignored — cleanup proceeds. |
| `timeout_ms`    | integer                    | Default `60000`. Applies to all hooks. Invalid value fails validation.    | —                                      |

Common patterns:

- `after_create` clones the source repo: `git clone --depth 1 git@github.com:owner/repo.git .`
- `after_create` runs language toolchain bootstrap: `mise trust && mise install`
- `before_remove` runs cleanup that needs the workspace intact (e.g. `git push` of a stash branch)

Idempotency matters: `after_create` runs only when the dir is newly created, but `before_run` runs every attempt. Don't re-clone in `before_run` — reuse what's there.

---

## `agent` (object)

| Field                            | Type                | Default      | Notes                                                                                       |
|----------------------------------|---------------------|--------------|---------------------------------------------------------------------------------------------|
| `max_concurrent_agents`          | positive integer    | `10`         | Global cap on simultaneous Codex sessions. Reapplies on hot-reload for future dispatches.   |
| `max_turns`                      | positive integer    | `20`         | Per-agent-session cap on consecutive turns when a turn ends but the issue is still active.  |
| `max_retry_backoff_ms`           | integer             | `300000`     | Upper bound for exponential retry backoff (5 min default).                                  |
| `max_concurrent_agents_by_state` | map(state → int>0)  | `{}`         | Per-state cap. Keys are normalized to lowercase. Invalid entries are silently dropped.      |

Use `max_concurrent_agents_by_state` to throttle a noisy state without affecting the rest, e.g. `rework: 1`.

---

## `codex` (object)

These pass through to the Codex app-server. Treat policy fields as opaque pass-throughs — supported values come from your installed Codex version (`codex app-server generate-json-schema --out <dir>`).

| Field                | Type                       | Default                              | Notes                                                                                                  |
|----------------------|----------------------------|--------------------------------------|--------------------------------------------------------------------------------------------------------|
| `command`            | shell command string       | `codex app-server`                   | Run via `bash -lc` in the workspace. Must speak the app-server protocol on stdio.                      |
| `approval_policy`    | Codex `AskForApproval`     | implementation-defined safe default  | E.g. `untrusted`, `on-failure`, `on-request`, `never`, or object form `{"reject": {...}}`.             |
| `thread_sandbox`     | Codex `SandboxMode`        | `workspace-write`                    | Common values: `read-only`, `workspace-write`, `danger-full-access`.                                   |
| `turn_sandbox_policy`| Codex `SandboxPolicy`      | workspace-write rooted at workspace  | When set, passed through unchanged. Compatibility depends on Codex version.                            |
| `turn_timeout_ms`    | integer                    | `3600000` (1h)                       | Wall-clock cap per turn.                                                                               |
| `read_timeout_ms`    | integer                    | `5000`                               | Idle-read timeout when waiting for app-server output.                                                  |
| `stall_timeout_ms`   | integer                    | `300000` (5m)                        | `<= 0` disables stall detection.                                                                       |

Example with explicit reasoning effort:

```yaml
codex:
  command: codex --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
```

---

## Prompt template (Markdown body)

Rendered with Liquid-compatible semantics. Inputs:

- `issue` — the normalized issue object (whatever the tracker returned, after canonicalization). Reliable fields: `identifier`, `title`, `state`, `description`, `url`, `labels`. Custom-tracker fields are present iff the tracker emits them.
- `attempt` — `null` on first run, integer on retry/continuation.

Hard rules:

- Unknown variables fail rendering.
- Unknown filters fail rendering.
- An empty body falls back to a minimal default prompt — fine for smoke tests, not for real runs.

Pattern for retry-aware prompts:

```liquid
{% if attempt %}
This is retry attempt #{{ attempt }}. Resume from current workspace state; do not redo finished steps.
{% endif %}
```

The body is the contract between Symphony and the agent. Keep it explicit about: what counts as "done", which tools/skills to consult, and when to stop. The reference workflow at `elixir/WORKFLOW.md` in this repo is a good (long) example for a Linear-driven workflow with PR review, landing, and rework flows.
