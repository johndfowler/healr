;;; healr-status.el --- Session status tracking for healr  -*- lexical-binding: t; -*-

;;; Code:

(require 'subr-x)
(require 'tabulated-list)
(require 'healr-agents)
(require 'healr-session)

(declare-function healr-new-session "healr")

(defcustom healr-idle-seconds 5
  "Seconds of terminal silence after which a working session turns idle."
  :type 'number
  :group 'healr)

(defvar-local healr--buffer-session nil
  "The `healr-session' struct this buffer belongs to.")

;;; State changes

(defun healr-status--set (session state)
  "Set SESSION's state to STATE, refreshing the fleet buffer on change."
  (unless (eq (healr-session-state session) state)
    (setf (healr-session-state session) state)
    (healr-list--maybe-refresh)))

(defun healr-status--arm-timer (session)
  "(Re)arm SESSION's idle timer."
  (when-let* ((timer (healr-session-timer session)))
    (cancel-timer timer))
  (setf (healr-session-timer session)
        (run-at-time healr-idle-seconds nil #'healr-status--idle-check
                     session)))

(defun healr-status--idle-check (session)
  "Mark SESSION idle when silent for more than `healr-idle-seconds'."
  (when (and (eq (healr-session-state session) 'working)
             (> (- (float-time) (or (healr-session-last-output session) 0))
                healr-idle-seconds))
    (healr-status--set session 'idle)))

(defun healr-status--note-output (session output)
  "Record OUTPUT arriving on SESSION's terminal.
Recent output is kept to a 500-character window; when the agent's
:prompt-regexp matches the window the session goes idle immediately
\(matching the window, not just this chunk, so prompts split across
reads still match).  Otherwise the session is working and the idle
timer re-arms."
  (setf (healr-session-last-output session) (float-time))
  (let ((window (concat (or (healr-session-recent-output session) "") output)))
    (when (> (length window) 500)
      (setq window (substring window (- (length window) 500))))
    (setf (healr-session-recent-output session) window)
    (let ((agent (healr-agent-get (healr-session-agent session))))
      (if (and agent
               (plist-get agent :prompt-regexp)
               (string-match-p (plist-get agent :prompt-regexp) window))
          (healr-status--set session 'idle)
        (healr-status--set session 'working)
        (healr-status--arm-timer session)))))

(defun healr-status--mark-dead (session)
  "Mark SESSION dead and stop its idle timer."
  (when-let* ((timer (healr-session-timer session)))
    (cancel-timer timer)
    (setf (healr-session-timer session) nil))
  (healr-status--set session 'dead))

(defun healr-status--mark-detached (session)
  "Mark SESSION detached and stop its idle timer.
The agent keeps running inside tmux; no Emacs buffer is attached."
  (when-let* ((timer (healr-session-timer session)))
    (cancel-timer timer)
    (setf (healr-session-timer session) nil))
  (healr-status--set session 'detached))

;;; Process watching

(defun healr-status--wrap-process (session proc)
  "Chain SESSION's status watcher onto PROC's filter and sentinel."
  (let ((orig-filter (process-filter proc))
        (orig-sentinel (process-sentinel proc)))
    (set-process-filter
     proc
     (lambda (process output)
       (condition-case nil
           (healr-status--note-output session output)
         (error nil))
       (if orig-filter
           (funcall orig-filter process output)
         (internal-default-process-filter process output))))
    (set-process-sentinel
     proc
     (lambda (process event)
       (when orig-sentinel
         (ignore-errors (funcall orig-sentinel process event)))
       (unless (process-live-p process)
         (if-let* ((tmux-name (healr-session-tmux session)))
             (let ((current (and (buffer-live-p (healr-session-buffer session))
                                 (get-buffer-process
                                  (healr-session-buffer session)))))
               (when (or (not current) (eq process current))
                 (if (healr-term--tmux-alive-p tmux-name)
                     (healr-status--mark-detached session)
                   (healr-status--mark-dead session))))
           (when (eq (process-buffer process)
                     (healr-session-buffer session))
             (healr-status--mark-dead session))))))))

(defun healr-status-attach (session)
  "Attach status tracking to SESSION; also used after restarts.
Sets the state to working, watches the terminal process, and installs
the modeline segment.  Suitable for `healr-session-created-hook'."
  (let ((buf (healr-session-buffer session)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq healr--buffer-session session
              mode-line-process '((:eval (healr-status--mode-line)))))
      (if-let* ((proc (get-buffer-process buf)))
          (progn
            (setf (healr-session-state session) 'working
                  (healr-session-last-output session) (float-time)
                  (healr-session-recent-output session) nil)
            (healr-status--wrap-process session proc)
            (healr-status--arm-timer session))
        (healr-status--mark-dead session)))))

(defun healr-status--mode-line ()
  "Return the modeline segment for the current healr session buffer."
  (when-let* ((session healr--buffer-session))
    (format " [%s:%s]" (healr-session-agent session)
            (healr-session-state session))))

;;; Rehydration

(defun healr-rehydrate ()
  "Rebuild the registry from live tmux sessions and sidecar metadata.
Live `healr_*' tmux sessions with a readable sidecar and no registry
entry are added as `detached' (no buffer).  Registry entries already
`detached' whose tmux session has vanished become `dead'."
  (interactive)
  (let ((live (healr-session--live-tmux-sessions)))
    (dolist (tmux-name live)
      (let ((meta (healr-session--read-sidecar tmux-name)))
        (when (and meta
                   (not (healr-session-get (plist-get meta :root)
                                           (plist-get meta :agent)
                                           (plist-get meta :name))))
          (puthash (healr-session--key (plist-get meta :root)
                                       (plist-get meta :agent)
                                       (plist-get meta :name))
                   (healr-session--create
                    :root (plist-get meta :root)
                    :agent (plist-get meta :agent)
                    :name (plist-get meta :name)
                    :buffer nil
                    :state 'detached
                    :last-output (float-time)
                    :tmux tmux-name)
                   healr--sessions))))
    (dolist (session (healr-session-list))
      (when (and (eq (healr-session-state session) 'detached)
                 (healr-session-tmux session)
                 (not (member (healr-session-tmux session) live)))
        (healr-status--set session 'dead)))
    (healr-session-list)))

;;; Fleet buffer

(defconst healr-list-buffer-name "*healr fleet*"
  "Name of the healr fleet buffer.")

(defun healr-list--entries ()
  "Return tabulated-list entries for all sessions."
  (mapcar
   (lambda (session)
     (let* ((root (healr-session-root session))
            (agent (healr-session-agent session))
            (name (healr-session-name session))
            (state (healr-session-state session))
            (idle (if (eq state 'dead)
                      "—"
                    (format "%ds"
                            (max 0 (round
                                    (- (float-time)
                                       (or (healr-session-last-output session)
                                           (float-time)))))))))
       (list (healr-session--key root agent name)
             (vector (file-name-nondirectory (directory-file-name root))
                     agent name (symbol-name state) idle))))
   (healr-session-list)))

(defun healr-list--maybe-refresh ()
  "Recompute the fleet buffer when it exists."
  (when-let* ((buf (get-buffer healr-list-buffer-name)))
    (with-current-buffer buf
      (tabulated-list-print t))))

(defun healr-list--session-at-point ()
  "Return the session for the fleet buffer line at point, or nil."
  (when-let* ((key (tabulated-list-get-id)))
    (apply #'healr-session-get key)))

(define-derived-mode healr-list-mode tabulated-list-mode "healr"
  "Major mode for the healr fleet buffer."
  (setq tabulated-list-format [("Project" 18 t) ("Agent" 10 t)
                               ("Session" 12 t) ("State" 8 t)
                               ("Idle" 6 nil)]
        tabulated-list-entries #'healr-list--entries
        tabulated-list-padding 2)
  (tabulated-list-init-header))

(keymap-set healr-list-mode-map "RET" #'healr-list-jump)
(keymap-set healr-list-mode-map "n" #'healr-list-new)
(keymap-set healr-list-mode-map "k" #'healr-list-kill)
(keymap-set healr-list-mode-map "r" #'healr-list-restart)
(keymap-set healr-list-mode-map "R" #'healr-list-rename)
(keymap-set healr-list-mode-map "g" #'healr-list-refresh)
(keymap-set healr-list-mode-map "d" #'healr-list-detach)

(defun healr-list-refresh ()
  "Recompute the fleet buffer, rehydrating from tmux first."
  (interactive nil healr-list-mode)
  (healr-rehydrate)
  (tabulated-list-print t))

(defun healr-list-detach ()
  "Detach the warm session at point; the agent keeps running."
  (interactive nil healr-list-mode)
  (when-let* ((session (healr-list--session-at-point)))
    (healr-session-detach session)
    (healr-list-refresh)))

(defun healr-list-jump ()
  "Pop to the session at point."
  (interactive nil healr-list-mode)
  (when-let* ((session (healr-list--session-at-point)))
    (pop-to-buffer (healr-session-buffer session))))

(defun healr-list-new ()
  "Create a new session, prompting for agent and name."
  (interactive nil healr-list-mode)
  (call-interactively #'healr-new-session)
  (healr-list-refresh))

(defun healr-list-kill ()
  "Kill the session at point, after confirmation."
  (interactive nil healr-list-mode)
  (when-let* ((session (healr-list--session-at-point)))
    (when (y-or-n-p (format "Kill %s:%s? "
                            (healr-session-agent session)
                            (healr-session-name session)))
      (healr-session-kill session)
      (healr-list-refresh))))

(defun healr-list-restart ()
  "Restart the dead session at point."
  (interactive nil healr-list-mode)
  (when-let* ((session (healr-list--session-at-point)))
    (healr-session-restart session)
    (healr-list-refresh)))

(defun healr-list-rename ()
  "Rename the session at point."
  (interactive nil healr-list-mode)
  (when-let* ((session (healr-list--session-at-point)))
    (healr-session-rename session (read-string "New name: "))
    (healr-list-refresh)))

;;;###autoload
(defun healr-list ()
  "Display the healr fleet buffer."
  (interactive)
  (healr-rehydrate)
  (let ((buf (get-buffer-create healr-list-buffer-name)))
    (with-current-buffer buf
      (healr-list-mode)
      (tabulated-list-print))
    (pop-to-buffer buf)))

(provide 'healr-status)
;;; healr-status.el ends here
