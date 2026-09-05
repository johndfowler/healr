# healr Phase 2 — Warm Sessions (persistence) Design Spec

Date: 2026-09-05
Status: approved direction, pre-implementation

## Purpose

Today every healr session dies with Emacs. Phase 2 makes sessions warm:
agents keep running inside tmux when Emacs closes (or when the user kills
the terminal buffer), and the fleet reassembles itself on return. This is
the spec's declared north star from v1 — codersauce/red's attach/detach
persistence — applied to the agent fleet.

## Core model

Persistence is a per-agent opt-in layered over the existing terminal
backends, NOT a third backend:

- Agent plists gain a `:persist` key (boolean, default nil). Normalization
  passes it through like the other keys.
- Global defcustom `healr-persist-default` (default nil) sets the fallback
  when an agent plist does not say.
- When persist is on, the agent process runs inside a detached tmux
  session; the eat/vterm buffer runs a tmux CLIENT attaching to it. The
  terminal backend choice (eat vs vterm) stays orthogonal.

Two processes exist per warm session: the durable tmux session (the
agent) and the disposable attachment client (what eat/vterm runs).

## tmux naming and metadata

- tmux session name: `healr_<agent>_<name>_<sha1(root)[:8]>`, with
  agent/name sanitized to `[a-zA-Z0-9_-]` (everything else becomes `-`).
  Deterministic, so rehydration and re-attach always compute the same
  name.
- Sidecar metadata: one elisp file per warm session in
  `healr-session-metadata-directory` (defcustom, default
  `~/.cache/healr/sessions/`). Contents: printed plist
  `(:root R :agent A :name N :backend B)`. Written at spawn, deleted at
  kill. This is the rehydration source.
- tmux spawn options: `tmux new-session -d -s NAME -c ROOT -e K=V...`
  for agent env, then per-session `set-option status off`,
  `set-option history-limit 50000`. No `remain-on-exit`: the tmux
  session must END when the agent exits — that is what makes
  `has-session` a truthful liveness check.

## The `detached` state

A fourth session state joins `working` / `idle` / `dead`:

- `detached` — the agent's tmux session is alive, but no Emacs buffer is
  attached to it.

Transitions:

- Attachment process (tmux client) dies → wrapped sentinel checks
  `tmux has-session`: alive → `detached`; gone → `dead`. This single
  check covers both intentional detach (buffer killed) and agent exit
  (tmux session ends, client exits).
- Killing the healr buffer with plain `kill-buffer` therefore detaches
  rather than destroys — warm by default.
- Non-persist sessions keep v1 behavior exactly (no tmux check; client
  death = `dead`).

New actions:

- `healr-session-detach` — kill only the attachment buffer (sentinel
  moves the session to `detached`). Fleet buffer key: `d`.
- Reattach — `healr-session-toggle` / fleet `RET` on a `detached`
  session creates a fresh eat/vterm buffer running
  `tmux attach-session -t NAME`, re-wraps watchers, state recomputed
  from output.

## Lifecycle changes

- **create** (persist on): require `tmux` on PATH (`user-error` naming
  it when absent); compute tmux name; `tmux new-session -d` with env and
  options; write sidecar; attach a terminal buffer; register with the
  struct's new `tmux` field set.
- **kill**: kill attachment buffer if live; `tmux kill-session`;
  delete sidecar; remove from registry.
- **restart** (dead only): respawn the tmux session under the same name
  (sidecar already exists), attach, state `working`.
- **rehydrate** (`healr-rehydrate`, also run by `M-x healr` dispatch and
  when the fleet buffer opens): `tmux list-sessions`, filter `healr_`
  prefix; for each with a readable sidecar and no registry entry, add a
  `detached` struct (no buffer). Registry entries already marked
  `detached` whose tmux session has vanished become `dead`.

## Struct and API changes

- `healr-session` struct gains field `tmux` (tmux session name string,
  or nil for non-persist sessions).
- `healr-term.el`:
  - `healr-term--tmux-run (&rest args)` — single `call-process` wrapper
    all tmux shell-outs go through (tests stub this one function).
  - `healr-term--tmux-name (root agent name)` → sanitized name.
  - `healr-term--tmux-alive-p (tmux-name)` → boolean via `has-session`.
  - `healr-term--tmux-spawn (tmux-name agent directory)` → detached
    session with env + options; `user-error` when tmux is missing.
  - `healr-term--tmux-attach (buffer-name tmux-name backend)` →
    eat/vterm buffer running the attach client.
- `healr-session.el`: sidecar read/write/delete helpers;
  `healr-session-detach`; `healr-rehydrate`; create/kill/restart/toggle
  updated as above.
- `healr-status.el`: for tmux-backed sessions the wrapped sentinel
  acts only when the dying process is the session's current client —
  where "current" means the session buffer is live and has NO live
  process of its own, or its process IS the dying one. (Emacs clears
  the buffer-process association on exit, so identity against
  `get-buffer-process` cannot be used: a dead process has no
  association, while a buffer with a DIFFERENT live process means a
  newer attachment exists and the stale sentinel must be ignored.)
  Only then does it branch on `healr-term--tmux-alive-p`: alive →
  `detached`, gone → `dead`. Fleet `d` key; `detached` appears in the
  State column like any state.
- `healr.el`: dispatch runs `healr-rehydrate` before lookup so a warm
  `main` session reattaches instead of spawning a duplicate.

## Error handling

- tmux binary missing at launch with persist on → `user-error` naming
  tmux; no partial state (no sidecar, no registry entry).
- Attach racing a session that just died → tmux client exits
  immediately; sentinel marks `dead`; the buffer shows tmux's message.
- Sidecar unreadable/missing for a live `healr_*` tmux session → skipped
  by rehydrate (never guessed at), reported in the fleet buffer's
  messages.
- `healr-session-metadata-directory` is created on demand.

## Testing

- ERT with `healr-term--tmux-run` stubbed: name sanitization, spawn
  argv, alive-p parsing, sidecar round-trip, rehydrate (temp metadata
  dir + fabricated `list-sessions` output), sentinel detached/dead
  branches, kill/restart/detach bookkeeping, fleet `d`.
- Real E2E (tmux is installed on the dev machine): persist fake agent →
  tmux session exists → kill attachment buffer → state `detached`, agent
  still alive → reattach → send ping → echo received → kill → tmux
  session and sidecar gone. Runs headless in batch like the v1 E2E.
- Suite must stay green with tmux entirely absent (all tmux paths
  stubbed or guarded).

## Out of scope (still)

- Attention/notification layer (Phase 3: "the fleet calls you").
- Inter-agent workflows, broadcast, task queues.
- `tmux capture-pane`-powered state detection (a later upgrade; noted
  here only as the reason tmux beat dtach).
- Migrating non-persist sessions to persist ones mid-flight.

## Success criteria

- Quit Emacs with three agents mid-conversation; reopen; `M-x healr-list`
  shows all three `detached`; `RET` reattaches with scrollback intact.
- Killing a session buffer detaches; `M-x healr` on that agent's `main`
  session reattaches instead of duplicating.
- Agent exit with no Emacs attached is reported as `dead` at rehydrate.
- Non-persist agents behave exactly as in v1.
- ERT suite green with and without tmux present; real-tmux E2E green on
  the dev machine.
