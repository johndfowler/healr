;;; healr-term.el --- Terminal backend for healr  -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar eat-terminal)             ; buffer-local in eat buffers
(declare-function eat-mode "eat")
(declare-function eat-exec "eat")
(declare-function eat-term-send-string "eat")
(defvar vterm-kill-buffer-on-exit)
(declare-function vterm-mode "vterm")
(declare-function vterm-send-string "vterm")
(declare-function vterm-send-return "vterm")

(defcustom healr-terminal-backend 'eat
  "Terminal backend used to run agent processes.
Either `eat' (the default) or `vterm'.  An agent plist's :backend
overrides this per agent."
  :type '(choice (const eat) (const vterm))
  :group 'healr)

(defvar-local healr-term--backend nil
  "The backend symbol (`eat' or `vterm') running in this buffer.")

(defun healr-term--process-env (env)
  "Return `process-environment' with alist ENV of (NAME . VALUE) prepended."
  (append (mapcar (lambda (kv) (concat (car kv) "=" (cdr kv))) env)
          process-environment))

(defun healr-term--resolve-backend (agent)
  "Return the backend symbol for AGENT plist."
  (or (plist-get agent :backend) healr-terminal-backend))

(defun healr-term-make (buffer-name agent directory)
  "Create a terminal buffer BUFFER-NAME running AGENT in DIRECTORY.
AGENT is a normalized agent plist (see `healr-agent-get').  Returns the
buffer without displaying it; `healr-term--backend' is set buffer-locally."
  (let* ((backend (healr-term--resolve-backend agent))
         (default-directory directory)
         (process-environment
          (healr-term--process-env (plist-get agent :env)))
         (buf (pcase backend
                ('eat (healr-term--make-eat buffer-name
                                            (plist-get agent :command)
                                            (plist-get agent :args)))
                ('vterm (healr-term--make-vterm buffer-name
                                                (plist-get agent :command)
                                                (plist-get agent :args)))
                (_ (user-error "healr: unknown terminal backend `%s'"
                               backend)))))
    (with-current-buffer buf
      (setq healr-term--backend backend))
    buf))

(defun healr-term--make-eat (buffer-name command args)
  "Create an eat terminal BUFFER-NAME running COMMAND with ARGS."
  (unless (require 'eat nil t)
    (user-error "healr: `eat' backend needs the eat package installed"))
  (let ((buf (get-buffer-create buffer-name)))
    (with-current-buffer buf
      (eat-mode)
      (eat-exec buf buffer-name command nil args))
    buf))

(defun healr-term--make-vterm (buffer-name command args)
  "Create a vterm terminal BUFFER-NAME running COMMAND with ARGS.
Starts the user's shell and `exec's the command, so shell startup files
\(PATH, direnv, version managers) run first.  `vterm-kill-buffer-on-exit'
is bound to nil so the buffer survives the agent for `healr-session-restart'."
  (unless (require 'vterm nil t)
    (user-error "healr: `vterm' backend needs the vterm package installed"))
  (let ((buf (get-buffer-create buffer-name))
        (vterm-kill-buffer-on-exit nil))
    (with-current-buffer buf
      (vterm-mode)
      (vterm-send-string
       (concat "exec "
               (mapconcat #'shell-quote-argument (cons command args) " ")))
      (vterm-send-return))
    buf))

(defun healr-term-send-string (buffer string)
  "Send STRING to the terminal in BUFFER, with no trailing newline."
  (with-current-buffer buffer
    (pcase healr-term--backend
      ('eat (eat-term-send-string eat-terminal string))
      ('vterm (vterm-send-string string))
      (other (user-error "healr: unknown terminal backend `%s'" other)))))

(defun healr-term-send-return (buffer)
  "Send a return keypress to the terminal in BUFFER."
  (with-current-buffer buffer
    (pcase healr-term--backend
      ('eat (eat-term-send-string eat-terminal "\r"))
      ('vterm (vterm-send-return))
      (other (user-error "healr: unknown terminal backend `%s'" other)))))

(defun healr-term-alive-p (buffer)
  "Return non-nil when BUFFER has a live terminal process."
  (and (buffer-live-p buffer)
       (process-live-p (get-buffer-process buffer))))

;;; tmux persistence (warm sessions)

(defcustom healr-persist-default nil
  "When non-nil, agents run inside detached tmux sessions by default.
An agent plist's :persist overrides this per agent."
  :type 'boolean
  :group 'healr)

(defun healr-term-persist-p (agent)
  "Return non-nil when AGENT plist runs warm (tmux-persisted)."
  (if (plist-member agent :persist)
      (plist-get agent :persist)
    healr-persist-default))

(defun healr-term--tmux-run (&rest args)
  "Run tmux with ARGS and return the exit code.
Returns 1 when tmux is not installed.  This wrapper and
`healr-term--tmux-output' carry every tmux shell-out, so tests stub
only them."
  (if (executable-find "tmux")
      (apply #'call-process "tmux" nil nil nil args)
    1))

(defun healr-term--tmux-output (&rest args)
  "Run tmux with ARGS; return trimmed stdout, or nil on failure.
Returns nil when tmux is not installed."
  (when (executable-find "tmux")
    (let ((buf (generate-new-buffer " *healr-tmux*")))
      (unwind-protect
          (when (zerop (apply #'call-process "tmux" nil buf nil args))
            (with-current-buffer buf
              (string-trim
               (buffer-substring-no-properties (point-min) (point-max)))))
        (kill-buffer buf)))))

(defun healr-term--tmux-name (root agent name)
  "Return the deterministic tmux session name for ROOT AGENT NAME."
  (let ((sanitize (lambda (s) (replace-regexp-in-string "[^a-zA-Z0-9_-]" "-" s))))
    (format "healr_%s_%s_%s"
            (funcall sanitize agent)
            (funcall sanitize name)
            (substring (secure-hash 'sha1 root) 0 8))))

(defun healr-term--tmux-alive-p (tmux-name)
  "Return non-nil when tmux session TMUX-NAME exists."
  (zerop (healr-term--tmux-run "has-session" "-t" tmux-name)))

(defun healr-term--tmux-spawn (tmux-name agent directory)
  "Create a detached tmux session TMUX-NAME running AGENT in DIRECTORY.
AGENT is a normalized agent plist.  The session ends when the agent
exits (no `remain-on-exit'), so `healr-term--tmux-alive-p' is a
truthful liveness check.  Signals `user-error' when tmux is missing
or the session cannot be created."
  (unless (executable-find "tmux")
    (user-error "healr: `tmux' is required for persistent sessions"))
  (let ((argv (append (list "new-session" "-d" "-s" tmux-name "-c" directory)
                      (cl-mapcan (lambda (kv)
                                   (list "-e" (concat (car kv) "=" (cdr kv))))
                                 (plist-get agent :env))
                      (list "--" (plist-get agent :command))
                      (plist-get agent :args))))
    (unless (zerop (apply #'healr-term--tmux-run argv))
      (user-error "healr: tmux could not create session `%s'" tmux-name))
    (healr-term--tmux-run "set-option" "-t" tmux-name "status" "off")
    (healr-term--tmux-run "set-option" "-t" tmux-name "history-limit" "50000")
    tmux-name))

(defun healr-term--tmux-attach (buffer-name tmux-name backend)
  "Create a terminal buffer BUFFER-NAME attached to TMUX-NAME via BACKEND.
BACKEND is `eat' or `vterm' — the terminal used for the client view."
  (let ((buf (pcase backend
               ('eat (healr-term--make-eat
                      buffer-name "tmux" (list "attach-session" "-t" tmux-name)))
               ('vterm (healr-term--make-vterm
                        buffer-name "tmux" (list "attach-session" "-t" tmux-name)))
               (_ (user-error "healr: unknown terminal backend `%s'" backend)))))
    (with-current-buffer buf
      (setq healr-term--backend backend))
    buf))

(provide 'healr-term)
;;; healr-term.el ends here
