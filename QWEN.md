# healr

A fleet layer for agentic CLI tools in Emacs — runs and supervises Claude Code, opencode, Kimi, and other agent CLIs in terminal buffers.

## Architecture

The package is split across five `.el` files, each a distinct concern:

| File | Concern |
|---|---|
| `healr.el` | Entry points: `healr`, `healr-new-session`, `healr-send-dwim` |
| `healr-agents.el` | Agent definitions (`healr-agent-list` alist), normalization, lookup |
| `healr-term.el` | Terminal backend abstraction — `eat` (default) or `vterm` |
| `healr-session.el` | Session registry, lifecycle (create/kill/restart/rename/toggle) |
| `healr-status.el` | State tracking (working/idle/dead), process watchers, fleet buffer (`tabulated-list-mode`) |

### Key data flow

1. **Agent config** → `healr-agent-list` alist, normalized via `healr-agent--normalize`; `healr-project-agent-alist` maps root marker files (`mix.exs`, `build.gradle.kts`, ...) to a default agent offered by the dispatch commands
2. **Session creation** → `healr-session-create` calls `healr-term-make` to spawn a terminal buffer
3. **State tracking** → `healr-status-attach` wraps the process filter/sentinel; `prompt-regexp` matching marks idle immediately
4. **Fleet buffer** → `healr-list` displays all sessions via `tabulated-list-mode` with keys `RET`/`n`/`k`/`r`/`R`/`g`
5. **DWIM send** → `healr-send-dwim` inserts `@path` or `@path#L10-20` references at a session prompt

### Session registry

Sessions are keyed by `(root agent name)` in `healr--sessions` hash table. The `healr-session` struct (`cl-defstruct`) tracks: root, agent, name, buffer, state, last-output, timer.

### Terminal backends

- **eat** (default): calls `eat-exec` directly — no shell startup files. Wrap agents needing direnv/shims via `:command "direnv" :args ("exec" "." "cmd")`.
- **vterm**: sends `exec <cmd>` through the user's shell so startup files run. Binds `vterm-kill-buffer-on-exit` to nil so buffers survive process death for restart.

## Testing

```bash
emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit
```

Tests use `healr-test--with-fake-term` macro to stub `healr-term-make` and `executable-find`. All layers (agents, term, session, status, DWIM) have dedicated ERT suites.

## Sandbox

```bash
./sandbox.sh         # GUI Emacs with private eat install
./sandbox.sh -nw     # terminal Emacs
```

Preconfigures a `fake` agent (`test/fake-agent.sh`) — no API keys needed.

## Requirements

- Emacs 29.1+
- `eat` or `vterm` package (terminal backend)
- Agent CLIs on PATH (`claude`, `opencode`, `kimi`, etc.)

## Doom Emacs install

```elisp
;; packages.el
(package! healr :recipe (:local-repo "~/projects/healr"))

;; config.el
(use-package! healr
  :commands (healr healr-new-session healr-list healr-send-dwim))
```

## Key commands

| Command | Purpose |
|---|---|
| `M-x healr` | Pick agent, toggle its main session |
| `M-x healr-new-session` | Create named session |
| `M-x healr-list` | Fleet buffer |
| `M-x healr-send-dwim` | Send `@file` reference to session |

## Conventions

- Lexical binding: `t` in all files
- No external dependencies beyond Emacs stdlib + eat/vterm
- `healr-` prefix on all public symbols
- Hooks: `healr-session-created-hook` (used by `healr-status-attach`)
- Custom vars: `healr-agent-list`, `healr-terminal-backend`, `healr-idle-seconds`, `healr-project-root-function`, `healr-project-agent-alist`
