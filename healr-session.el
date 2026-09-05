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

(defcustom healr-session-metadata-directory
  (expand-file-name "healr/sessions/"
                    (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Directory where warm-session sidecar metadata files live."
  :type 'directory
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
  recent-output ; tail of recent terminal output (prompt-regexp window)
  timer         ; idle timer or nil
  tmux)         ; tmux session name when warm, or nil

(defun healr-session--key (root agent name)
  "Return the registry key for ROOT AGENT NAME."
  (list root agent name))

(defun healr-session--sidecar-file (tmux-name)
  "Return the sidecar file path for TMUX-NAME."
  (expand-file-name (concat tmux-name ".el")
                    healr-session-metadata-directory))

(defun healr-session--write-sidecar (tmux-name root agent name backend)
  "Write the sidecar for TMUX-NAME describing the warm session."
  (unless (file-directory-p healr-session-metadata-directory)
    (make-directory healr-session-metadata-directory t))
  (with-temp-file (healr-session--sidecar-file tmux-name)
    (prin1 (list :root root :agent agent :name name :backend backend)
           (current-buffer))))

(defun healr-session--read-sidecar (tmux-name)
  "Return the sidecar plist for TMUX-NAME, or nil when unreadable.
Content that does not read as a keyword plist counts as unreadable."
  (let ((file (healr-session--sidecar-file tmux-name)))
    (when (file-readable-p file)
      (let ((data (condition-case nil
                      (with-temp-buffer
                        (insert-file-contents file)
                        (read (current-buffer)))
                    (error nil))))
        (when (and (listp data) (keywordp (car-safe data)))
          data)))))

(defun healr-session--delete-sidecar (tmux-name)
  "Delete the sidecar for TMUX-NAME when it exists."
  (let ((file (healr-session--sidecar-file tmux-name)))
    (when (file-exists-p file)
      (delete-file file))))

(defun healr-session--live-tmux-sessions ()
  "Return the names of live tmux sessions with the `healr_' prefix."
  (seq-filter
   (lambda (name) (string-prefix-p "healr_" name))
   (split-string
    (or (healr-term--tmux-output "list-sessions" "-F" "#{session_name}")
        "")
    "\n" t)))

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
  (when (healr-session-get root (plist-get agent :name) name)
    (user-error "healr: session `%s' already exists for %s"
                name (plist-get agent :name)))
  (let* ((agent-name (plist-get agent :name))
         (persist (healr-term-persist-p agent))
         (tmux-name (and persist
                         (healr-term--tmux-name root agent-name name)))
         (backend (healr-term--resolve-backend agent))
         (buffer-name (healr-session--buffer-name-for root agent-name name))
         (buffer (if persist
                     (condition-case err
                         (progn
                           (healr-term--tmux-spawn tmux-name agent root)
                           (healr-term--tmux-attach
                            buffer-name tmux-name backend))
                       (error
                        (healr-term--tmux-run "kill-session" "-t" tmux-name)
                        (signal (car err) (cdr err))))
                   (healr-term-make buffer-name agent root)))
         (session (healr-session--create
                   :root root :agent agent-name :name name :buffer buffer
                   :state 'working :last-output (float-time)
                   :tmux tmux-name)))
    (when persist
      (healr-session--write-sidecar tmux-name root agent-name name backend))
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
    (when (string-empty-p new-name)
      (user-error "healr: session name must not be empty"))
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
    (cancel-timer timer)
    (setf (healr-session-timer session) nil))
  (when-let* ((buf (healr-session-buffer session)))
    (when (buffer-live-p buf)
      (when-let* ((proc (get-buffer-process buf)))
        (set-process-filter proc #'ignore)
        (set-process-sentinel proc #'ignore)
        (delete-process proc))
      (kill-buffer buf)))
  (when-let* ((tmux-name (healr-session-tmux session)))
    (healr-term--tmux-run "kill-session" "-t" tmux-name)
    (healr-session--delete-sidecar tmux-name))
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
         (tmux-name (healr-session-tmux session))
         (old-buffer (healr-session-buffer session)))
    (when (buffer-live-p old-buffer)
      (kill-buffer old-buffer))
    (setf (healr-session-buffer session)
          (if tmux-name
              (progn
                (healr-term--tmux-spawn tmux-name agent root)
                (healr-term--tmux-attach
                 (healr-session--buffer-name-for root agent-name name)
                 tmux-name (healr-term--resolve-backend agent)))
            (healr-term-make
             (healr-session--buffer-name-for root agent-name name)
             agent root))
          (healr-session-state session) 'working
          (healr-session-last-output session) (float-time))
    (run-hook-with-args 'healr-session-created-hook session)
    session))

(defun healr-session-toggle (session)
  "Bury SESSION's buffer when visible, reattach when `detached',
otherwise pop to it."
  (if (eq (healr-session-state session) 'detached)
      (healr-session-attach session)
    (let ((buf (healr-session-buffer session)))
      (if-let* ((win (and buf (get-buffer-window buf t))))
          (quit-window nil win)
        (pop-to-buffer buf)))))

(defun healr-session-detach (session)
  "Detach Emacs from SESSION without killing the agent.
Only warm (tmux-persisted) sessions can detach; the agent keeps
running and the process sentinel moves the session to `detached'."
  (unless (healr-session-tmux session)
    (user-error "healr: only warm (tmux) sessions can be detached"))
  (when-let* ((buf (healr-session-buffer session)))
    (when (buffer-live-p buf)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf))))
  session)

(defun healr-session-attach (session)
  "Attach a fresh terminal buffer to SESSION's live tmux session.
Runs `healr-session-created-hook' so watchers are re-wrapped, then
pops to the buffer."
  (unless (healr-session-tmux session)
    (user-error "healr: session is not warm (no tmux)"))
  (unless (healr-term--tmux-alive-p (healr-session-tmux session))
    (user-error "healr: tmux session `%s' is gone"
                (healr-session-tmux session)))
  (let* ((agent-name (healr-session-agent session))
         (agent (or (healr-agent-get agent-name)
                    (user-error "healr: agent `%s' is no longer configured"
                                agent-name)))
         (buf (healr-term--tmux-attach
               (healr-session--buffer-name-for
                (healr-session-root session) agent-name
                (healr-session-name session))
               (healr-session-tmux session)
               (healr-term--resolve-backend agent))))
    (setf (healr-session-buffer session) buf)
    (run-hook-with-args 'healr-session-created-hook session)
    (pop-to-buffer buf)
    session))

(provide 'healr-session)
;;; healr-session.el ends here
