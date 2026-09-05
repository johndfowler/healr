# healr Phase 3 — Attention Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** healr notices when an agent needs attention and says so in every buffer's modeline — with optional alerts — whether or not the agent has an Emacs buffer attached.

**Architecture:** A fifth state `blocked` joins the state machine, detected per agent via a new `:blocked-regexp` plist key matched against the terminal buffer's tail (attached) or `tmux capture-pane` (detached warm sessions, polled). A global `healr-attention-mode` minor mode shows live blocked/idle/dead counts in the modeline; transitions into `healr-attention-states` fire `healr-attention-alert-function` when the session buffer is not visible. Everything lives in `healr-status.el` plus the one new agent key.

**Tech Stack:** Emacs Lisp (29.1+), ERT, eat/vterm (optional), tmux (optional).

Spec: `docs/superpowers/specs/2026-09-05-healr-attention-design.md`

## Global Constraints

- Everything from the v1/Phase-2 plans still binds.
- All matching for `blocked` happens in the watcher, already wrapped in `condition-case` (v1.1) — a bad `:blocked-regexp` must never break the terminal filter.
- The tail window is `healr-status-tail-lines` (defcustom, default 12). Blocked clears when a later chunk's tail no longer matches — which for real TUI agents happens via screen redraws (the fake agent clears its screen on answer to model this).
- Alerts fire only on real state CHANGES, only into `healr-attention-states`, and only when the session buffer is not visible (nil buffer = not visible). They are independent of `healr-attention-mode` (mode owns modeline + poll; alerts are always-on per the defcustoms).
- Test command: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
- Suite starts at 70 tests: 76 after Task 1, 83 after Task 2, 87 after Task 3.

---

### Task 1: blocked state for attached sessions

**Files:**
- Modify: `healr-agents.el` (`:blocked-regexp` in normalize + docstring)
- Modify: `healr-status.el` (tail helper, blocked branch, mark-blocked, fleet face)
- Test: `test/healr-test.el` (append)

**Interfaces:**
- Consumes: existing watcher/struct.
- Produces:
  - `(healr-status--buffer-tail BUFFER &optional LINES) → string|nil`.
  - `(healr-status--mark-blocked SESSION)` — cancels idle timer, sets `blocked`.
  - `healr-status-tail-lines` — defcustom, default 12.
  - Agent key `:blocked-regexp` (normalized, nil default).

- [ ] **Step 1: Write the failing tests**

Append to `test/healr-test.el`:

```elisp
;;; Blocked state, attached sessions (Task 1)

(cl-defun healr-test--session-with-tail (tail-text &key (agent "claude"))
  "Return a fake session whose buffer contains TAIL-TEXT."
  (let ((session (healr-test--fake-session :agent agent)))
    (with-current-buffer (healr-session-buffer session)
      (erase-buffer)
      (insert tail-text))
    session))

(ert-deftest healr-test-status-buffer-tail ()
  (let ((buf (get-buffer-create " *healr-test-tail*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (dotimes (n 50) (insert (format "line %d\n" n)))
          (insert "tail marker"))
        (let ((tail (healr-status--buffer-tail buf 5)))
          (should (string-match-p "tail marker" tail))
          (should (string-match-p "line 49" tail))
          (should-not (string-match-p "line 40" tail)))
      (kill-buffer buf)))
  (should-not (healr-status--buffer-tail (get-buffer " *nonexistent*"))))

(ert-deftest healr-test-status-note-output-blocked-match ()
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("claude" :command "claude"
                             :blocked-regexp "Do you want to proceed")))
        (session (healr-test--session-with-tail
                  "working away\nDo you want to proceed? (y/n) ")))
    (unwind-protect
        (progn
          (healr-status--note-output session "Do you want to proceed? (y/n) ")
          (should (eq (healr-session-state session) 'blocked))
          (should-not (healr-session-timer session)))
      (when-let* ((timer (healr-session-timer session))) (cancel-timer timer))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-status-note-output-blocked-clears ()
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("claude" :command "claude"
                             :blocked-regexp "Do you want to proceed")))
        (session (healr-test--session-with-tail
                  "Do you want to proceed? (y/n) ")))
    (unwind-protect
        (progn
          (healr-status--note-output session "chunk")
          (should (eq (healr-session-state session) 'blocked))
          (with-current-buffer (healr-session-buffer session)
            (erase-buffer)
            (insert "proceeding\n> "))
          (healr-status--note-output session "proceeding\n> ")
          (should (eq (healr-session-state session) 'working)))
      (when-let* ((timer (healr-session-timer session))) (cancel-timer timer))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-status-blocked-beats-prompt-regexp ()
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("claude" :command "claude"
                             :prompt-regexp "> $"
                             :blocked-regexp "Do you want to proceed")))
        (session (healr-test--session-with-tail
                  "Do you want to proceed? (y/n) ")))
    (unwind-protect
        (progn
          (healr-status--note-output session "thinking\n> ")
          (should (eq (healr-session-state session) 'blocked)))
      (when-let* ((timer (healr-session-timer session))) (cancel-timer timer))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-status-mark-blocked-cancels-timer ()
  (let ((healr-idle-seconds 3600)
        (healr-agent-list nil)
        (session (healr-test--fake-session)))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-list--maybe-refresh) #'ignore))
          (healr-status--note-output session "x")
          (should (healr-session-timer session))
          (healr-status--mark-blocked session)
          (should (eq (healr-session-state session) 'blocked))
          (should-not (healr-session-timer session)))
      (when-let* ((timer (healr-session-timer session))) (cancel-timer timer))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-agent-normalize-blocked-regexp ()
  (let ((agent (healr-agent--normalize
                "foo" '(:blocked-regexp "proceed"))))
    (should (equal (plist-get agent :blocked-regexp) "proceed")))
  (should-not (plist-get (healr-agent--normalize "foo" nil)
                         :blocked-regexp)))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — void `healr-status--buffer-tail`, `healr-status--mark-blocked`; no `:blocked-regexp` handling.

- [ ] **Step 3: Implement**

In `healr-agents.el`, add `:blocked-regexp` to normalize and the `healr-agent-list` docstring:

```elisp
        :prompt-regexp (plist-get spec :prompt-regexp)
        :blocked-regexp (plist-get spec :blocked-regexp)
        :backend (plist-get spec :backend))
```

```elisp
;;   :prompt-regexp  optional regexp matching the agent's input prompt;
;;                   a match in terminal output marks the session idle at once
;;   :blocked-regexp optional regexp matching the agent's blocked screens
;;                   (permission prompts, y/n questions); a match in the
;;                   terminal buffer's tail marks the session blocked
```

In `healr-status.el`, add the defcustom and helper after `healr-idle-seconds`:

```elisp
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
                    (buffer-substring-no-properties (point) (point-max))))))
```

Replace `healr-status--note-output` with:

```elisp
(defun healr-status--note-output (session output)
  "Record OUTPUT arriving on SESSION's terminal.
Recent output is kept to a 500-character window.  Each chunk
re-evaluates the state: the agent's :blocked-regexp against the buffer
tail wins, then :prompt-regexp against the window (idle), otherwise
working with the idle timer re-armed."
  (setf (healr-session-last-output session) (float-time))
  (let ((window (concat (or (healr-session-recent-output session) "") output)))
    (when (> (length window) 500)
      (setq window (substring window (- (length window) 500))))
    (setf (healr-session-recent-output session) window)
    (let* ((agent (healr-agent-get (healr-session-agent session)))
           (blocked-re (and agent (plist-get agent :blocked-regexp)))
           (tail (and blocked-re
                      (healr-status--buffer-tail
                       (healr-session-buffer session)))))
      (cond
       ((and blocked-re tail (string-match-p blocked-re tail))
        (healr-status--mark-blocked session))
       ((and agent
             (plist-get agent :prompt-regexp)
             (string-match-p (plist-get agent :prompt-regexp) window))
        (healr-status--set session 'idle))
       (t
        (healr-status--set session 'working)
        (healr-status--arm-timer session))))))
```

Add `healr-status--mark-blocked` after `healr-status--mark-detached`:

```elisp
(defun healr-status--mark-blocked (session)
  "Mark SESSION blocked and stop its idle timer.
The agent is waiting on the user (permission prompt, y/n question)."
  (when-let* ((timer (healr-session-timer session)))
    (cancel-timer timer)
    (setf (healr-session-timer session) nil))
  (healr-status--set session 'blocked))
```

In `healr-list--entries`, propertize the state string when blocked:

```elisp
             (vector (file-name-nondirectory (directory-file-name root))
                     agent name
                     (if (eq state 'blocked)
                         (propertize (symbol-name state) 'face 'error)
                       (symbol-name state))
                     idle))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: `76 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add healr-agents.el healr-status.el test/healr-test.el
git commit -m "feat: blocked state for attached sessions"
```

---

### Task 2: attention mode, modeline counts, transition alerts

**Files:**
- Modify: `healr-status.el`
- Test: `test/healr-test.el` (append)

**Interfaces:**
- Consumes: `healr-status--set` (gains alert firing), registry.
- Produces:
  - `healr-attention-states` (defcustom, `'(blocked dead)`), `healr-attention-alert-function` (defcustom, `#'healr-attention--echo`), `healr-attention-poll-seconds` (defcustom, 30).
  - `(healr-attention--counts) → (B I D)` (detached counts as idle).
  - `(healr-attention--mode-line) → string` (empty when all zero; mouse-1 opens fleet).
  - `(healr-attention--maybe-alert SESSION STATE)`, `(healr-attention--echo SESSION STATE)`, `(healr-attention--system SESSION STATE)`.
  - `healr-attention-mode` (global minor mode; owns modeline entry + poll timer via `healr-attention--timer`).

- [ ] **Step 1: Write the failing tests**

Append to `test/healr-test.el`:

```elisp
;;; Attention mode and alerts (Task 2)

(defun healr-test--registry-with-states (states)
  "Bind a fresh registry holding one fake session per state in STATES."
  (let ((healr--sessions (make-hash-table :test 'equal))
        (sessions nil))
    (dolist (state states)
      (let ((session (healr-test--fake-session
                      :name (symbol-name state) :state state)))
        (puthash (healr-session--key "/tmp/proj/" "claude"
                                     (symbol-name state))
                 session healr--sessions)
        (push session sessions)))
    (list healr--sessions sessions)))

(ert-deftest healr-test-attention-counts ()
  (let* ((setup (healr-test--registry-with-states
                 '(working idle blocked dead detached)))
         (healr--sessions (car setup))
         (sessions (cadr setup)))
    (unwind-protect
        (should (equal (healr-attention--counts) '(1 2 1)))
      (mapc (lambda (s) (kill-buffer (healr-session-buffer s))) sessions))))

(ert-deftest healr-test-attention-mode-line ()
  (let* ((setup (healr-test--registry-with-states '(working)))
         (healr--sessions (car setup))
         (sessions (cadr setup)))
    (unwind-protect
        (should (equal (healr-attention--mode-line) ""))
      (mapc (lambda (s) (kill-buffer (healr-session-buffer s))) sessions)))
  (let* ((setup (healr-test--registry-with-states '(blocked idle dead)))
         (healr--sessions (car setup))
         (sessions (cadr setup)))
    (unwind-protect
        (let ((segment (healr-attention--mode-line)))
          (should (string-match-p "healr\\[" segment))
          (should (string-match-p "b:1" segment))
          (should (string-match-p "i:1" segment))
          (should (string-match-p "d:1" segment))
          (should (get-text-property 0 'local-map segment)))
      (mapc (lambda (s) (kill-buffer (healr-session-buffer s))) sessions))))

(ert-deftest healr-test-attention-alert-fires-on-listed-transition ()
  (let ((healr-attention-states '(blocked dead))
        (healr-attention-alert-function nil)
        (session (healr-test--fake-session :state 'working))
        (alerts nil))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-list--maybe-refresh) #'ignore)
                  ((symbol-function 'get-buffer-window) (lambda (&rest _) nil)))
          (setq healr-attention-alert-function
                (lambda (s state) (push (list s state) alerts)))
          (healr-status--set session 'blocked)
          (should (= (length alerts) 1))
          (healr-status--set session 'blocked)
          (should (= (length alerts) 1))
          (healr-status--set session 'idle)
          (should (= (length alerts) 1))
          (healr-status--set session 'dead)
          (should (= (length alerts) 2)))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-attention-alert-suppressed-when-visible ()
  (let ((healr-attention-states '(blocked))
        (healr-attention-alert-function nil)
        (session (healr-test--fake-session :state 'working))
        (alerts 0))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-list--maybe-refresh) #'ignore)
                  ((symbol-function 'get-buffer-window)
                   (lambda (&rest _) 'window)))
          (setq healr-attention-alert-function
                (lambda (&rest _) (setq alerts (1+ alerts))))
          (healr-status--set session 'blocked)
          (should (= alerts 0))))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-attention-alert-suppressed-for-unlisted-state ()
  (let ((healr-attention-states '(dead))
        (healr-attention-alert-function nil)
        (session (healr-test--fake-session :state 'working))
        (alerts 0))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-list--maybe-refresh) #'ignore)
                  ((symbol-function 'get-buffer-window) (lambda (&rest _) nil)))
          (setq healr-attention-alert-function
                (lambda (&rest _) (setq alerts (1+ alerts))))
          (healr-status--set session 'blocked)
          (should (= alerts 0))))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-attention-echo-format ()
  (let ((session (healr-test--fake-session :root "/tmp/alpha/")))
    (unwind-protect
        (should (equal (healr-attention--echo session 'blocked)
                       "healr: claude:main is blocked (alpha)"))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-attention-mode-toggles-modeline-and-timer ()
  (let ((global-mode-string '(""))
        (healr-attention--timer nil)
        (healr-attention-poll-seconds 30)
        (started 0) (stopped 0))
    (cl-letf (((symbol-function 'healr-attention--start-timer)
               (lambda () (setq started (1+ started))))
              ((symbol-function 'healr-attention--stop-timer)
               (lambda () (setq stopped (1+ stopped)))))
      (healr-attention-mode 1)
      (should healr-attention-mode)
      (should (member '(:eval (healr-attention--mode-line)) global-mode-string))
      (should (= started 1))
      (healr-attention-mode -1)
      (should-not healr-attention-mode)
      (should-not (member '(:eval (healr-attention--mode-line)) global-mode-string))
      (should (= stopped 1)))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — void `healr-attention--counts`, `healr-attention--mode-line`, `healr-attention-mode`, alert path absent.

- [ ] **Step 3: Implement**

In `healr-status.el`, update `healr-status--set` and add the attention section after `healr-status--mark-blocked`:

```elisp
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
  "Return the attention modeline segment, or \"\" when all counts are zero."
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
                    (format "display notification \"%s\" with title \"healr\""
                            (replace-regexp-in-string "\"" "\\\\\"" body))))
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: `83 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add healr-status.el test/healr-test.el
git commit -m "feat: attention mode, modeline counts, transition alerts"
```

---

### Task 3: detached polling via capture-pane

**Files:**
- Modify: `healr-status.el` (`healr-attention--poll`)
- Test: `test/healr-test.el` (append)

**Interfaces:**
- Consumes: `healr-term--tmux-output` (Phase 2), `healr-session-tmux`, `healr-status--set`.
- Produces: `(healr-attention--poll)` — capture-pane check of warm detached/blocked sessions.

- [ ] **Step 1: Write the failing tests**

Append to `test/healr-test.el`:

```elisp
;;; Detached polling (Task 3)

(defun healr-test--warm-detached (&key (state 'detached))
  "Return a fake warm session with no buffer."
  (healr-session--create
   :root "/tmp/proj/" :agent "fake" :name "main"
   :buffer nil :state state :last-output 0
   :tmux "healr_fake_main_aaaaaaaa"))

(ert-deftest healr-test-attention-poll-marks-blocked ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("fake" :command "fake"
                             :blocked-regexp "Do you want to proceed")))
        (session (healr-test--warm-detached)))
    (cl-letf (((symbol-function 'healr-term--tmux-output)
               (lambda (&rest _) "some output\nDo you want to proceed? (y/n) "))
              ((symbol-function 'healr-list--maybe-refresh) #'ignore))
      (puthash (healr-session--key "/tmp/proj/" "fake" "main")
               session healr--sessions)
      (healr-attention--poll)
      (should (eq (healr-session-state session) 'blocked)))))

(ert-deftest healr-test-attention-poll-clears-to-detached ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("fake" :command "fake"
                             :blocked-regexp "Do you want to proceed")))
        (session (healr-test--warm-detached :state 'blocked)))
    (cl-letf (((symbol-function 'healr-term--tmux-output)
               (lambda (&rest _) "proceeding\n> "))
              ((symbol-function 'healr-list--maybe-refresh) #'ignore))
      (puthash (healr-session--key "/tmp/proj/" "fake" "main")
               session healr--sessions)
      (healr-attention--poll)
      (should (eq (healr-session-state session) 'detached)))))

(ert-deftest healr-test-attention-poll-skips-non-detached-and-nil-pane ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("fake" :command "fake"
                             :blocked-regexp "Do you want to proceed")))
        (working (healr-test--warm-detached :state 'working))
        (detached (healr-test--warm-detached)))
    (cl-letf (((symbol-function 'healr-term--tmux-output)
               (lambda (&rest _) nil))
              ((symbol-function 'healr-list--maybe-refresh) #'ignore))
      (puthash (healr-session--key "/tmp/proj/" "fake" "main")
               working healr--sessions)
      (puthash (healr-session--key "/tmp/proj/" "fake" "work")
               detached healr--sessions)
      (setf (healr-session-name detached) "work")
      (healr-attention--poll)
      (should (eq (healr-session-state working) 'working))
      (should (eq (healr-session-state detached) 'detached)))))

(ert-deftest healr-test-attention-poll-contains-errors ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("fake" :command "fake"
                             :blocked-regexp "(")))
        (session (healr-test--warm-detached)))
    (cl-letf (((symbol-function 'healr-term--tmux-output)
               (lambda (&rest _) "anything"))
              ((symbol-function 'healr-list--maybe-refresh) #'ignore))
      (puthash (healr-session--key "/tmp/proj/" "fake" "main")
               session healr--sessions)
      (healr-attention--poll)
      (should (eq (healr-session-state session) 'detached)))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — void `healr-attention--poll`.

- [ ] **Step 3: Implement**

In `healr-status.el`, add after `healr-attention--stop-timer`:

```elisp
(defun healr-attention--poll ()
  "Check warm detached/blocked sessions for blocked screens.
Uses `tmux capture-pane' via `healr-term--tmux-output'; sessions whose
agent has no :blocked-regexp are skipped, a nil pane (no tmux, dead
session) leaves state untouched, and per-session errors are contained."
  (dolist (session (healr-session-list))
    (when (and (healr-session-tmux session)
               (memq (healr-session-state session) '(detached blocked)))
      (condition-case nil
          (let* ((agent (healr-agent-get (healr-session-agent session)))
                 (blocked-re (and agent (plist-get agent :blocked-regexp))))
            (when blocked-re
              (let ((pane (healr-term--tmux-output
                           "capture-pane" "-t"
                           (healr-session-tmux session) "-p")))
                (when pane
                  (if (string-match-p blocked-re pane)
                      (healr-status--set session 'blocked)
                    (healr-status--set session 'detached))))))
        (error nil)))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: `87 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add healr-status.el test/healr-test.el
git commit -m "feat: capture-pane poll for warm blocked detection"
```

---

### Task 4: fake agent /block, attention E2E, docs, version

**Files:**
- Modify: `test/fake-agent.sh` (`/block`), `README.md`, `AGENTS.md`, `QWEN.md`, `healr.el` (Version: 0.4.0)
- Create: `test/e2e-attention.sh`
- Test: full suite + both E2E scripts

- [ ] **Step 1: fake agent learns /block**

Replace `test/fake-agent.sh`:

```bash
#!/usr/bin/env bash
# fake-agent.sh --- Stand-in agentic CLI for the healr sandbox.
# Prints a prompt, echoes input, blocks on /block until y/n, /quit exits.
printf 'fake-agent ready\n> '
blocked=0
while IFS= read -r line; do
  if [ "$blocked" = 1 ]; then
    case "$line" in
      y|n) printf '\033[2J\033[Hproceeding\n> '; blocked=0 ;;
      *) : ;;
    esac
    continue
  fi
  case "$line" in
    /quit) printf 'bye\n'; exit 0 ;;
    /block) printf 'Do you want to proceed? (y/n) '; blocked=1 ;;
    *) printf 'you said: %s\n> ' "$line" ;;
  esac
done
```

- [ ] **Step 2: Create test/e2e-attention.sh**

```bash
#!/usr/bin/env bash
# e2e-attention.sh --- Real-tmux E2E for the attention layer.
# Attached: /block -> blocked, answer -> clears.  Detached: drive the
# tmux pane directly, poll -> blocked, answer via tmux -> detached.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EAT_DIR="${HEALR_EAT_DIR:-$HOME/.config/emacs/.local/straight/build-29.4/eat}"
COMPAT_DIR="${HEALR_COMPAT_DIR:-$HOME/.config/emacs/.local/straight/build-29.4/compat}"

tmux list-sessions -F "#{session_name}" 2>/dev/null \
  | grep "^healr_fake_main_" \
  | while read -r s; do tmux kill-session -t "$s"; done || true
rm -f "$HOME/.cache/healr/sessions/"healr_fake_main_*.el 2>/dev/null || true

LOG="$(mktemp)"
cat > "$LOG.el" <<ELISP
(require 'healr)
(setq healr-agent-list
      (list (list "fake" :command "${REPO_DIR}/test/fake-agent.sh"
                  :persist t
                  :blocked-regexp "Do you want to proceed")))
(let* ((root "${REPO_DIR}/")
       (session (healr-session-get-or-create "fake" root)))
  (sleep-for 2)
  (healr-term-send-string (healr-session-buffer session) "/block")
  (healr-term-send-return (healr-session-buffer session))
  (sleep-for 2)
  (message "E2E-ATT attached-state: %s" (healr-session-state session))
  (message "E2E-ATT attached-counts: %s" (healr-attention--counts))
  (healr-term-send-string (healr-session-buffer session) "y")
  (healr-term-send-return (healr-session-buffer session))
  (sleep-for 2)
  (message "E2E-ATT cleared-state: %s" (healr-session-state session))
  (healr-session-detach session)
  (sleep-for 1)
  (healr-term--tmux-run "send-keys" "-t" (healr-session-tmux session)
                        "/block" "Enter")
  (sleep-for 1)
  (healr-attention--poll)
  (message "E2E-ATT poll-state: %s" (healr-session-state session))
  (healr-term--tmux-run "send-keys" "-t" (healr-session-tmux session)
                        "y" "Enter")
  (sleep-for 1)
  (healr-attention--poll)
  (message "E2E-ATT poll-cleared: %s" (healr-session-state session))
  (healr-session-kill session)
  (message "E2E-ATT done: %s" (= (hash-table-count healr--sessions) 0)))
ELISP

if emacs -Q --batch -L "$COMPAT_DIR" -L "$EAT_DIR" -L "$REPO_DIR" \
     -l "$LOG.el" > "$LOG" 2>&1; then
  grep "E2E-ATT" "$LOG"
  rm -f "$LOG" "$LOG.el"
else
  cat "$LOG"
  rm -f "$LOG" "$LOG.el"
  exit 1
fi
```

Run: `chmod +x test/e2e-attention.sh`

Expected output:

```
E2E-ATT attached-state: blocked
E2E-ATT attached-counts: (1 0 0)
E2E-ATT cleared-state: working
E2E-ATT poll-state: blocked
E2E-ATT poll-cleared: detached
E2E-ATT done: t
```

- [ ] **Step 3: README — Attention section (after Warm sessions)**

```markdown
## Attention (the fleet calls you)

```elisp
(healr-attention-mode 1)
```

A modeline segment shows live counts of sessions that need you —
`healr[b:1 i:2 d:1]` — in every buffer; click it to open the fleet.
A session is `blocked` when its agent is waiting on you (permission
prompt, y/n question): teach healr the pattern per agent:

```elisp
(setq healr-agent-list
      '(("claude" :command "claude" :persist t
                  :blocked-regexp "Do you want to proceed")))
```

- Attached sessions are checked against the terminal buffer's tail on
  every output chunk; blocked clears when the screen moves on.
- Warm sessions are checked with `tmux capture-pane` every
  `healr-attention-poll-seconds` (default 30) — even with no Emacs
  buffer attached.
- Transitions into `healr-attention-states` (default `blocked` and
  `dead`) fire `healr-attention-alert-function` when the session's
  buffer isn't visible: echo-area message by default, or
  `healr-attention--system` for macOS notifications.
```

- [ ] **Step 4: AGENTS.md / QWEN.md updates**

- AGENTS.md: five states (add `blocked`); `:blocked-regexp` in the
  plist keys and its tail-matching note; `healr-attention-*` defcustoms
  in the list; attention mode + poll under the Status bullet; fleet
  keys unchanged; alerts independent of the minor mode.
- QWEN.md: states line becomes five states; short "Attention"
  subsection; custom vars += `healr-attention-states`,
  `healr-attention-alert-function`, `healr-attention-poll-seconds`,
  `healr-status-tail-lines`.

- [ ] **Step 5: healr.el version**

`;; Version: 0.3.0` → `;; Version: 0.4.0`.

- [ ] **Step 6: Run full suite + both E2E scripts**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: `87 passed, 0 failed`.
Run: `./test/e2e-warm.sh` — five E2E-WARM lines as before.
Run: `./test/e2e-attention.sh` — six E2E-ATT lines as above.

- [ ] **Step 7: Commit**

```bash
git add test/fake-agent.sh test/e2e-attention.sh README.md AGENTS.md QWEN.md healr.el
git commit -m "docs: attention layer (v0.4.0) and attention e2e"
```

---

## Self-review notes (completed by plan author)

- Spec coverage: blocked state attached (T1), attention mode + alerts (T2), detached poll (T3), fake agent + E2E + docs (T4). Every spec section maps.
- The tail window is 12 lines (`healr-status-tail-lines`), pinned here from the spec's "~40": large enough for TUI menus, small enough that redraws clear promptly. The fake agent's screen-clear on answer models real TUI redraw behavior so the E2E exercises clearing realistically.
- `healr-status--set` now also fires `healr-attention--maybe-alert`; all state transitions in the package flow through it, so no path bypasses alerts.
- Poll only touches `detached`/`blocked` warm sessions; working/idle attached sessions are covered by the output watcher; dead detection stays with rehydrate (no double-duty).
- Test counts: 70 → 76 (T1) → 83 (T2) → 87 (T3).
