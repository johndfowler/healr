;;; healr-term.el --- Terminal backend for healr  -*- lexical-binding: t; -*-

;;; Code:

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

(provide 'healr-term)
;;; healr-term.el ends here
