# Local `custom_http` Tracker Server — Design

Status: Draft (brainstorm output, pre-implementation)
Date: 2026-05-01
Author: brainstorming session with @treedy
Scope: `elixir/` Mix project

## 1. Background

Symphony already ships:

- A SPEC contract for a `custom_http` tracker (SPEC §11.3) — four JSON endpoints
  (`POST /issues/search`, `POST /issues/by_ids`, `POST /issues/:id/comments`,
  `PATCH /issues/:id`).
- A client adapter `SymphonyElixir.Tracker.CustomHttp`
  (`elixir/lib/symphony_elixir/tracker/custom_http.ex`) that calls those four
  endpoints from inside the orchestrator, plus tests covering it via a stubbed
  `:custom_http_tracker_request_fun`.
- An in-process `SymphonyElixir.Tracker.Memory` adapter for offline runs / unit
  tests.

What is missing is a **server** that satisfies the `custom_http` contract.

This document specifies that server: a small, self-contained, end-user-facing
local tracker so a Symphony user can run a real `custom_http` setup without
needing Linear or any other external service.

## 2. Goals & Non-Goals

### Goals

- Provide a long-running local HTTP service that fully implements the four
  `custom_http` endpoints from SPEC §11.3.
- Persist issues in a hand-editable JSON file that users own as the source of
  truth.
- Persist agent-written comments in an append-only sidecar log.
- Ship as a separate escript (`bin/symphony-tracker`) alongside `bin/symphony`
  in the existing `elixir/` Mix project.
- Be testable end-to-end against the existing `CustomHttp` client adapter.

### Non-Goals

- No GET endpoint for comments. Inspection is `tail -f tracker.comments.jsonl`.
- No HTTP endpoints for creating, deleting, or listing issues. The user edits
  `tracker.json` by hand.
- No web UI.
- No multi-project / multi-tenant isolation.
- No `tracker.json` schema version field. Migration is YAGNI; revisit when a
  breaking change is actually needed.
- No file watcher (`:file_system` dep). The server re-parses the file on every
  read request.
- No Docker / systemd packaging. This is a single-user local tool.
- No changes to SPEC.md. SPEC §11.3 already defines the wire contract; this
  document is the elixir-implementation-level specification of the server.

## 3. Architecture

```
User                                       Symphony orchestrator
  |                                                |
  |  edits tracker.json / tails comments.jsonl     |  HTTP (4 contract endpoints)
  v                                                v
+--------------------------------------------------------+
| bin/symphony-tracker (new escript, BEAM process)       |
|                                                        |
|  Bandit + Plug router                                  |
|   |- POST  /issues/search                              |
|   |- POST  /issues/by_ids                              |
|   |- POST  /issues/:id/comments                        |
|   '- PATCH /issues/:id                                 |
|                                                        |
|  Each request -> IssueStore.* (no in-memory cache)     |
|                       |                                |
|       +---------------+---------------+                |
|       v                               v                |
|   tracker.json                  comments.jsonl         |
|   (read: parse on demand;       (single GenServer      |
|    PATCH write: tmp+rename)      serializes appends)   |
+--------------------------------------------------------+
```

Module boundaries (proposed names):

| Module | Responsibility |
|---|---|
| `SymphonyElixir.TrackerServer.CLI` | escript entrypoint, argv parsing, supervision tree start |
| `SymphonyElixir.TrackerServer.Application` | supervision tree: `Bandit` + `CommentLog` |
| `SymphonyElixir.TrackerServer.Router` | `Plug.Router` with the 4 routes + bearer auth plug |
| `SymphonyElixir.TrackerServer.IssueStore` | pure functions + file IO over `tracker.json` (load, search, by_ids, update_state) |
| `SymphonyElixir.TrackerServer.CommentLog` | `GenServer` that serializes appends to `tracker.comments.jsonl` |

## 4. File Contracts

Both files default to the escript working directory (matching existing
conventions like `./WORKFLOW.md` and `./log`). Override with `--file`. The
sidecar path is derived from `--file` (see CLI section).

### 4.1 `tracker.json`

```json
{
  "issues": [
    {
      "id": "task-1",
      "identifier": "LOCAL-1",
      "title": "Fix flaky test",
      "state": "Todo",
      "description": "optional",
      "priority": 2,
      "branch_name": "treedy/local-1",
      "url": "https://example.com/local-1",
      "assignee_id": "treedy",
      "labels": ["backend"],
      "blocked_by": [],
      "assigned_to_worker": true,
      "created_at": "2026-05-01T10:00:00Z",
      "updated_at": "2026-05-01T10:00:00Z"
    }
  ]
}
```

Constraints:

- Top level **must** be an object containing an `issues` array. The bare-array
  form allowed by SPEC §11.3 is rejected — we want headroom for future
  top-level fields.
- Each issue **must** have non-empty string `id`, `identifier`, `title`, and
  `state`. Other fields are optional; their absence aligns with the
  `CustomHttp` client's `normalize_issue` defaults.
- `id` is used as the URL parameter for PATCH and comment routes
  (`/issues/:id/...`). `id` **must be unique within the file**; duplicates fail
  startup.
- `identifier` is human-facing (e.g. `LOCAL-1`) and is recommended (but not
  enforced) to be unique.

### 4.2 `tracker.comments.jsonl`

Append-only, one JSON object per line:

```jsonl
{"at":"2026-05-01T10:30:00Z","issue_id":"task-1","body":"agent: starting work"}
{"at":"2026-05-01T10:31:14Z","issue_id":"task-1","body":"agent: opened PR #42"}
```

Fields:

- `at` — server-generated UTC ISO-8601 timestamp at the moment the request
  was received.
- `issue_id` — taken verbatim from the URL `:id` parameter. Existence is
  **not** validated against `tracker.json` (rationale: the comment write path
  must not need to read `tracker.json`, and the user can `grep` orphans
  manually).
- `body` — the request body's `body` field, stored verbatim.

### 4.3 Missing / malformed file behavior

- `tracker.json` missing at startup → server creates `{"issues": []}` and logs
  an INFO line. First-run UX works without a manual `echo`.
- `tracker.json` exists but is not valid JSON → escript fails to start.
  Error message includes file path and the underlying Jason decode error.
- `tracker.json` exists but violates the schema (top level is not a map,
  missing required fields, duplicate `id`) → escript fails to start. Error
  identifies which issue / which field.
- `tracker.comments.jsonl` missing → first comment append creates it.

### 4.4 Concurrency

- **PATCH** `/issues/:id` performs read → modify → write `tracker.json.tmp` →
  `File.rename!`. Concurrent PATCHes are unguarded; last rename wins. Symphony
  serializes its own writes, and the practical concurrency on a single-user
  local tool is near zero. We do not invest in a mutex.
- **Comment append** routes go through the `CommentLog` GenServer; appends
  are serialized.
- A user hand-editing `tracker.json` while Symphony PATCHes can clobber or be
  clobbered. The README must call this out. We do not defend against it.

## 5. HTTP Contract

### 5.1 Bearer token

- Source: `--token` flag, falling back to `SYMPHONY_TRACKER_API_KEY` env var.
  Flag wins if both are set.
- If neither is set → no auth check (acceptable for the
  default `127.0.0.1`-only bind).
- If a token is configured → every request must carry
  `Authorization: Bearer <token>` matched via `Plug.Crypto.secure_compare/2`,
  else `401`.
- Symmetric to `CustomHttp.headers/0` on the client side: client sends Bearer
  iff `tracker.api_key` is configured.

### 5.2 Routes

| Method | Path | Request body | Success | Failure |
|---|---|---|---|---|
| POST | `/issues/search` | `{"states":["Todo","In Progress"]}` | `200 {"issues":[…]}` | `400` body shape; `401` token mismatch |
| POST | `/issues/by_ids` | `{"ids":["task-1","task-2"]}` | `200 {"issues":[…]}` | `400`; `401` |
| POST | `/issues/:id/comments` | `{"body":"…"}` | `200 {"success":true}` | `400` body missing/empty; `401` |
| PATCH | `/issues/:id` | `{"state":"Done"}` | `200 {"success":true}` | `400`; `401`; `404` unknown id |

Anything that doesn't match a route → `404`. Body that isn't valid JSON →
`400`.

### 5.3 Per-route handling

**`POST /issues/search`**
- Parse `states`: must be a string array. Deduplicate. Case-sensitive exact
  match.
- Read `tracker.json`, filter issues whose `state` is in the set, return
  `{"issues": […]}` with each issue's fields passed through verbatim
  (preserving snake_case / camelCase / extra fields the user wrote).
- Empty `states` → `{"issues": []}` (defensive parity with the client's
  `if states == []` short-circuit).

**`POST /issues/by_ids`**
- Parse `ids`: must be a string array. Deduplicate.
- Read `tracker.json`, return matches by exact `id`. **Missing ids are
  silently dropped** — matches Linear's "deleted issue disappears from by-ids"
  semantics that the orchestrator's reconciliation already tolerates.

**`POST /issues/:id/comments`**
- `body` must be a non-empty string, else `400`.
- Send to `CommentLog`, await `:ok`, then `200`. GenServer write failure
  (e.g. disk error) → `500 {"success":false,"error":"…"}`.
- `:id` existence is **not** checked against `tracker.json`.

**`PATCH /issues/:id`**
- `state` must be a non-empty string, else `400`.
- `IssueStore.update_state/3`: read → find by `id` → set `state` → if the
  original issue object already has an `updated_at` field, refresh it to the
  current UTC ISO-8601 timestamp; if it does not, **do not** add the field
  (we don't quietly mutate a user's hand-edited shape).
- Write tmp + rename atomically.
- Unknown id → `404 {"success":false,"error":"unknown_issue_id"}`.
- Write failure → `500 {"success":false,"error":"…"}`.

### 5.4 Logging

- Startup: listen address, `--file` path, comments path, auth status, issue
  count.
- Per request: method, path, status, duration ms; failures include reason.
- `Logger.info/2` style consistent with the rest of Symphony. No structured
  JSON logs.

## 6. CLI

```
bin/symphony-tracker [--file ./tracker.json] [--port 8787] \
                     [--bind 127.0.0.1] [--token <STR>]
```

- `--file` — path to `tracker.json`. Default `./tracker.json`. `~` is expanded
  via the existing `SymphonyElixir.PathSafety` helper. The comments sidecar is
  derived from this: replace a trailing `.json` with `.comments.jsonl`; if the
  filename does not end in `.json`, append `.comments.jsonl` literally.
- `--port` — default `8787` (matches the README §110 example
  `http://127.0.0.1:8787`).
- `--bind` — default `127.0.0.1`. `0.0.0.0` is allowed but the README must
  warn about exposing the unauthenticated port.
- `--token` — falls back to `SYMPHONY_TRACKER_API_KEY` env var. If neither
  set, no auth.
- `--help` / unknown flag → print usage, exit non-zero.

Startup banner on stdout:

```
Symphony Tracker listening on http://127.0.0.1:8787
  file:    /Users/treedy/.symphony/tracker.json
  comments:/Users/treedy/.symphony/tracker.comments.jsonl
  auth:    bearer token (length 32)
  issues:  3 (states: Todo×2, In Progress×1)
```

Shutdown: SIGINT/SIGTERM → graceful stop Bandit → flush `CommentLog` → exit 0.

## 7. Build & Packaging

`mix.exs` currently configures one escript via `escript/0` (`bin/symphony`).
Mix's `escript.build` produces one binary per invocation, so we add a custom
Mix task:

- New file: `elixir/lib/mix/tasks/tracker_server.escript.ex` defining
  `Mix.Tasks.TrackerServer.Escript`. The task temporarily overrides
  `Mix.Project.config()`'s `:escript` key to point at
  `SymphonyElixir.TrackerServer.CLI` and produces `bin/symphony-tracker`,
  then calls `Mix.Tasks.Escript.Build.run/1`.
- `mix.exs` `aliases/0` updates `build` to:

  ```elixir
  build: ["escript.build", "tracker_server.escript"]
  ```

  so `mix build` produces both binaries in one shot.

## 8. Testing

### 8.1 Test classes

1. **`IssueStore` unit tests** — temp-dir file IO:
   - `load/1`: valid file, missing file (auto-create), unparseable JSON,
     schema violations (top-level not a map, missing required fields,
     duplicate `id`).
   - `update_state/3`: happy path, unknown id, `updated_at` refresh behavior
     (refreshes if present, does not add if absent), `tmp` cleanup on rename
     success.
   - `search/2`: state filter, empty `states` short-circuit.
   - `by_ids/2`: matches, missing ids silently dropped.

2. **`CommentLog` GenServer tests**:
   - `append/2` writes one JSONL line, fields are correct.
   - Concurrent callers serialize (order is `:ok` for each, file ends up with
     N lines).
   - Auto-creates the file on first append.

3. **`Router` integration tests** via `Plug.Test` (no Bandit):
   - Each of the 4 routes: success and 400/401/404/500 paths.
   - Auth: token-configured-but-missing → 401; token-configured-and-correct
     → pass; no-token-configured → pass without an `Authorization` header.
   - Unparseable JSON body → 400.

4. **End-to-end smoke test** (one happy-path case in
   `extensions_test.exs`): bring up real Bandit + Router on
   `127.0.0.1:0`, point the existing `SymphonyElixir.Tracker.CustomHttp`
   client at it, exercise all four operations: search returns the seeded
   issue, PATCH advances state, follow-up search reflects the new state,
   comment write produces a JSONL line. This is the test that validates the
   real wire path, not just the stubbed `:custom_http_tracker_request_fun`.

### 8.2 CLI testing

`SymphonyElixir.TrackerServer.CLI` follows the same pattern as
`SymphonyElixir.CLI`: argv-parsing logic is split into a pure function that is
tested in full; the supervision tree start function is added to
`mix.exs` `ignore_modules`.

### 8.3 Coverage threshold

The repo enforces 100% coverage with an `ignore_modules` allowlist. New
modules are added as follows:

- `IssueStore`, `CommentLog`, `Router` → 100%, **not** in `ignore_modules`.
- `CLI` → in `ignore_modules` (precedent: `SymphonyElixir.CLI`).
- `Application` → in `ignore_modules` (precedent: `HttpServer`,
  `SymphonyElixirWeb.Endpoint`).

## 9. Documentation

`elixir/README.md` gets a new sub-section right after the existing "For local
or internal trackers, use `custom_http`" block (around line 110), covering:

- How to start the server: command, flags, defaults.
- File formats with a minimal example.
- The concurrency caveat: do not hand-edit a running issue's `state` while
  Symphony is actively driving it.
- A minimal end-to-end recipe: write a `tracker.json` → start
  `bin/symphony-tracker` → write a `WORKFLOW.md` with `tracker.kind:
  custom_http` → start `bin/symphony` → watch the agent run.
- Security note about `--bind 0.0.0.0`.

`SPEC.md` is **not** changed by this design.

## 10. Open Questions

None at design-approval time. Items deliberately left for the implementation
plan:

- Exact wording of error messages from `IssueStore.load/1`.
- Whether `Plug.Parsers` JSON parser is used directly or wrapped to control
  the 400 body shape.
- Whether the Bandit listener uses `:inet` vs `:inet6` defaults (likely
  inherit Bandit defaults).
