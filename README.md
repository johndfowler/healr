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
as in the `wrapped` example above.

## Testing

```bash
emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit
```

`./sandbox.sh` launches a throwaway `emacs -Q` with eat installed into a
private package dir and a fake agent (no API keys needed).
