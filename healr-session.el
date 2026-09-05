;;; healr-session.el --- Session registry for healr  -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'healr-agents)
(require 'healr-term)

(defcustom healr-project-root-function #'healr-session--default-root
  "Function returning the directory new sessions are scoped to."
  :type 'function
  :group 'healr)

(defvar healr-session-created-hook nil
  "Hook run with the session after a session is created or restarted.
`healr-status' uses it to attach process watchers.")

(defvar healr--sessions (make-hash-table :test 'equal)
  "Hash of session key -> `healr-session' struct.")

(cl-defstruct (healr-session (:constructor healr-session--create))
  "A running or dead agent session."
  root          ; absolute project directory
  agent         ; agent name string
  name          ; session name string
  buffer        ; terminal buffer
  state         ; `working', `idle' or `dead'
  last-output   ; float time of last terminal output
  timer)        ; idle timer or nil

(defun healr-session--key (root agent name)
  "Return the registry key for ROOT AGENT NAME."
  (list root agent name))

(defun healr-session--default-root ()
  "Return the current project root, or `default-directory'."
  (if-let* ((project (project-current nil)))
      (project-root project)
    default-directory))

(defun healr-session-buffer-name (root agent name)
  "Return the canonical buffer name for ROOT AGENT NAME."
  (format "*healr:%s:%s:%s*"
          (file-name-nondirectory (directory-file-name root))
          agent name))

(defun healr-session--owner-root (buffer)
  "Return the root of the session owning BUFFER, or nil."
  (catch 'found
    (maphash (lambda (_key session)
               (when (eq (healr-session-buffer session) buffer)
                 (throw 'found (healr-session-root session))))
             healr--sessions)
    nil))

(defun healr-session--buffer-name-for (root agent name)
  "Return a buffer name for ROOT AGENT NAME, disambiguated on collision.
When the canonical name is taken by a buffer not owned by a session of
ROOT, append an 8-character hash of ROOT to the project component."
  (let ((plain (healr-session-buffer-name root agent name)))
    (if (and (get-buffer plain)
             (not (equal (healr-session--owner-root (get-buffer plain)) root)))
        (format "*healr:%s-%s:%s:%s*"
                (file-name-nondirectory (directory-file-name root))
                (substring (secure-hash 'sha1 root) 0 8)
                agent name)
      plain)))

(defun healr-session-get (root agent name)
  "Return the session for ROOT AGENT NAME, or nil."
  (gethash (healr-session--key root agent name) healr--sessions))

(defun healr-session-list (&optional root)
  "Return all sessions, or only those under ROOT."
  (let (sessions)
    (maphash (lambda (_key session)
               (when (or (null root)
                         (equal (healr-session-root session) root))
                 (push session sessions)))
             healr--sessions)
    (nreverse sessions)))

(defun healr-session-live-p (session)
  "Return non-nil when SESSION is not dead."
  (not (eq (healr-session-state session) 'dead)))

(defun healr-session-create (agent root name)
  "Create and register a session running AGENT plist at ROOT named NAME.
Signals `user-error' when the agent's command is not on PATH."
  (unless (executable-find (plist-get agent :command))
    (user-error "healr: `%s' not found on PATH (agent `%s')"
                (plist-get agent :command) (plist-get agent :name)))
  (let* ((agent-name (plist-get agent :name))
         (buffer (healr-term-make
                  (healr-session--buffer-name-for root agent-name name)
                  agent root))
         (session (healr-session--create
                   :root root :agent agent-name :name name :buffer buffer
                   :state 'working :last-output (float-time))))
    (puthash (healr-session--key root agent-name name) session healr--sessions)
    (run-hook-with-args 'healr-session-created-hook session)
    session))

(defun healr-session-get-or-create (agent-name root &optional name)
  "Return the session for AGENT-NAME ROOT NAME, creating it if needed.
NAME defaults to \"main\"."
  (or name (setq name "main"))
  (or (healr-session-get root agent-name name)
      (healr-session-create
       (or (healr-agent-get agent-name)
           (user-error "healr: unknown agent `%s'" agent-name))
       root name)))

(defun healr-session-rename (session new-name)
  "Rename SESSION to NEW-NAME."
  (let ((root (healr-session-root session))
        (agent (healr-session-agent session)))
    (when (healr-session-get root agent new-name)
      (user-error "healr: session `%s' already exists for %s" new-name agent))
    (remhash (healr-session--key root agent (healr-session-name session))
             healr--sessions)
    (setf (healr-session-name session) new-name)
    (puthash (healr-session--key root agent new-name) session healr--sessions)
    (let ((buf (healr-session-buffer session)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (rename-buffer
           (healr-session--buffer-name-for root agent new-name)))))
    session))

(defun healr-session-kill (session)
  "Kill SESSION's process and buffer and remove it from the registry."
  (when-let* ((timer (healr-session-timer session)))
    (cancel-timer timer))
  (when-let* ((buf (healr-session-buffer session)))
    (when (buffer-live-p buf)
      (when-let* ((proc (get-buffer-process buf)))
        (delete-process proc))
      (kill-buffer buf)))
  (remhash (healr-session--key (healr-session-root session)
                               (healr-session-agent session)
                               (healr-session-name session))
           healr--sessions)
  nil)

(defun healr-session-restart (session)
  "Re-run SESSION's agent in a fresh buffer.  Only dead sessions restart."
  (unless (eq (healr-session-state session) 'dead)
    (user-error "healr: only dead sessions can be restarted"))
  (let* ((agent-name (healr-session-agent session))
         (agent (or (healr-agent-get agent-name)
                    (user-error "healr: agent `%s' is no longer configured"
                                agent-name)))
         (root (healr-session-root session))
         (name (healr-session-name session))
         (old-buffer (healr-session-buffer session)))
    (when (buffer-live-p old-buffer)
      (kill-buffer old-buffer))
    (setf (healr-session-buffer session)
          (healr-term-make
           (healr-session--buffer-name-for root agent-name name)
           agent root)
          (healr-session-state session) 'working
          (healr-session-last-output session) (float-time))
    (run-hook-with-args 'healr-session-created-hook session)
    session))

(defun healr-session-toggle (session)
  "Bury SESSION's buffer when it is visible, otherwise pop to it."
  (let ((buf (healr-session-buffer session)))
    (if-let* ((win (get-buffer-window buf t)))
        (quit-window nil win)
      (pop-to-buffer buf))))

(provide 'healr-session)
;;; healr-session.el ends here
