#!/usr/bin/env bash
# sandbox.sh --- Try healr in a throwaway `emacs -Q' session.
#
#   ./sandbox.sh         # GUI Emacs (terminals need a real frame)
#   ./sandbox.sh -nw     # terminal Emacs in this terminal
#
# Uses a private package dir (eat is installed there, not in your config)
# and a sample git project.  The fleet is preconfigured with a fake agent
# (test/fake-agent.sh) so no API keys are needed.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="${REPO_DIR}/.sandbox"
PKG_DIR="${SANDBOX_DIR}/elpa"
PROJECT_DIR="${SANDBOX_DIR}/sample-project"

mkdir -p "${PKG_DIR}" "${PROJECT_DIR}"

if [ ! -d "${PROJECT_DIR}/.git" ]; then
  git -C "${PROJECT_DIR}" init -q
  printf '# sample-project\n' > "${PROJECT_DIR}/README.md"
fi

cat > "${SANDBOX_DIR}/init.el" <<INIT
(setq package-user-dir "${PKG_DIR}"
      package-archives '(("gnu" . "https://elpa.gnu.org/packages/")))
(require 'package)
(package-initialize)
(unless (require 'eat nil t)
  (package-refresh-contents)
  (package-install 'eat))
(add-to-list 'load-path "${REPO_DIR}")
(require 'healr)
(setq healr-agent-list
      (append (list (list "fake" :command "${REPO_DIR}/test/fake-agent.sh"))
              healr-agent-list))
(setq default-directory "${PROJECT_DIR}/")
(message "healr sandbox: M-x healr / healr-list / healr-send-dwim")
INIT

EMACS_ARGS=(-Q -l "${SANDBOX_DIR}/init.el")
if [ "${1:-}" = "-nw" ]; then
  EMACS_ARGS+=(-nw)
fi

exec emacs "${EMACS_ARGS[@]}"
