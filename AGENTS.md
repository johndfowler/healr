# AGENTS.md — healr

Guidance for AI coding agents working in this repository. The reader is
assumed to know nothing about the project.

## Project overview

**healr** is a fleet layer for agentic CLI tools in Emacs. It runs and
supervises multiple agent CLIs (Claude Code, opencode, Kimi, ...) in
terminal buffers: every `(project, agent, session)` triple gets its own
terminal buffer, and a "fleet buffer" shows every session's state
(`working` / `idle` / `dead`) at a glance.

- Language: **Emacs Lisp** (requires Emacs 29.1+; developed on 29.4)
- Package: single package `healr`, spread across five `.el` files
- License: GPL-3.0-or-later (see `LICENSE`)
- Runtime deps: Emacs stdlib only, plus **either** `eat` (default) **or**
  `vterm` as the terminal backend — both are *optional* and loaded lazily
- There is no build system: no Makefile, package.json, or byte-compile
  step is required to use or test the package
- Install path for users: Doom Emacs `(package! healr :recipe (:local-repo ...))`
  (see `README.md`)

## Repository layout

```
healr.el            Entry points: M-x healr, healr-new-session, healr-send-dwim
healr-agents.el     Agent definitions: healr-agent-list alist, normalization, lookup
healr-term.el       Terminal backend abstraction: eat (default) / vterm
healr-session.el    Session registry + lifecycle (create/kill/restart/rename/toggle)
healr-status.el     State tracking, process watchers, modeline, fleet buffer
test/healr-test.el  ERT test suite (all layers)
test/fake-agent.sh  Stand-in agent CLI for the sandbox (echoes input, /quit exits)
sandbox.sh          Throwaway `emacs -Q' smoke-test environment
README.md           User-facing install/usage docs
QWEN.md             Project context doc (architecture summary, conventions)
docs/superpowers/   Design spec + implementation plan (specs/, plans/)
```

Dependency direction between modules (each file `require`s what it needs;
no cycles):

```
healr-agents  <-  healr-term  <-  healr-session  <-  healr-status  <-  healr
```

## Core architecture

- **Agents** are plists `(:name :command :args :env :prompt-regexp :blocked-regexp :backend :persist)`
  configured through the `healr-agent-list` defcustom (alist of name -> plist)
  and normalized by `healr-agent--normalize`. `:prompt-regexp` matches the
  agent's input prompt in terminal output and marks the session idle
  immediately; `:blocked-regexp` matches the agent's blocked screens
  (permission prompts, y/n questions) and marks the session blocked;
  `:backend` overrides the global terminal backend per agent.
  Ships presets for `claude`, `opencode`, `kimi`. A preset whose binary is
  missing costs nothing until launched (`executable-find` check at launch,
  `user-error` if absent).
- **Sessions** are `cl-defstruct` `healr-session` (fields: root, agent, name,
  buffer, state, last-output, recent-output, timer, tmux) keyed by
  `(root agent name)` in the
  `healr--sessions` hash table. Default session name is `"main"`. Project
  root comes from `project-current` (project.el) falling back to
  `default-directory`, via the `healr-project-root-function` defcustom.
- **Terminal backends** (`healr-term.el`): `healr-term-make` dispatches on
  `healr-terminal-backend` (default `'eat`, per-agent `:backend` override).
  - eat: `eat-exec` runs the binary directly, *without* shell startup files
    (wrap agents needing direnv/shims as `:command "direnv" :args ("exec" "." "cmd")`).
  - vterm: starts the user's shell and sends `exec <cmd>` so rc files run;
    binds `vterm-kill-buffer-on-exit` to nil so the buffer survives process
    exit and `healr-session-restart` can reuse it.
  - eat/vterm must **never** be required at top level; load with
    `(require 'eat nil t)` inside the backend function and signal `user-error`
    naming the missing package.
- **Status** (`healr-status.el`): five states — `working` (output within
  `healr-idle-seconds`, default 5), `idle` (silence timeout or
  `:prompt-regexp` match), `blocked` (agent waiting on the user —
  permission prompt/y-n question, matched by the agent's
  `:blocked-regexp` against the screen), `detached` (warm session:
  tmux alive, no Emacs buffer attached), `dead` (process/tmux gone).
  Blocked evaluation runs from `eat-update-hook` (eat renders from a
  queue), after the filter (vterm renders inline), and via
  `healr-attention--poll` for detached warm sessions; warm sessions
  read the screen with `tmux capture-pane`.
  `healr-status-attach` (on `healr-session-created-hook`) chains a watcher
  onto the process filter/sentinel, sets the modeline segment, and arms the
  idle timer. Dead sessions stay in the registry until explicitly killed;
  restart re-runs the same command in the same root.
- **Fleet buffer**: `M-x healr-list`, a `tabulated-list-mode` buffer over all
  sessions across all projects. Keys: `RET` jump (reattach when
  detached), `n` new, `k` kill (confirms), `r` restart (dead only),
  `R` rename, `d` detach (warm only), `g` refresh (rehydrates first).
- **Buffer naming**: `*healr:<project-base>:<agent>:<session>*`; on collision
  with a buffer owned by a *different* project root, disambiguate with an
  8-char sha1 prefix of root: `*healr:<base>-<hash>:<agent>:<session>*`.
- **Project-aware defaults**: when the project root contains a marker
  from `healr-project-agent-alist` (default `mix.exs` → `elixir`,
  `build.gradle[.kts]` → `kotlin`) and that agent is configured, the
  dispatch commands pre-select it in the completing-read.
- **Attention** (`healr-attention-mode`): global minor mode showing
  `healr[b:N i:N d:N]` counts (blocked/idle/dead; detached counts as
  idle) in every buffer's modeline, click for the fleet. Transitions
  into `healr-attention-states` fire
  `healr-attention-alert-function` (default echo;
  `healr-attention--system` for macOS notifications) when the
  session's buffer isn't visible. Alerts are independent of the mode.
- **Warm sessions** (`:persist` on an agent, or `healr-persist-default`):
  the agent runs in a detached tmux session
  (`healr_<agent>_<name>_<hash8>`); the eat/vterm buffer runs a tmux
  client attaching to it. Killing the buffer detaches (agent keeps
  running); `healr-rehydrate` rebuilds the registry from live tmux
  sessions + sidecars in `healr-session-metadata-directory`. The
  sentinel branches `detached`/`dead` via `healr-term--tmux-alive-p`,
  guarded on the dying process being the session's current client (the
  buffer has no *other* live process). All tmux calls go through
  `healr-term--tmux-run` / `healr-term--tmux-output`, which degrade
  quietly when tmux is absent.
- **healr-send-dwim**: from a file buffer, inserts `@relative/path` (or
  `@relative/path#L10-20` with an active region) at a live session's prompt
  without submitting; with multiple live sessions it prompts which.

## Build and test commands

Run the full ERT suite from the repo root:

```bash
emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit
```

Expected: `Ran 35 tests, 35 results as expected, 0 unexpected`. Run it
before considering any change complete.

Interactive smoke test (no API keys needed):

```bash
./sandbox.sh         # GUI Emacs (terminals need a real frame)
./sandbox.sh -nw     # terminal Emacs
```

The sandbox installs `eat` into a private `.sandbox/elpa` package dir (your
own Emacs config is untouched), loads healr from the repo, and preconfigures
a `fake` agent running `test/fake-agent.sh`. `.sandbox/` is gitignored.

There is no linter/formatter config in the repo; correctness is enforced by
the ERT suite plus Emacs Lisp conventions (below).

## Code style guidelines

- Every `.el` file starts with
  `;;; <file> --- <desc>  -*- lexical-binding: t; -*-` and ends with
  `(provide '<feature>)` then `;;; <file> ends here`. Lexical binding is
  mandatory everywhere.
- Symbol naming: `healr-` prefix on everything; `healr--` (double dash) for
  internal/private symbols, e.g. `healr--sessions`, `healr-status--set`.
- Only built-ins plus `cl-lib`, `seq`, `subr-x`, `project`, `tabulated-list`
  may be `require`d unconditionally. Declare foreign functions/vars with
  `declare-function`/`defvar` instead of hard-requiring optional packages
  (see the eat/vterm declarations at the top of `healr-term.el`).
- No hard dependency on any agent binary; always check with
  `executable-find` at launch time.
- User-facing failures signal `user-error` with a message prefixed `healr: `.
- Customization lives in `defgroup healr` (defined in `healr-agents.el`);
  defcustoms: `healr-agent-list`, `healr-terminal-backend`,
  `healr-idle-seconds`, `healr-project-root-function`,
  `healr-project-agent-alist`, `healr-persist-default`,
  `healr-session-metadata-directory`, `healr-status-tail-lines`,
  `healr-attention-states`, `healr-attention-alert-function`,
  `healr-attention-poll-seconds`.
- The package binds **no global keys**; only the fleet buffer has its own
  keymap (`healr-list-mode-map`).
- State changes go through `healr-status--set`, which refreshes the fleet
  buffer on change; don't `setf` a session's state directly in new code.
- Match existing idioms: `when-let*`/`if-let*`, `pcase` for backend
  dispatch, `cl-letf` for stubbing in tests.

## Testing instructions

- Framework: **ERT** (`ert-deftest`), all tests in `test/healr-test.el`,
  grouped by layer in the same order as the source files (agents, term,
  session, status, DWIM/entry points).
- Tests must not spawn real agent processes or require eat/vterm. Use the
  `healr-test--with-fake-term` macro (stubs `healr-term-make` and
  `executable-find`) for session-lifecycle tests, and `cl-letf` on
  `symbol-function` for everything else. One test
  (`healr-test-status-attach-watches-real-process`) uses a real `cat`
  process to exercise the filter/sentinel chaining; guard anything similar
  with `skip-unless`.
- Isolate state in every test: bind a fresh `healr--sessions`
  `(make-hash-table :test 'equal)`, set `healr-agent-list` locally, cancel
  timers and kill buffers in `unwind-protect` cleanup (including any
  partially-created session buffers on failure paths).
- When adding a feature, add its ERT tests to `test/healr-test.el` in the
  matching layer section; keep the suite green with the terminal backend
  mocked.

## Development workflow and conventions

- Git branch: `master`. Commit style observed in history: Conventional
  Commits (`feat:`, `fix:`, `docs:`, `chore:`), e.g.
  `feat: status tracking and fleet buffer`.
- `.gitignore` covers `.sandbox/` (sandbox state) and `.superpowers/`
  (local tooling workspace) — do not commit either.
- `docs/superpowers/specs/2026-09-05-healr-design.md` is the approved design
  spec and `docs/superpowers/plans/2026-09-05-healr.md` the implementation
  plan; consult them for intent when behavior seems arbitrary. If you change
  documented behavior, update the spec, `README.md`, and `QWEN.md` to match.
- Explicitly out of scope for v1 (from the design spec — do not add without
  being asked): session persistence/reattach (tmux/dtach), MCP integration,
  cost/token tracking, gptel coupling, a Doom module, global keybindings.

## Security considerations

- healr executes arbitrary agent binaries on the user's machine with the
  user's environment. Never auto-launch agents; launching is always an
  explicit user action (`M-x healr` / `healr-new-session`).
- The `:env` plist key injects environment variables into the agent process;
  treat values as sensitive — never log or echo them.
- Agent processes may handle API keys (e.g. for Claude/Kimi). Keep secrets
  out of the repo: tests and the sandbox must stay key-free
  (`test/fake-agent.sh` exists precisely so no real credentials are needed).
- `sandbox.sh` writes only into the gitignored `.sandbox/` directory and
  downloads `eat` from GNU ELPA over HTTPS; it does not touch the user's
  Emacs configuration.
- When shell-quoting is needed (the vterm backend's `exec <cmd>` line),
  always use `shell-quote-argument` — never interpolate commands raw.
