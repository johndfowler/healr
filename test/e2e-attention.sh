#!/usr/bin/env bash
# e2e-attention.sh --- Real-tmux E2E for the attention layer.
# Attached: /block -> blocked, answer -> clears.  Detached: drive the
# tmux pane directly, poll -> blocked, answer via tmux -> detached.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EAT_DIR="${HEALR_EAT_DIR:-$HOME/.config/emacs/.local/straight/build-29.4/eat}"
COMPAT_DIR="${HEALR_COMPAT_DIR:-$HOME/.config/emacs/.local/straight/build-29.4/compat}"

tmux list-sessions -F "#{session_name}" 2>/dev/null \
  | grep "^healr_fake_main_" \
  | while read -r s; do tmux kill-session -t "$s"; done || true
rm -f "$HOME/.cache/healr/sessions/"healr_fake_main_*.el 2>/dev/null || true

LOG="$(mktemp)"
cat > "$LOG.el" <<ELISP
(require 'healr)
(setq healr-agent-list
      (list (list "fake" :command "${REPO_DIR}/test/fake-agent.sh"
                  :persist t
                  :blocked-regexp "Do you want to proceed")))
(let* ((root "${REPO_DIR}/")
       (session (healr-session-get-or-create "fake" root)))
  (sleep-for 2)
  (healr-term-send-string (healr-session-buffer session) "/block")
  (healr-term-send-return (healr-session-buffer session))
  (sleep-for 2)
  (message "E2E-ATT attached-state: %s" (healr-session-state session))
  (message "E2E-ATT attached-counts: %s" (healr-attention--counts))
  (healr-term-send-string (healr-session-buffer session) "y")
  (healr-term-send-return (healr-session-buffer session))
  (sleep-for 2)
  (message "E2E-ATT cleared-state: %s" (healr-session-state session))
  (healr-session-detach session)
  (sleep-for 1)
  (healr-term--tmux-run "send-keys" "-t" (healr-session-tmux session)
                        "/block" "Enter")
  (sleep-for 1)
  (healr-attention--poll)
  (message "E2E-ATT poll-state: %s" (healr-session-state session))
  (healr-term--tmux-run "send-keys" "-t" (healr-session-tmux session)
                        "y" "Enter")
  (sleep-for 1)
  (healr-attention--poll)
  (message "E2E-ATT poll-cleared: %s" (healr-session-state session))
  (healr-session-kill session)
  (message "E2E-ATT done: %s" (= (hash-table-count healr--sessions) 0)))
ELISP

if emacs -Q --batch -L "$COMPAT_DIR" -L "$EAT_DIR" -L "$REPO_DIR" \
     -l "$LOG.el" > "$LOG" 2>&1; then
  grep "E2E-ATT" "$LOG"
  rm -f "$LOG" "$LOG.el"
else
  cat "$LOG"
  rm -f "$LOG" "$LOG.el"
  exit 1
fi
