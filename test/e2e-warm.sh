#!/usr/bin/env bash
# e2e-warm.sh --- Real-tmux E2E for warm sessions (no API keys needed).
# Spawns the fake agent warm, detaches, simulates an Emacs restart
# (clears the registry), rehydrates, reattaches, pings.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EAT_DIR="${HEALR_EAT_DIR:-$HOME/.config/emacs/.local/straight/build-29.4/eat}"
COMPAT_DIR="${HEALR_COMPAT_DIR:-$HOME/.config/emacs/.local/straight/build-29.4/compat}"

# Idempotent: clear leftovers of previous (failed) runs of this script.
tmux list-sessions -F "#{session_name}" 2>/dev/null \
  | grep "^healr_fake_main_" \
  | while read -r s; do tmux kill-session -t "$s"; done || true
rm -f "$HOME/.cache/healr/sessions/"healr_fake_main_*.el 2>/dev/null || true

LOG="$(mktemp)"
cat > "$LOG.el" <<ELISP
(require 'healr)
(setq healr-agent-list
      (list (list "fake" :command "${REPO_DIR}/test/fake-agent.sh"
                  :persist t)))
(let* ((root "${REPO_DIR}/")
       (session (healr-session-get-or-create "fake" root)))
  (sleep-for 2)
  (message "E2E-WARM tmux-alive: %s"
           (healr-term--tmux-alive-p (healr-session-tmux session)))
  (healr-session-detach session)
  (sleep-for 1)
  (message "E2E-WARM state-after-detach: %s"
           (healr-session-state session))
  (clrhash healr--sessions)
  (healr-rehydrate)
  (let ((s (healr-session-get root "fake" "main")))
    (message "E2E-WARM rehydrated-state: %s"
             (and s (healr-session-state s)))
    (healr-session-attach s)
    (sleep-for 2)
    (healr-term-send-string (healr-session-buffer s) "warm ping")
    (healr-term-send-return (healr-session-buffer s))
    (sleep-for 2)
    (with-current-buffer (healr-session-buffer s)
      (message "E2E-WARM echo: %s"
               (if (save-excursion (goto-char (point-min))
                                   (search-forward "you said: warm ping" nil t))
                   "YES" "NO")))
    (healr-session-kill s)
    (message "E2E-WARM tmux-gone: %s"
             (not (healr-term--tmux-alive-p (healr-session-tmux s))))))
ELISP

if emacs -Q --batch -L "$COMPAT_DIR" -L "$EAT_DIR" -L "$REPO_DIR" \
     -l "$LOG.el" > "$LOG" 2>&1; then
  grep "E2E-WARM" "$LOG"
  rm -f "$LOG" "$LOG.el"
else
  cat "$LOG"
  rm -f "$LOG" "$LOG.el"
  exit 1
fi
