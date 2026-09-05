<p align="center">
  <img src="assets/logo.png" alt="healr logo — a temple before a banded seventies sunset, prompt in the pediment" width="160">
</p>
<h1 align="center">healr</h1>

A fleet layer for agentic CLI tools in Emacs — the child of herdr,
Doom Emacs, and codersauce/red. healr herds your agent fleet the way
`red` keeps a session warm per project: every agent, every project,
one glance away.

Run and supervise Claude Code, opencode, Kimi and friends in terminal
buffers — each (project, agent, session) triple gets its own buffer,
and a fleet buffer shows every session's state (working / idle / dead).

## Requirements

- Emacs 29.1+
- [eat](https://codeberg.org/akib/emacs-eat) (default terminal backend)
  or [vterm](https://github.com/akermu/emacs-libvterm)
- whichever agent CLIs you actually use (`claude`, `opencode`, `kimi`, ...)

## Install (Doom Emacs)

```elisp
;; packages.el
(package! healr :recipe (:host github :repo "johndfowler/healr"))
;; or from a local checkout:
;; (package! healr :recipe (:local-repo "~/projects/healr"))

;; config.el
(use-package! healr
  :commands (healr healr-new-session healr-list healr-send-dwim))
```

## Usage

- `M-x healr` — pick an agent, toggle its `main` session in this project
- `M-x healr-new-session` — create a named session (several per agent OK)
- `M-x healr-list` — fleet buffer: `RET` jump, `n` new, `k` kill,
  `r` restart (dead only), `R` rename, `g` refresh
- `M-x healr-send-dwim` — from a file buffer, insert `@path` (or
  `@path#L10-20` with a region) at a session's prompt, without submitting

## Configuring agents

```elisp
(setq healr-agent-list
      '(("claude"   :command "claude")
        ("opencode" :command "opencode" :backend vterm)
        ("wrapped"  :command "direnv" :args ("exec" "." "claude"))
        ("kimi"     :command "kimi" :prompt-regexp "^❯ ")))
```

Plist keys: `:command` (defaults to the name), `:args`, `:env`,
`:prompt-regexp` (a match in output marks the session idle immediately),
`:backend` (`eat` or `vterm`, overriding `healr-terminal-backend`).

Note: the eat backend execs the agent directly, without shell startup
files.  If an agent needs direnv or a version manager's shims, wrap it
as in the `wrapped` example above (or see below).

## Language workflows

Some ecosystems want environment setup before the agent starts — `mise`
or `asdf` for Erlang/Elixir, SDKMAN/JAVA_HOME for Kotlin.  Wrap the
agent in your env manager:

```elisp
(setq healr-agent-list
      '(("claude"   :command "claude")
        ;; Elixir: project .envrc / .tool-versions via direnv
        ("elixir"   :command "direnv" :args ("exec" "." "claude"))
        ;; Kotlin: SDKMAN init, then exec
        ("kotlin"   :command "sh"
         :args ("-c" ". \"$HOME/.sdkman/bin/sdkman-init.sh\"; exec claude"))))
```

(The vterm backend runs shell startup files anyway, so unwrapped agents
usually work there too.)

With `healr-project-agent-alist`, `M-x healr` and `M-x healr-new-session`
offer the matching agent as the default when the project root contains
the marker file:

```elisp
;; default value
(("mix.exs" . "elixir")
 ("build.gradle.kts" . "kotlin")
 ("build.gradle" . "kotlin"))
```

A mapping only applies when the agent is also in `healr-agent-list`, so
the defaults cost nothing where they are unused.

## Warm sessions (persistence)

Give an agent `:persist t` and it runs inside a detached tmux session:
it keeps running when you kill its buffer or quit Emacs, and the fleet
finds it again when you come back.

```elisp
(setq healr-agent-list
      '(("claude" :command "claude" :persist t)))
```

- Killing a warm session's buffer **detaches** instead of destroying —
  the fleet shows the session as `detached` and `RET` reattaches with
  the tmux scrollback intact.
- `M-x healr` on a detached `main` session reattaches instead of
  spawning a duplicate.
- Fleet buffer `d` detaches; `k` still kills (tmux session included).
- Agent exit with nothing attached shows as `dead` at the next
  rehydrate; `r` respawns it under the same tmux name.
- Requires `tmux` on PATH — only for `:persist` agents; everything
  else works without it.

Rehydration runs on `M-x healr`, `M-x healr-new-session`, and whenever
the fleet buffer opens or refreshes; `M-x healr-rehydrate` does it on
demand.  Sidecar metadata lives in `healr-session-metadata-directory`
(default `~/.cache/healr/sessions/`).  Set `healr-persist-default` to
make persistence the default for every agent.

## Attention (the fleet calls you)

```elisp
(healr-attention-mode 1)
```

A modeline segment shows live counts of sessions that need you —
`healr[b:1 i:2 d:1]` — in every buffer; click it to open the fleet.
A session is `blocked` when its agent is waiting on you (permission
prompt, y/n question): teach healr the pattern per agent:

```elisp
(setq healr-agent-list
      '(("claude" :command "claude" :persist t
                  :blocked-regexp "Do you want to proceed")))
```

- Attached sessions are checked on every render; warm sessions
  (attached or not) are checked with `tmux capture-pane` — every
  render when attached, every `healr-attention-poll-seconds`
  (default 30) when detached.
- Transitions into `healr-attention-states` (default `blocked` and
  `dead`) fire `healr-attention-alert-function` when the session's
  buffer isn't visible: echo-area message by default, or
  `healr-attention--system` for macOS notifications.
- Blocked clears when the screen moves on (for real TUI agents, when
  the prompt redraws away).

## Testing

```bash
emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit
```

`./sandbox.sh` launches a throwaway `emacs -Q` with eat installed into a
private package dir and a fake agent (no API keys needed).
