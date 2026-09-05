# healr — Design Spec

Date: 2026-09-05
Status: approved design, pre-implementation

## Purpose

healr is an agent-agnostic fleet layer for Emacs: one consistent interface for
running and supervising multiple agentic CLI tools (Claude Code, opencode,
Kimi, and future CLIs such as codex/gemini/aider) in terminal buffers.

It exists because claude-code.el — the current daily driver — is Claude-only,
and the previously parked alternatives (agent-shell, agent-vterm, pilish) were
duplicate *launchers* for a single tool. healr is not a launcher for one agent;
it is the registry, status board, and context-sending layer for all of them.

## Context and constraints

- Emacs 29.4, Doom Emacs (master). Package targets Emacs 29.1+.
- Terminal backends available on this machine: **eat** (preferred — the user's
  config notes vterm "fossils Ink redraws" for TUI agents) and vterm (module
  compiled). Both are optional runtime dependencies; healr must work with
  either one and say clearly when the chosen backend is missing.
- Agent CLIs installed: `claude`, `opencode`, `kimi`. codex/gemini/aider are
  not installed — healr must have zero hard dependencies on any agent binary.
- License: GPL-3.0-or-later (MELPA-conventional).
- Package prefix: `healr-`. Single package, multiple files.

## Core concepts

### Agent definition (`healr-agents.el`)

An agent is a plist:

```elisp
(:name "claude"                 ; unique key, used in buffer names
 :command "claude"              ; executable, resolved with executable-find at launch
 :args nil                      ; list of extra arguments
 :env nil                       ; alist of extra environment variables
 :prompt-regexp "..."           ; optional; matches the agent's input prompt
 :backend nil)                  ; optional; 'eat or 'vterm, overrides global default
```

- User-facing variable: `healr-agent-list`, an alist of name → plist.
- Ships presets for `claude`, `opencode`, `kimi`, each with a best-effort
  `:prompt-regexp` (may be nil when no reliable pattern exists).
- A preset whose binary is absent costs nothing until that agent is launched.

### Session (`healr-session.el`)

- A session is keyed by the list `(project-root agent-name session-name)`.
- Default session name is `"main"`; additional sessions are created with
  `M-x healr-new-session` which prompts for agent and name.
- Buffer naming: `*healr:<project>:<agent>:<session>*` (project = directory
  basename of project root).
- Project root resolution: `project-current` (project.el), falling back to
  `default-directory`.
- Registry operations: get-or-create, list (all sessions, or filtered by
  project), rename, kill (process + buffer + registry entry), restart
  (dead sessions only: re-spawn same command in same root, reusing the
  buffer name).
- Toggle semantics for display: if the session's buffer is visible in a
  window, bury it; otherwise pop to it.

### Terminal backend (`healr-term.el`)

Thin abstraction over eat and vterm:

- `healr-term-make` — create buffer + process (command, args, env, directory).
- `healr-term-send-string`, `healr-term-send-return` — input.
- `healr-term-alive-p` — process liveness.
- Backend selection: global defcustom `healr-terminal-backend` (default
  `'eat`), overridable per agent via `:backend`.
- The inactive backend is never required; picking an uninstalled backend
  signals a clear user error naming the missing package.

### Status (`healr-status.el`)

Three session states:

- `working` — process alive, terminal output within `healr-idle-seconds`
  (default 5).
- `idle` — process alive, no output for `healr-idle-seconds`, or the agent's
  `:prompt-regexp` matched recent output (immediate idle, no waiting for the
  timer).
- `dead` — process exited (sentinel fired).

Surfaces:

- Modeline segment in healr session buffers: agent name + state.
- `M-x healr-list` — fleet buffer (tabulated-list-mode) over all sessions
  across projects: project, agent, session, state, seconds since last output.
  Keys: `RET` jump to session, `n` new session, `k` kill, `r` restart,
  `R` rename, `g` revert/refresh, `q` quit.

### Entry points (`healr.el`)

- `M-x healr` — completing-read over all configured agents (missing
  binaries are not filtered here; they error at launch), get-or-create the
  `"main"` session in the current project, toggle visibility.
- `M-x healr-new-session` — agent + name, always creates.
- `M-x healr-send-dwim` — from a file buffer, insert `@relative/path` (or
  `@relative/path#L10-20` with active region) into a target session's prompt
  without submitting. Only live sessions are candidates: one live session in
  the project → target it directly; more than one → completing-read.
- The package binds no global keys. The fleet buffer has its own keymap;
  a Doom config snippet goes in the README.

## Data flow

1. `M-x healr` → pick agent → resolve project root → session lookup.
2. Miss → `healr-term-make` spawns the process with `default-directory` set
   to the root → session registered → sentinel and output watch attached.
3. Terminal output → status set to `working`, timestamp recorded; on
   `healr-idle-seconds` of silence (timer) or prompt-regexp match → `idle`.
   Modeline and fleet buffer refresh on every state change.
4. Process exit → sentinel → state `dead`; session stays in the registry
   until explicitly killed. `r` in the fleet buffer restarts it in place.
5. `healr-send-dwim` → compute path relative to the target session's root →
   send string via the backend → leave point in the session buffer so the
   user can type the rest of the prompt.

## Error handling

- Agent binary not found at launch (`executable-find` fails) → user error
  naming agent and command; no buffer created.
- Chosen backend not installed → user error naming the missing package;
  no partial state.
- Process dies on its own → session marked `dead`, never silently removed;
  restart is one key in the fleet buffer.
- `healr-send-dwim` with no live session in the project → user error
  suggesting `M-x healr`.

## Testing

- ERT unit tests (`test/healr-test.el`) for all pure logic: agent-list
  normalization, session registry (get-or-create, rename, kill bookkeeping,
  restart guards), buffer-name generation, dwim path computation (relative
  paths, `#L` ranges), and the status state machine driven by mocked output
  events. The terminal backend is mocked for these — no real processes.
- `sandbox.sh`: launches `emacs -Q`, installs eat into a throwaway package
  dir, loads healr from the repo, and provides a fake agent (a small shell
  script that echoes a prompt and cats stdin) so interactive smoke testing
  needs no API keys.
- Test command documented in README:
  `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`.

## File layout

```
healr.el            ; entry points, defgroup, dispatch
healr-agents.el     ; agent plist shape, presets, normalization
healr-session.el    ; session registry and lifecycle
healr-term.el       ; eat/vterm backend abstraction
healr-status.el     ; state tracking, modeline, fleet buffer
test/healr-test.el  ; ERT suite
sandbox.sh          ; throwaway-environment smoke test
README.md           ; install (Doom snippet), usage, test command
LICENSE             ; GPL-3.0
```

## Out of scope (v1)

- Session persistence or reattach (tmux/dtach).
- MCP integration, monet-style companions.
- Cost or token tracking.
- gptel or in-buffer chat coupling.
- A Doom module (README snippet is enough).
- Global keybindings.

## Success criteria

- From any project buffer, launch claude, opencode, or kimi into its own
  named session with one command.
- Multiple sessions per agent per project coexist and are individually
  addressable.
- Fleet buffer shows every session across projects with a live state that
  matches the three-state model above.
- A dead agent restarts in place; a missing binary fails loudly at launch.
- `ert` suite is green with the terminal backend mocked.
