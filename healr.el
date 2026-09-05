;;; healr.el --- Fleet layer for agentic CLI tools  -*- lexical-binding: t; -*-

;; Author: healr contributors
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes
;; URL: https://github.com/johndfowler/healr

;;; Commentary:

;; healr runs and supervises multiple agentic CLI tools (Claude Code,
;; opencode, Kimi, ...) in terminal buffers.  Each (project, agent,
;; session) triple gets its own terminal buffer; a fleet buffer shows
;; every session's state (working / idle / dead) at a glance.
;;
;;   M-x healr              ; pick an agent, toggle its main session
;;   M-x healr-new-session  ; create a named session
;;   M-x healr-list         ; fleet buffer
;;   M-x healr-send-dwim    ; send @file / @file#L10-20 to a session

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'healr-agents)
(require 'healr-term)
(require 'healr-session)
(require 'healr-status)

(add-hook 'healr-session-created-hook #'healr-status-attach)

(defcustom healr-project-agent-alist
  '(("mix.exs" . "elixir")
    ("build.gradle.kts" . "kotlin")
    ("build.gradle" . "kotlin"))
  "Alist of (MARKER-FILE . AGENT-NAME) for project-aware agent defaults.
When the project root contains MARKER-FILE and AGENT-NAME is configured
in `healr-agent-list', `M-x healr' and `M-x healr-new-session' offer
that agent as the default."
  :type '(alist :key-type (string :tag "Marker file")
                :value-type (string :tag "Agent name"))
  :group 'healr)

(defun healr--default-agent (root)
  "Return the default agent name for ROOT per `healr-project-agent-alist'.
Only markers present at ROOT whose agent is configured in
`healr-agent-list' count; nil when nothing matches."
  (cl-some (lambda (entry)
             (and (file-exists-p (expand-file-name (car entry) root))
                  (member (cdr entry) (healr-agent-names))
                  (cdr entry)))
           healr-project-agent-alist))

;;;###autoload
(defun healr (agent)
  "Open or toggle AGENT's main session in the current project."
  (interactive
   (let ((default (healr--default-agent (funcall healr-project-root-function))))
     (list (completing-read
            (if default (format "Agent (%s): " default) "Agent: ")
            (healr-agent-names) nil t nil nil default))))
  (healr-rehydrate)
  (healr-session-toggle
   (healr-session-get-or-create agent (funcall healr-project-root-function))))

;;;###autoload
(defun healr-new-session (agent name)
  "Create a new session NAME for AGENT in the current project."
  (interactive
   (let ((default (healr--default-agent (funcall healr-project-root-function))))
     (list (completing-read
            (if default (format "Agent (%s): " default) "Agent: ")
            (healr-agent-names) nil t nil nil default)
           (read-string "Session name: "))))
  (when (string-empty-p name)
    (user-error "healr: session name must not be empty"))
  (healr-rehydrate)
  (let ((root (funcall healr-project-root-function)))
    (when (healr-session-get root agent name)
      (user-error "healr: session `%s' already exists for %s" name agent))
    (pop-to-buffer
     (healr-session-buffer
      (healr-session-create
       (or (healr-agent-get agent)
           (user-error "healr: unknown agent `%s'" agent))
       root name)))))

(defun healr--dwim-reference (file root &optional start-line end-line)
  "Return the @-reference for FILE relative to ROOT, with #L lines if given."
  (concat "@" (file-relative-name file root)
          (when start-line
            (if (and end-line (> end-line start-line))
                (format "#L%d-%d" start-line end-line)
              (format "#L%d" start-line)))))

(defun healr--read-session (sessions)
  "Pick one session from SESSIONS with completion."
  (let* ((choices (mapcar (lambda (session)
                            (cons (format "%s:%s"
                                          (healr-session-agent session)
                                          (healr-session-name session))
                                  session))
                          sessions))
         (picked (completing-read "Session: " choices nil t)))
    (cdr (assoc picked choices))))

;;;###autoload
(defun healr-send-dwim ()
  "Send an @-reference to the current file or region to a session.
The reference is inserted at the session's prompt without submitting.
With one live session in the project, target it directly; with several,
ask which."
  (interactive)
  (unless buffer-file-name
    (user-error "healr: current buffer is not visiting a file"))
  (let* ((root (funcall healr-project-root-function))
         (sessions (seq-filter
                    (lambda (session)
                      (and (healr-session-live-p session)
                           (healr-term-alive-p
                            (healr-session-buffer session))))
                    (healr-session-list root))))
    (unless sessions
      (user-error "healr: no live session in this project — M-x healr first"))
    (let* ((session (if (= 1 (length sessions))
                        (car sessions)
                      (healr--read-session sessions)))
           (start-line (when (use-region-p)
                         (line-number-at-pos (region-beginning))))
           (end-line (when (use-region-p)
                       (line-number-at-pos
                        (max (region-beginning) (1- (region-end))))))
           (reference (healr--dwim-reference
                       buffer-file-name (healr-session-root session)
                       start-line end-line))
           (buffer (healr-session-buffer session)))
      (healr-term-send-string buffer (concat reference " "))
      (pop-to-buffer buffer))))

(provide 'healr)
;;; healr.el ends here
