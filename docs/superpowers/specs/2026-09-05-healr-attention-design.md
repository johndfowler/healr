# healr Phase 3 — The Fleet Calls You (attention layer) Design Spec

Date: 2026-09-05
Status: approved direction, pre-implementation

## Purpose

Supervision in healr is currently pull: the user polls `*healr fleet*`.
Phase 3 makes it push — healr notices when an agent needs attention and
says so in every buffer's modeline, with optional alerts, whether or not
the agent has an Emacs buffer attached.

## The `blocked` state

A fifth session state joins `working` / `idle` / `detached` / `dead`:

- `blocked` — the agent is waiting on the user for something specific: a
  permission prompt, a y/n question, a menu. Distinct from `idle`
  (waiting at an ordinary prompt).

Detection for attached sessions, per agent plist:

- New optional key `:blocked-regexp` — a regexp matching the agent's
  blocked screens (e.g. Claude Code's permission prompts). Ships nil in
  presets (users tune to their setup); documented with examples.
- On every terminal output chunk, the watcher matches against the
  terminal buffer's TAIL (last ~40 lines), not the chunk: blocked
  prompts stay on screen until answered, so the tail is the source of
  truth. Precedence on each evaluation:
  1. `:blocked-regexp` matches the tail → `blocked`
  2. else `:prompt-regexp` matches recent output → `idle`
  3. else → `working` (idle timer armed)
- `blocked` clears on the next evaluation that no longer matches (the
  user answered; the screen changed). `healr-status--mark-blocked`
  cancels the idle timer.
- Blocked rows show in the fleet State column, propertized with the
  `error` face.

## Attention surfacing

- `healr-attention-mode` — global minor mode. When on, a modeline
  segment appears in every buffer via `global-mode-string`:
  ` healr[b:1 i:2 d:1]` showing only non-zero counts of
  blocked/idle/dead sessions (detached counts as idle for this
  purpose); the segment hides entirely when all counts are zero.
  Faces: blocked count `error`, dead `warning`, idle default. Clicking
  (`mouse-1`) opens the fleet buffer. The mode also owns the detached
  polling timer (below) when warm sessions exist.
- Transition alerts: when `healr-status--set` moves a session INTO a
  state listed in `healr-attention-states` (defcustom, default
  `'(blocked dead)`) and the session's buffer is not visible in any
  window (nil buffer counts as not visible),
  `healr-attention-alert-function` (defcustom) is called with
  (SESSION STATE). Two functions ship:
  - `healr-attention--echo` (default) — `(message ...)` with agent,
    session, state, project.
  - `healr-attention--system` — macOS `osascript` notification when
    available, `notifications-notify` when fboundp, echo otherwise.
  Fires only on actual state CHANGE (status--set already no-ops on
  same-state), so no repeat-alert storms.

## Detached polling (capture-pane)

- When `healr-attention-mode` is on and any warm session exists, a
  global timer every `healr-attention-poll-seconds` (defcustom, default
  30) runs `healr-attention--poll`:
  - For each registry session in `detached` or warm `blocked` state:
    `tmux capture-pane -t TMUX -p` (via `healr-term--tmux-output`) →
    agent `:blocked-regexp` matches → `blocked`; no match → `detached`.
  - A warm session whose tmux vanished is left to rehydrate (no
    double-duty).
- Alerts fire from these transitions like any other, so a blocked agent
  in a bufferless tmux lights up the modeline and (optionally) the OS.

## API and struct changes

- `healr-agents.el`: `:blocked-regexp` in normalize pass-through and the
  `healr-agent-list` docstring.
- `healr-status.el`:
  - `healr-status--buffer-tail (buffer &optional lines)` → string|nil.
  - note-output evaluation gains the blocked branch (buffer-tail based).
  - `healr-status--mark-blocked`.
  - `healr-attention-mode`, `healr-attention--mode-line`,
    `healr-attention--counts`, `healr-attention--echo`,
    `healr-attention--system`, `healr-attention--poll`.
  - Defcustoms: `healr-attention-states`,
    `healr-attention-alert-function`, `healr-attention-poll-seconds`.
  - `healr-status--set` fires the alert function per the rules above.
  - Fleet `d`etach unchanged; fleet State column propertizes `blocked`.
- No struct changes; no changes to term/session files.

## Error handling

- Missing/invalid `:blocked-regexp` — watcher errors are already
  contained (condition-case in the filter wrapper, v1.1); poll wraps
  its per-session work in condition-case and moves on.
- `tmux` absent → capture-pane returns nil via the degrading wrappers;
  poll treats it as "no information", leaves state untouched.
- Alert function errors are caught (condition-case) and never break
  state tracking.

## Testing

- ERT: tail helper; note-output blocked match/clear/precedence;
  mark-blocked cancels timer; attention counts and segment formatting;
  alert fires on blocked/dead transitions only when the buffer is not
  visible, with the configured states list; echo formatter; poll
  (stubbed capture-pane) sets and clears blocked, skips non-detached.
  No real tmux needed in ERT.
- E2E (`test/e2e-warm.sh` extended, real tmux): fake agent learns
  `/block` (prints a permission prompt until answered) — spawn with
  `:blocked-regexp`, send `/block`, expect `blocked`; detach, drive the
  tmux pane directly, poll, expect `blocked` again; answer, poll,
  expect `detached`; kill clean.

## Out of scope (still)

- Agent-protocol hooks (Claude Code hooks, opencode events).
- Inter-agent workflows, broadcast, task queues.
- Sound/LED/hubot integrations beyond the two alert functions.
- Per-state user hooks beyond the alert function.

## Success criteria

- In another project, the modeline shows `b:1` when any session blocks;
  mouse-1 → fleet → `RET` → answer → count clears.
- A blocked detached warm session is detected within
  `healr-attention-poll-seconds` and alerted per
  `healr-attention-states`.
- No alerts while the session's buffer is visible; no repeats without a
  state change.
- Suite green; warm E2E green on the dev machine.
