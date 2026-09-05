# Changelog

All notable changes to healr, in [Keep a Changelog](https://keepachangelog.com/) form.
This project uses semantic-ish versioning; the public API is the set of
interactive commands, defcustoms, and the agent plist keys.

## [0.4.0] — 2026-09-05 "The fleet calls you"

### Added
- **`blocked` session state** — the agent is waiting on the user
  (permission prompt, y/n question), detected per agent via the new
  `:blocked-regexp` plist key, matched against what's on the screen.
  Blocked rows are highlighted in the fleet buffer.
- **`healr-attention-mode`** — global minor mode showing live
  `healr[b:N i:N d:N]` counts (blocked/idle/dead; detached counts as
  idle) in every buffer's modeline; click to open the fleet buffer.
- **Transition alerts** — `healr-attention-alert-function` (echo area
  by default, `healr-attention--system` for macOS notifications) fires
  on state changes into `healr-attention-states` (default blocked and
  dead) when the session's buffer isn't visible.
- **Detached blocked detection** — warm sessions are checked with
  `tmux capture-pane` every `healr-attention-poll-seconds` (default 30),
  so a blocked agent with no Emacs buffer attached still lights up.
- `healr-status-tail-lines` defcustom (terminal tail window, default 12).
- `test/e2e-attention.sh` — real-tmux E2E for the attention layer;
  the fake agent learned `/block`.

### Fixed
- The status watcher now renders before evaluating (the wrapped filter
  used to see the screen one chunk behind).
- Blocked evaluation moved off the chunk path entirely: eat renders
  from a queue, so it runs from `eat-update-hook`; vterm renders
  inline, so it runs post-filter; warm sessions always read the screen
  via `tmux capture-pane` (a tmux client owns the terminal, so the
  buffer tail can be blank while the screen shows a prompt).

### Tests
- 89 ERT tests, all green; both E2E scripts green on the dev machine.

## [0.3.0] — 2026-09-05 "Warm sessions"

### Added
- **Persistence via tmux** — agents with `:persist t` (or
  `healr-persist-default`) run in detached tmux sessions
  (`healr_<agent>_<name>_<hash8>`); the eat/vterm buffer attaches a
  tmux client. Agents survive killed buffers and Emacs restarts.
- **`detached` session state** — tmux alive, no Emacs buffer attached.
  Killing a warm session's buffer detaches instead of destroying.
- **Rehydration** — `healr-rehydrate` rebuilds the registry from live
  tmux sessions and sidecar metadata in
  `healr-session-metadata-directory` (`~/.cache/healr/sessions/`);
  runs on dispatch and fleet open/refresh.
- `healr-session-detach` / `healr-session-attach`; fleet `d` detaches;
  `RET` reattaches with scrollback; `r` respawns dead warm sessions
  under the same tmux name.
- `test/e2e-warm.sh` — real-tmux lifecycle E2E (spawn → detach →
  simulated restart → rehydrate → reattach → echo → kill).

### Fixed
- `healr-session-detach` no longer triggers the "buffer has a running
  process" query (binds `kill-buffer-query-functions` nil).
- Sentinel contract for warm sessions: acts only when the dying
  process is the session's current client (a dead process has no
  buffer association), then branches `detached`/`dead` via
  `tmux has-session`.
- Sidecar reads reject non-plist garbage.

### Tests
- 70 ERT tests, all green.

## [0.2.0] — 2026-09-05 "Project-aware defaults"

### Added
- `healr-project-agent-alist` — marker-file → agent-name mapping
  (default `mix.exs` → elixir, `build.gradle[.kts]` → kotlin).
  `M-x healr` and `M-x healr-new-session` pre-select the mapped agent
  when the marker exists at the project root and the agent is
  configured. Mappings with no configured agent are inert.
- README "Language workflows" section: direnv/mise/SDKMAN wrap recipes
  for agents that need shell environment setup (eat execs directly).

### Tests
- 45 ERT tests, all green.

## [0.1.0] — 2026-09-05 "The fleet"

### Added
- **Fleet layer for agentic CLIs in Emacs** — run and supervise
  Claude Code, opencode, Kimi and friends in terminal buffers, one
  buffer per (project, agent, session) triple.
- Agent plists (`:command :args :env :prompt-regexp :backend`) with
  presets for claude/opencode/kimi; zero hard dependencies on any
  agent binary (`executable-find` at launch).
- Terminal backends: **eat** (default, direct `eat-exec`) and **vterm**
  (shell + `exec`, buffer survives agent exit) — both optional,
  lazily required.
- Session registry keyed `(root agent name)` with collision-safe
  buffer naming (`*healr:project:agent:session*`, hash suffix on
  cross-project basename collisions); get-or-create, rename, kill,
  restart (dead only), toggle.
- Status tracking: `working`/`idle`/`dead` from process filter and
  sentinel watching, idle after `healr-idle-seconds` or an immediate
  `:prompt-regexp` match; modeline segment per session buffer.
- **Fleet buffer** (`M-x healr-list`, tabulated-list): jump, new,
  kill, restart, rename, refresh.
- `M-x healr` / `healr-new-session` / `healr-send-dwim`
  (`@path` / `@path#L10-20` insertion at a session's prompt).
- `sandbox.sh` + `test/fake-agent.sh` — throwaway `emacs -Q` smoke
  environment, no API keys needed.
- Sunset-temple logo, GPLv3, GitHub repo.

### Fixed (post-release review hardening)
- Stale sentinels can no longer mark a restarted session dead.
- Watcher errors (e.g. a bad `:prompt-regexp`) can't break the
  terminal's own filter.
- `:prompt-regexp` matches a 500-char recent-output window (split
  prompts work); kill disarms filter/sentinel before `delete-process`;
  DWIM only targets sessions with a live process; create/rename
  reject duplicate keys and empty names.

### Tests
- 43 ERT tests, all green; real eat/vterm E2E on the dev machine.
