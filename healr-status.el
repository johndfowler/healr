;;; healr-status.el --- Session status tracking for healr  -*- lexical-binding: t; -*-

;;; Code:

(require 'subr-x)
(require 'tabulated-list)
(require 'healr-agents)
(require 'healr-session)

(declare-function healr-new-session "healr")
(defvar eat-update-hook)             ; from eat, run after each render batch

(defcustom healr-idle-seconds 5
  "Seconds of terminal silence after which a working session turns idle."
  :type 'number
  :group 'healr)

(defcustom healr-status-tail-lines 12
  "Lines of terminal-buffer tail matched against agents' :blocked-regexp."
  :type 'number
  :group 'healr)

(defun healr-status--buffer-tail (buffer &optional lines)
  "Return the last LINES of BUFFER as a string, or nil when it is dead.
LINES defaults to `healr-status-tail-lines'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-max))
          (forward-line (- (or lines healr-status-tail-lines)))
                    (buffer-substring-no-properties (point) (point-max)))))))

(defvar-local healr--buffer-session nil
  "The `healr-session' struct this buffer belongs to.")

;;; State changes

(defun healr-status--set (session state)
  "Set SESSION's state to STATE.
Refreshes the fleet buffer and fires the attention alert on
qualifying transitions (see `healr-attention-states')."
  (unless (eq (healr-session-state session) state)
    (setf (healr-session-state session) state)
    (healr-list--maybe-refresh)
    (healr-attention--maybe-alert session state)))

;;; Attention layer

(defcustom healr-attention-states '(blocked dead)
  "Session states whose transitions fire `healr-attention-alert-function'."
  :type '(repeat symbol)
  :group 'healr)

(defcustom healr-attention-alert-function #'healr-attention--echo
  "Function called with (SESSION STATE) on attention transitions.
`healr-attention--echo' and `healr-attention--system' are provided;
nil disables alerts."
  :type '(choice (const :tag "Echo area" healr-attention--echo)
                 (const :tag "System notification" healr-attention--system)
                 (const :tag "Off" nil)
                 function)
  :group 'healr)

(defcustom healr-attention-poll-seconds 30
  "Seconds between capture-pane polls of warm sessions for blocked screens."
  :type 'number
  :group 'healr)

(defun healr-attention--counts ()
  "Return (BLOCKED IDLE DEAD) counts over the registry.
`detached' sessions count as idle."
  (let ((blocked 0) (idle 0) (dead 0))
    (dolist (session (healr-session-list))
      (pcase (healr-session-state session)
        ('blocked (setq blocked (1+ blocked)))
        ((or 'idle 'detached) (setq idle (1+ idle)))
        ('dead (setq dead (1+ dead)))))
    (list blocked idle dead)))

(defvar healr-attention--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'healr-list)
    map)
  "Keymap for the healr attention modeline segment.")

(defun healr-attention--mode-line ()
  "Return the attention modeline segment, or "" when all counts are zero."
  (pcase-let ((`(,blocked ,idle ,dead) (healr-attention--counts)))
    (if (zerop (+ blocked idle dead))
        ""
      (propertize
       (concat " healr["
               (when (> blocked 0)
                 (propertize (format "b:%d" blocked) 'face 'error))
               (when (> idle 0)
                 (format "%si:%d" (if (> blocked 0) " " "") idle))
               (when (> dead 0)
                 (propertize (format "%sd:%d" (if (> (+ blocked idle) 0) " " "")
                              dead)
                             'face 'warning))
               "]")
       'local-map healr-attention--mode-line-map
       'mouse-face 'mode-line-highlight
       'help-echo "healr fleet (click)"))))

(defun healr-attention--maybe-alert (session state)
  "Fire `healr-attention-alert-function' for SESSION entering STATE.
Only for states in `healr-attention-states' and only when SESSION's
buffer is not visible in any window (nil buffer counts as invisible)."
  (when (and (memq state healr-attention-states)
             healr-attention-alert-function
             (let ((buf (healr-session-buffer session)))
               (not (and buf
                         (buffer-live-p buf)
                         (get-buffer-window buf t)))))
    (condition-case nil
        (funcall healr-attention-alert-function session state)
      (error nil))))

(defun healr-attention--echo (session state)
  "Echo an attention message for SESSION entering STATE."
  (message "healr: %s:%s is %s (%s)"
           (healr-session-agent session)
           (healr-session-name session)
           state
           (file-name-nondirectory
            (directory-file-name (healr-session-root session)))))

(defun healr-attention--system (session state)
  "System notification for SESSION entering STATE; echoes as fallback."
  (let ((body (format "%s:%s is %s"
                      (healr-session-agent session)
                      (healr-session-name session)
                      state)))
    (cond
     ((executable-find "osascript")
      (call-process "osascript" nil nil nil "-e"
                    (format "display notification "%s" with title "healr""
                            (replace-regexp-in-string """ "\\"" body))))
     ((fboundp 'notifications-notify)
      (notifications-notify :title "healr" :body body))
     (t
      (healr-attention--echo session state)))))

(defvar healr-attention--timer nil
  "The capture-pane poll timer, or nil.")

(defun healr-attention--start-timer ()
  "Start the poll timer per `healr-attention-poll-seconds'."
  (unless healr-attention--timer
    (setq healr-attention--timer
          (run-at-time healr-attention-poll-seconds
                       healr-attention-poll-seconds
                       #'healr-attention--poll))))

(defun healr-attention--stop-timer ()
  "Stop the poll timer."
  (when healr-attention--timer
    (cancel-timer healr-attention--timer)
    (setq healr-attention--timer nil)))

(defun healr-attention--poll ()
  "Check warm detached/blocked sessions for blocked screens.
Delegates to `healr-status--evaluate-blocked' (which reads the screen
via `tmux capture-pane' for warm sessions); a blocked session whose
screen cleared is set back to `detached' here rather than working."
  (dolist (session (healr-session-list))
    (when (and (healr-session-tmux session)
               (memq (healr-session-state session) '(detached blocked)))
      (condition-case nil
          (let ((was-blocked (eq (healr-session-state session) 'blocked)))
            (healr-status--evaluate-blocked session)
            (when (and was-blocked
                       (eq (healr-session-state session) 'working))
              (healr-status--set session 'detached)))
        (error nil)))))

;;;###autoload
(define-minor-mode healr-attention-mode
  "Global minor mode showing healr attention counts in the modeline.
Also runs the warm-session blocked poll (see `healr-attention--poll')."
  :global t
  :group 'healr
  (let ((entry '(:eval (healr-attention--mode-line))))
    (if healr-attention-mode
        (progn
          (unless (listp global-mode-string)
            (setq global-mode-string (list global-mode-string)))
          (unless (member entry global-mode-string)
            (setq global-mode-string
                  (append global-mode-string (list entry))))
          (healr-attention--start-timer))
      (when (listp global-mode-string)
        (setq global-mode-string (remove entry global-mode-string)))
      (healr-attention--stop-timer))))

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

(defun healr-status--evaluate-blocked (session)
  "Evaluate SESSION's blocked state from what's on its screen.
Warm (tmux) sessions read the screen via `tmux capture-pane' — tmux
owns the terminal there, so the buffer's tail is unreliable — and
other sessions read the terminal buffer's tail.  Must run only when
the screen is freshly rendered (see `eat-update-hook' and the vterm
filter path).  A match of the agent's :blocked-regexp marks blocked;
a blocked session whose screen no longer matches goes back to working."
  (when (memq (healr-session-state session) '(working idle blocked detached))
    (let* ((agent (healr-agent-get (healr-session-agent session)))
           (blocked-re (and agent (plist-get agent :blocked-regexp))))
      (when blocked-re
        (let ((content
               (if-let* ((tmux-name (healr-session-tmux session)))
                   (healr-term--tmux-output "capture-pane" "-t" tmux-name "-p")
                 (healr-status--buffer-tail
                  (healr-session-buffer session)))))
          (when content
            (cond
             ((string-match-p blocked-re content)
              (healr-status--mark-blocked session))
             ((eq (healr-session-state session) 'blocked)
              (healr-status--set session 'working)
              (healr-status--arm-timer session)))))))))

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

(defun healr-status--mark-blocked (session)
  "Mark SESSION blocked and stop its idle timer.
The agent is waiting on the user (permission prompt, y/n question)."
  (when-let* ((timer (healr-session-timer session)))
    (cancel-timer timer)
    (setf (healr-session-timer session) nil))
  (healr-status--set session 'blocked))

;;; Process watching

(defun healr-status--wrap-process (session proc backend)
  "Chain SESSION's status watcher onto PROC's filter and sentinel.
BACKEND is the session buffer's terminal backend (`eat' or `vterm'):
vterm renders inside its filter, so the blocked evaluation can run
right after it; eat renders from a queue and is evaluated from
`eat-update-hook' instead (see `healr-status-attach')."
  (let ((orig-filter (process-filter proc))
        (orig-sentinel (process-sentinel proc)))
    (set-process-filter
     proc
     (lambda (process output)
       (if orig-filter
           (funcall orig-filter process output)
         (internal-default-process-filter process output))
       (condition-case nil
           (progn
             (healr-status--note-output session output)
             (when (eq backend 'vterm)
               (healr-status--evaluate-blocked session)))
         (error nil))))
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
          (let ((backend (buffer-local-value 'healr-term--backend buf)))
            (setf (healr-session-state session) 'working
                  (healr-session-last-output session) (float-time)
                  (healr-session-recent-output session) nil)
            (when (eq backend 'eat)
              (with-current-buffer buf
                (add-hook 'eat-update-hook
                          (lambda ()
                            (healr-status--evaluate-blocked session))
                          nil t)))
            (healr-status--wrap-process session proc backend)
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
                     agent name
                     (if (eq state 'blocked)
                         (propertize (symbol-name state) 'face 'error)
                       (symbol-name state))
                     idle))))
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
