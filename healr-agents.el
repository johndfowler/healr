;;; healr-agents.el --- Agent definitions for healr  -*- lexical-binding: t; -*-

;;; Code:

(require 'subr-x)

(defgroup healr nil
  "Fleet layer for agentic CLI tools."
  :group 'tools
  :prefix "healr-")

(defcustom healr-agent-list
  '(("claude"   :command "claude")
    ("opencode" :command "opencode")
    ("kimi"     :command "kimi"))
  "Alist of agent NAME -> plist describing how to run that agent.
Plist keys:
  :command        executable name (defaults to NAME)
  :args           list of extra command-line arguments
  :env            alist of (NAME . VALUE) extra environment variables
  :prompt-regexp  optional regexp matching the agent's input prompt;
                  a match in terminal output marks the session idle at once
  :blocked-regexp optional regexp matching the agent's blocked screens
                  (permission prompts, y/n questions); a match in the
                  terminal buffer's tail marks the session blocked
  :backend        optional `eat' or `vterm', overriding
                  `healr-terminal-backend'"
  :type '(alist :key-type (string :tag "Name")
                :value-type (plist :tag "Spec"))
  :group 'healr)

(defun healr-agent--normalize (name spec)
  "Return the full agent plist for NAME from alist entry SPEC.
:persist is included only when SPEC sets it, so
`healr-persist-default' can apply otherwise."
  (append (list :name name
                :command (or (plist-get spec :command) name)
                :args (plist-get spec :args)
                :env (plist-get spec :env)
                :prompt-regexp (plist-get spec :prompt-regexp)
                :blocked-regexp (plist-get spec :blocked-regexp)
                :backend (plist-get spec :backend))
          (when (plist-member spec :persist)
            (list :persist (plist-get spec :persist)))))

(defun healr-agent-get (name)
  "Return the normalized agent plist for NAME, or nil if not configured."
  (when-let* ((spec (assoc name healr-agent-list)))
    (healr-agent--normalize name (cdr spec))))

(defun healr-agent-names ()
  "Return the names of all configured agents."
  (mapcar #'car healr-agent-list))

(provide 'healr-agents)
;;; healr-agents.el ends here
