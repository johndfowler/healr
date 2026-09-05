# healr Phase 2 — Warm Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make healr sessions warm — agents keep running inside tmux when Emacs or the terminal buffer goes away, and the fleet reassembles on return.

**Architecture:** Persistence is a per-agent `:persist` opt-in layered over the existing eat/vterm backends. The agent runs in a detached tmux session (`healr_<agent>_<name>_<hash8>`); the terminal buffer runs a tmux client attaching to it. A fourth session state `detached` (tmux alive, no Emacs buffer) joins working/idle/dead. Sidecar elisp files in `~/.cache/healr/sessions/` drive rehydration. All tmux shell-outs go through two stubbable wrappers.

**Tech Stack:** Emacs Lisp (29.1+), ERT, eat/vterm (optional), tmux (optional; required only when `:persist` is used).

Spec: `docs/superpowers/specs/2026-09-05-healr-warm-sessions-design.md`

## Global Constraints

- Everything from the v1 plan still binds: lexical-binding headers, `healr-`/`healr--` prefixes, no global keys, no hard requires of eat/vterm, `user-error` with `healr: ` prefix, `executable-find` checks at launch.
- tmux is OPTIONAL: all tmux calls go through `healr-term--tmux-run` / `healr-term--tmux-output`, which must degrade quietly (exit 1 / nil) when tmux is absent. Loud failure only at explicit persist spawn (`healr-term--tmux-spawn`).
- Non-persist sessions keep v1 behavior exactly.
- Test command: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
- Suite starts at 45 tests: 52 after Task 1, 61 after Task 2, 69 after Task 3.

---

### Task 1: tmux primitives + :persist plumbing

**Files:**
- Modify: `healr-agents.el` (normalize passes :persist through, unset by default)
- Modify: `healr-term.el` (tmux wrappers + spawn/attach)
- Test: `test/healr-test.el` (append; also patch the two normalize tests)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `(healr-term-persist-p AGENT) → boolean` — agent :persist, else `healr-persist-default`.
  - `(healr-term--tmux-run &rest ARGS) → exit-code` — the only exit-code tmux wrapper; returns 1 when tmux is absent.
  - `(healr-term--tmux-output &rest ARGS) → trimmed-stdout|nil` — nil on failure or missing tmux.
  - `(healr-term--tmux-name ROOT AGENT NAME) → "healr_<agent>_<name>_<hash8>"` sanitized.
  - `(healr-term--tmux-alive-p TMUX-NAME) → boolean`.
  - `(healr-term--tmux-spawn TMUX-NAME AGENT DIRECTORY)` — user-error when tmux missing or spawn fails.
  - `(healr-term--tmux-attach BUFFER-NAME TMUX-NAME BACKEND) → buffer` — tags `healr-term--backend`.

- [ ] **Step 1: Patch the two existing normalize tests and write the failing Task 1 tests**

In `test/healr-test.el`, replace `healr-test-agent-normalize-defaults` and `healr-test-agent-normalize-explicit` with:

```elisp
(ert-deftest healr-test-agent-normalize-defaults ()
  (let ((agent (healr-agent--normalize "foo" nil)))
    (should (equal (plist-get agent :name) "foo"))
    (should (equal (plist-get agent :command) "foo"))
    (should-not (plist-get agent :args))
    (should-not (plist-get agent :env))
    (should-not (plist-get agent :prompt-regexp))
    (should-not (plist-get agent :backend))
    (should-not (plist-member agent :persist))))

(ert-deftest healr-test-agent-normalize-explicit ()
  (let ((agent (healr-agent--normalize
                "foo" '(:command "bar" :args ("--baz") :env (("A" . "1"))
                        :prompt-regexp "> " :backend vterm :persist t))))
    (should (equal (plist-get agent :command) "bar"))
    (should (equal (plist-get agent :args) '("--baz")))
    (should (equal (plist-get agent :env) '(("A" . "1"))))
    (should (equal (plist-get agent :prompt-regexp) "> "))
    (should (eq (plist-get agent :backend) 'vterm))
    (should (eq (plist-get agent :persist) t))))
```

Append the new tests before `;;; healr-test.el ends here`:

```elisp
;;; tmux primitives (Task 1, warm sessions)

(ert-deftest healr-test-term-persist-p ()
  (let ((healr-persist-default nil))
    (should-not (healr-term-persist-p '(:name "a")))
    (should (healr-term-persist-p '(:name "a" :persist t)))
    (should-not (healr-term-persist-p '(:name "a" :persist nil))))
  (let ((healr-persist-default t))
    (should (healr-term-persist-p '(:name "a")))
    (should-not (healr-term-persist-p '(:name "a" :persist nil)))))

(ert-deftest healr-test-term-tmux-name ()
  (should (string-match-p
           "\\`healr_claude_main_[0-9a-f]\\{8\\}\\'"
           (healr-term--tmux-name "/tmp/proj/" "claude" "main")))
  (should (string-match-p
           "\\`healr_my-agent_work-1_[0-9a-f]\\{8\\}\\'"
           (healr-term--tmux-name "/tmp/proj/" "my agent" "work 1")))
  (should (equal (healr-term--tmux-name "/tmp/proj/" "claude" "main")
                 (healr-term--tmux-name "/tmp/proj/" "claude" "main")))
  (should-not (equal (healr-term--tmux-name "/a/proj/" "claude" "main")
                     (healr-term--tmux-name "/b/proj/" "claude" "main"))))

(ert-deftest healr-test-term-tmux-alive-p ()
  (cl-letf (((symbol-function 'healr-term--tmux-run)
             (lambda (&rest _) 0)))
    (should (healr-term--tmux-alive-p "healr_x_y_00000000")))
  (cl-letf (((symbol-function 'healr-term--tmux-run)
             (lambda (&rest _) 1)))
    (should-not (healr-term--tmux-alive-p "healr_x_y_00000000"))))

(ert-deftest healr-test-term-tmux-spawn-argv ()
  (let (calls)
    (cl-letf (((symbol-function 'healr-term--tmux-run)
               (lambda (&rest args) (push args calls) 0))
              ((symbol-function 'executable-find)
               (lambda (_cmd &optional _remote) "/usr/bin/tmux")))
      (healr-term--tmux-spawn
       "healr_fake_main_aaaaaaaa"
       (healr-agent--normalize "fake" '(:command "fake" :args ("-x")
                                        :env (("A" . "1")) :persist t))
       "/tmp/proj/")
      (setq calls (nreverse calls))
      (let ((spawn (car calls)))
        (should (equal (car spawn) "new-session"))
        (should (member "-d" spawn))
        (should (member "healr_fake_main_aaaaaaaa" spawn))
        (should (member "/tmp/proj/" spawn))
        (should (member "-e" spawn))
        (should (member "A=1" spawn))
        (should (member "--" spawn))
        (should (member "fake" spawn))
        (should (member "-x" spawn)))
      (should (= (length (seq-filter (lambda (c) (equal (car c) "set-option"))
                                     calls))
                 2)))))

(ert-deftest healr-test-term-tmux-spawn-errors ()
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_cmd &optional _remote) nil)))
    (should-error
     (healr-term--tmux-spawn "healr_x_y_aaaaaaaa" '(:name "x" :command "x") "/tmp/")
     :type 'user-error))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_cmd &optional _remote) "/usr/bin/tmux"))
            ((symbol-function 'healr-term--tmux-run)
             (lambda (&rest _) 1)))
    (should-error
     (healr-term--tmux-spawn "healr_x_y_aaaaaaaa" '(:name "x" :command "x") "/tmp/")
     :type 'user-error)))

(ert-deftest healr-test-term-tmux-attach ()
  (let (made)
    (cl-letf (((symbol-function 'healr-term--make-eat)
               (lambda (bn cmd args)
                 (setq made (list bn cmd args))
                 (get-buffer-create bn))))
      (unwind-protect
          (let ((buf (healr-term--tmux-attach "*healr-test-attach*"
                                              "healr_x_y_aaaaaaaa" 'eat)))
            (should (equal (car made) "*healr-test-attach*"))
            (should (equal (nth 1 made) "tmux"))
            (should (equal (nth 2 made)
                           (list "attach-session" "-t" "healr_x_y_aaaaaaaa")))
            (should (eq (buffer-local-value 'healr-term--backend buf) 'eat)))
        (when-let* ((buf (get-buffer "*healr-test-attach*")))
          (kill-buffer buf))))))

(ert-deftest healr-test-term-tmux-absent-degrades ()
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_cmd &optional _remote) nil)))
    (should (= (healr-term--tmux-run "has-session" "-t" "x") 1))
    (should-not (healr-term--tmux-output "list-sessions"))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — void functions `healr-term-persist-p`, `healr-term--tmux-*`; normalize tests fail on `:persist` expectations.

- [ ] **Step 3: Implement**

In `healr-agents.el`, replace `healr-agent--normalize` (keep the rest of the file):

```elisp
(defun healr-agent--normalize (name spec)
  "Return the full agent plist for NAME from alist entry SPEC.
:persist is included only when SPEC sets it, so
`healr-persist-default' can apply otherwise."
  (append (list :name name
                :command (or (plist-get spec :command) name)
                :args (plist-get spec :args)
                :env (plist-get spec :env)
                :prompt-regexp (plist-get spec :prompt-regexp)
                :backend (plist-get spec :backend))
          (when (plist-member spec :persist)
            (list :persist (plist-get spec :persist)))))
```

In `healr-term.el`, add `cl-lib` to the requires and append (before the `(provide 'healr-term)` line):

```elisp
(require 'cl-lib)
```

```elisp
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: `52 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add healr-agents.el healr-term.el test/healr-test.el
git commit -m "feat: tmux primitives and :persist plumbing"
```

---

### Task 2: warm session lifecycle (sidecars, struct, create/kill/restart/detach/attach)

**Files:**
- Modify: `healr-session.el`
- Test: `test/healr-test.el` (append)

**Interfaces:**
- Consumes: `healr-term-persist-p`, `healr-term--tmux-name/spawn/attach/alive-p` (Task 1).
- Produces:
  - `healr-session` struct new field `tmux` (tmux session name or nil).
  - `healr-session-metadata-directory` — defcustom, default `~/.cache/healr/sessions/`.
  - `(healr-session--sidecar-file TMUX-NAME)`, `(healr-session--write-sidecar TMUX-NAME ROOT AGENT NAME BACKEND)`, `(healr-session--read-sidecar TMUX-NAME) → plist|nil`, `(healr-session--delete-sidecar TMUX-NAME)`.
  - `(healr-session--live-tmux-sessions) → list of names` (via `healr-term--tmux-output`).
  - `(healr-session-detach SESSION)` — kill attachment buffer only; user-error for non-warm sessions.
  - `(healr-session-attach SESSION)` — fresh buffer on a live tmux session; runs `healr-session-created-hook`; pops to it.
  - create/kill/restart/toggle updated for warm sessions.

- [ ] **Step 1: Write the failing tests**

Append to `test/healr-test.el`:

```elisp
;;; Warm session lifecycle (Task 2)

(defmacro healr-test--with-temp-metadata (&rest body)
  "Run BODY with a temp `healr-session-metadata-directory'."
  (declare (indent 0))
  `(let ((healr-session-metadata-directory
          (make-temp-file "healr-meta" t)))
     (unwind-protect
         (progn ,@body)
       (delete-directory healr-session-metadata-directory t))))

(ert-deftest healr-test-session-sidecar-roundtrip ()
  (healr-test--with-temp-metadata
    (healr-session--write-sidecar "healr_a_b_aaaaaaaa"
                                  "/tmp/proj/" "claude" "main" 'eat)
    (let ((meta (healr-session--read-sidecar "healr_a_b_aaaaaaaa")))
      (should (equal (plist-get meta :root) "/tmp/proj/"))
      (should (equal (plist-get meta :agent) "claude"))
      (should (equal (plist-get meta :name) "main"))
      (should (eq (plist-get meta :backend) 'eat)))
    (healr-session--delete-sidecar "healr_a_b_aaaaaaaa")
    (should-not (healr-session--read-sidecar "healr_a_b_aaaaaaaa"))))

(ert-deftest healr-test-session-sidecar-read-garbage ()
  (healr-test--with-temp-metadata
    (with-temp-file (healr-session--sidecar-file "healr_bad")
      (insert "not a plist ((("))
    (should-not (healr-session--read-sidecar "healr_bad"))))

(ert-deftest healr-test-session-live-tmux-sessions ()
  (cl-letf (((symbol-function 'healr-term--tmux-output)
             (lambda (&rest _)
               "healr_a_main_aaaaaaaa\nother_session\nhealr_b_work_bbbbbbbb")))
    (should (equal (healr-session--live-tmux-sessions)
                   '("healr_a_main_aaaaaaaa" "healr_b_work_bbbbbbbb"))))
  (cl-letf (((symbol-function 'healr-term--tmux-output)
             (lambda (&rest _) nil)))
    (should-not (healr-session--live-tmux-sessions))))

(ert-deftest healr-test-session-create-warm ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("fake" :command "fake" :persist t)))
        spawned attached sidecars)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_cmd &optional _remote) "/usr/bin/true"))
              ((symbol-function 'healr-term--tmux-spawn)
               (lambda (tmux-name _agent _dir)
                 (push tmux-name spawned) tmux-name))
              ((symbol-function 'healr-term--tmux-attach)
               (lambda (buffer-name _tmux _backend)
                 (push buffer-name attached)
                 (get-buffer-create buffer-name)))
              ((symbol-function 'healr-session--write-sidecar)
               (lambda (&rest args) (push args sidecars))))
      (unwind-protect
          (let ((session (healr-session-get-or-create "fake" "/tmp/proj/")))
            (should (= (length spawned) 1))
            (should (equal (healr-session-tmux session) (car spawned)))
            (should (= (length attached) 1))
            (should (= (length sidecars) 1))
            (should (healr-session-buffer session)))
        (mapc #'healr-session-kill (healr-session-list))))))

(ert-deftest healr-test-session-kill-warm ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("fake" :command "fake" :persist t)))
        tmux-killed sidecar-deleted)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_cmd &optional _remote) "/usr/bin/true"))
              ((symbol-function 'healr-term--tmux-spawn)
               (lambda (tmux-name &rest _) tmux-name))
              ((symbol-function 'healr-term--tmux-attach)
               (lambda (bn &rest _) (get-buffer-create bn)))
              ((symbol-function 'healr-session--write-sidecar) #'ignore)
              ((symbol-function 'healr-term--tmux-run)
               (lambda (&rest args)
                 (when (equal (car args) "kill-session")
                   (setq tmux-killed (nth 2 args)))
                 0))
              ((symbol-function 'healr-session--delete-sidecar)
               (lambda (tmux-name) (setq sidecar-deleted tmux-name))))
      (let* ((session (healr-session-get-or-create "fake" "/tmp/proj/"))
             (tmux-name (healr-session-tmux session)))
        (healr-session-kill session)
        (should (equal tmux-killed tmux-name))
        (should (equal sidecar-deleted tmux-name))
        (should-not (healr-session-get "/tmp/proj/" "fake" "main"))
        (should (= (hash-table-count healr--sessions) 0))))))

(ert-deftest healr-test-session-restart-warm ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("fake" :command "fake" :persist t)))
        (spawns 0))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_cmd &optional _remote) "/usr/bin/true"))
              ((symbol-function 'healr-term--tmux-spawn)
               (lambda (tmux-name &rest _) (setq spawns (1+ spawns)) tmux-name))
              ((symbol-function 'healr-term--tmux-attach)
               (lambda (bn &rest _) (get-buffer-create bn)))
              ((symbol-function 'healr-session--write-sidecar) #'ignore)
              ((symbol-function 'healr-term--tmux-run) (lambda (&rest _) 0))
              ((symbol-function 'healr-session--delete-sidecar) #'ignore))
      (unwind-protect
          (let ((session (healr-session-get-or-create "fake" "/tmp/proj/")))
            (setf (healr-session-state session) 'dead)
            (healr-session-restart session)
            (should (= spawns 2))
            (should (eq (healr-session-state session) 'working)))
        (mapc #'healr-session-kill (healr-session-list))))))

(ert-deftest healr-test-session-detach ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("fake" :command "fake" :persist t)
                            ("cold" :command "cold"))))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_cmd &optional _remote) "/usr/bin/true"))
              ((symbol-function 'healr-term-make)
               (lambda (buffer-name _agent _dir)
                 (get-buffer-create buffer-name)))
              ((symbol-function 'healr-term--tmux-spawn)
               (lambda (tmux-name &rest _) tmux-name))
              ((symbol-function 'healr-term--tmux-attach)
               (lambda (bn &rest _) (get-buffer-create bn)))
              ((symbol-function 'healr-session--write-sidecar) #'ignore))
      (unwind-protect
          (progn
            (let* ((warm (healr-session-get-or-create "fake" "/tmp/proj/"))
                   (buf (healr-session-buffer warm)))
              (healr-session-detach warm)
              (should-not (buffer-live-p buf)))
            (let ((cold (healr-session-get-or-create "cold" "/tmp/proj/")))
              (should-error (healr-session-detach cold) :type 'user-error)))
        (mapc (lambda (s)
                (when (buffer-live-p (healr-session-buffer s))
                  (kill-buffer (healr-session-buffer s))))
              (healr-session-list))
        (clrhash healr--sessions)))))

(ert-deftest healr-test-session-attach ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("fake" :command "fake" :persist t)))
        (hook-ran 0))
    (cl-letf (((symbol-function 'healr-term--tmux-alive-p)
               (lambda (_) t))
              ((symbol-function 'healr-term--tmux-attach)
               (lambda (bn &rest _) (get-buffer-create bn)))
              ((symbol-function 'pop-to-buffer) #'ignore))
      (let ((session (healr-session--create
                      :root "/tmp/proj/" :agent "fake" :name "main"
                      :buffer nil :state 'detached :last-output 0
                      :tmux "healr_fake_main_aaaaaaaa")))
        (unwind-protect
            (let ((healr-session-created-hook
                   (list (lambda (_s) (setq hook-ran (1+ hook-ran))))))
              (healr-session-attach session)
              (should (= hook-ran 1))
              (should (healr-session-buffer session)))
          (when (buffer-live-p (healr-session-buffer session))
            (kill-buffer (healr-session-buffer session))))))))

(ert-deftest healr-test-session-attach-gone-tmux ()
  (cl-letf (((symbol-function 'healr-term--tmux-alive-p)
             (lambda (_) nil)))
    (should-error
     (healr-session-attach
      (healr-session--create :root "/tmp/" :agent "fake" :name "main"
                             :buffer nil :state 'detached :last-output 0
                             :tmux "healr_fake_main_aaaaaaaa"))
     :type 'user-error)))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — void `healr-session-detach`, `healr-session-attach`, sidecar functions; struct has no `tmux` accessor.

- [ ] **Step 3: Implement healr-session.el changes**

Add `tmux` to the struct (keep all other fields):

```elisp
(cl-defstruct (healr-session (:constructor healr-session--create))
  "A running or dead agent session."
  root          ; absolute project directory
  agent         ; agent name string
  name          ; session name string
  buffer        ; terminal buffer, or nil when detached
  state         ; `working', `idle', `detached' or `dead'
  last-output   ; float time of last terminal output
  recent-output ; tail of recent terminal output (prompt-regexp window)
  timer         ; idle timer or nil
  tmux)         ; tmux session name when warm, or nil
```

Append the sidecar section (after the defcustoms):

```elisp
(defcustom healr-session-metadata-directory
  (expand-file-name "healr/sessions/"
                    (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Directory where warm-session sidecar metadata files live."
  :type 'directory
  :group 'healr)

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
  "Return the sidecar plist for TMUX-NAME, or nil when unreadable."
  (let ((file (healr-session--sidecar-file tmux-name)))
    (when (file-readable-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (read (current-buffer)))
        (error nil)))))

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
```

Replace `healr-session-create` with:

```elisp
(defun healr-session-create (agent root name)
  "Create and register a session running AGENT plist at ROOT named NAME.
When AGENT persists (see `healr-term-persist-p'), the agent runs in a
detached tmux session and the buffer attaches to it.  Signals
`user-error' when the agent's command is not on PATH, when a session
with this key exists, or (warm) when tmux is missing."
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
```

Replace `healr-session-kill` with:

```elisp
(defun healr-session-kill (session)
  "Kill SESSION's process and buffer and remove it from the registry.
Warm sessions also lose their tmux session and sidecar."
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
```

Replace `healr-session-restart` with:

```elisp
(defun healr-session-restart (session)
  "Re-run SESSION's agent in a fresh buffer.  Only dead sessions restart.
Warm sessions respawn their tmux session under the same name."
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
```

Replace `healr-session-toggle` and add detach/attach:

```elisp
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
      (kill-buffer buf)))
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: `61 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add healr-session.el test/healr-test.el
git commit -m "feat: warm session lifecycle (sidecars, detach/attach)"
```

---

### Task 3: detached state, sentinel branch, rehydrate, fleet detach, dispatch

**Files:**
- Modify: `healr-status.el` (sentinel branch, mark-detached, rehydrate, fleet `d`, fleet opens with rehydrate)
- Modify: `healr.el` (dispatch runs rehydrate)
- Test: `test/healr-test.el` (append)

**Interfaces:**
- Consumes: `healr-term--tmux-alive-p` (Task 1); `healr-session-tmux`, `healr-session-detach`, `healr-session--live-tmux-sessions`, `healr-session--read-sidecar` (Task 2).
- Produces:
  - `(healr-status--mark-detached SESSION)` — cancels timer, sets `detached`.
  - `(healr-rehydrate)` — interactive; rebuilds registry from live tmux + sidecars; `detached`→`dead` for vanished tmux.
  - Sentinel contract (per spec): only when the dying process is the session's current client (buffer live and `(eq process (get-buffer-process buffer))`) or the buffer is gone, branch `has-session` → `detached`/`dead`; non-warm sessions keep the v1.1 buffer-identity guard.
  - Fleet `d` = `healr-list-detach`; `healr-list` and `healr-list-refresh` run `healr-rehydrate` first.

- [ ] **Step 1: Write the failing tests**

Append to `test/healr-test.el`:

```elisp
;;; Detached state, rehydrate, fleet detach (Task 3)

(ert-deftest healr-test-status-mark-detached ()
  (let ((healr-idle-seconds 3600)
        (healr-agent-list nil)
        (session (healr-test--fake-session)))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-list--maybe-refresh) #'ignore))
          (healr-status--note-output session "x")
          (should (healr-session-timer session))
          (healr-status--mark-detached session)
          (should (eq (healr-session-state session) 'detached))
          (should-not (healr-session-timer session)))
      (when-let* ((timer (healr-session-timer session))) (cancel-timer timer))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-status-sentinel-warm-detached ()
  (skip-unless (executable-find "cat"))
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("fake" :command "cat")))
        (buf (generate-new-buffer " *healr-test-wd*"))
        proc session)
    (unwind-protect
        (cl-letf (((symbol-function 'healr-term--tmux-alive-p)
                   (lambda (_) t))
                  ((symbol-function 'healr-list--maybe-refresh) #'ignore))
          (setq proc (make-process :name "healr-test-wd" :buffer buf
                                   :command '("cat") :connection-type 'pipe
                                   :noquery t)
                session (healr-session--create
                         :root "/tmp/" :agent "fake" :name "main"
                         :buffer buf :state 'dead :last-output 0
                         :tmux "healr_fake_main_aaaaaaaa"))
          (healr-status-attach session)
          (kill-buffer buf)
          (accept-process-output proc 1)
          (should (eq (healr-session-state session) 'detached)))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when-let* ((timer (and session (healr-session-timer session))))
        (cancel-timer timer))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest healr-test-status-sentinel-warm-dead ()
  (skip-unless (executable-find "cat"))
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("fake" :command "cat")))
        (buf (generate-new-buffer " *healr-test-wx*"))
        proc session)
    (unwind-protect
        (cl-letf (((symbol-function 'healr-term--tmux-alive-p)
                   (lambda (_) nil))
                  ((symbol-function 'healr-list--maybe-refresh) #'ignore))
          (setq proc (make-process :name "healr-test-wx" :buffer buf
                                   :command '("cat") :connection-type 'pipe
                                   :noquery t)
                session (healr-session--create
                         :root "/tmp/" :agent "fake" :name "main"
                         :buffer buf :state 'dead :last-output 0
                         :tmux "healr_fake_main_aaaaaaaa"))
          (healr-status-attach session)
          (delete-process proc)
          (accept-process-output proc 1)
          (should (eq (healr-session-state session) 'dead)))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when-let* ((timer (and session (healr-session-timer session))))
        (cancel-timer timer))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest healr-test-status-sentinel-warm-stale-process ()
  (skip-unless (executable-find "cat"))
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("fake" :command "cat")))
        (buf1 (generate-new-buffer " *healr-test-ws1*"))
        (buf2 (generate-new-buffer " *healr-test-ws2*"))
        proc session)
    (unwind-protect
        (cl-letf (((symbol-function 'healr-term--tmux-alive-p)
                   (lambda (_) t))
                  ((symbol-function 'healr-list--maybe-refresh) #'ignore))
          (setq proc (make-process :name "healr-test-ws" :buffer buf1
                                   :command '("cat") :connection-type 'pipe
                                   :noquery t)
                session (healr-session--create
                         :root "/tmp/" :agent "fake" :name "main"
                         :buffer buf1 :state 'dead :last-output 0
                         :tmux "healr_fake_main_aaaaaaaa"))
          (healr-status-attach session)
          (setf (healr-session-buffer session) buf2)
          (delete-process proc)
          (accept-process-output proc 1)
          (should (eq (healr-session-state session) 'working)))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when-let* ((timer (and session (healr-session-timer session))))
        (cancel-timer timer))
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2)))))

(ert-deftest healr-test-rehydrate-adds-detached ()
  (let ((healr--sessions (make-hash-table :test 'equal)))
    (healr-test--with-temp-metadata
      (cl-letf (((symbol-function 'healr-session--live-tmux-sessions)
                 (lambda () '("healr_fake_main_aaaaaaaa" "healr_fake_gone_bbbbbbbb")))
                ((symbol-function 'healr-list--maybe-refresh) #'ignore))
        (healr-session--write-sidecar "healr_fake_main_aaaaaaaa"
                                      "/tmp/proj/" "fake" "main" 'eat)
        (puthash (healr-session--key "/tmp/gone/" "fake" "old")
                 (healr-session--create
                  :root "/tmp/gone/" :agent "fake" :name "old"
                  :buffer nil :state 'detached :last-output 0
                  :tmux "healr_fake_old_cccccccc")
                 healr--sessions)
        (healr-rehydrate)
        (let ((added (healr-session-get "/tmp/proj/" "fake" "main")))
          (should added)
          (should (eq (healr-session-state added) 'detached))
          (should (equal (healr-session-tmux added)
                         "healr_fake_main_aaaaaaaa"))
          (should-not (healr-session-buffer added)))
        (let ((gone (healr-session-get "/tmp/gone/" "fake" "old")))
          (should (eq (healr-session-state gone) 'dead)))))))

(ert-deftest healr-test-rehydrate-skips-existing-and-no-sidecar ()
  (let ((healr--sessions (make-hash-table :test 'equal)))
    (healr-test--with-temp-metadata
      (cl-letf (((symbol-function 'healr-session--live-tmux-sessions)
                 (lambda () '("healr_fake_main_aaaaaaaa" "healr_orphan_dddddddd")))
                ((symbol-function 'healr-list--maybe-refresh) #'ignore))
        (puthash (healr-session--key "/tmp/proj/" "fake" "main")
                 (healr-session--create
                  :root "/tmp/proj/" :agent "fake" :name "main"
                  :buffer nil :state 'working :last-output 0
                  :tmux "healr_fake_main_aaaaaaaa")
                 healr--sessions)
        (healr-rehydrate)
        (should (= (hash-table-count healr--sessions) 1))
        (should (eq (healr-session-state
                     (healr-session-get "/tmp/proj/" "fake" "main"))
                    'working))))))

(ert-deftest healr-test-fleet-detach-at-point ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (session (healr-session--create
                  :root "/tmp/alpha/" :agent "fake" :name "main"
                  :buffer (get-buffer-create " *healr-test-fd*")
                  :state 'working :last-output 0
                  :tmux "healr_fake_main_aaaaaaaa"))
        (detached nil))
    (unwind-protect
        (progn
          (puthash (healr-session--key "/tmp/alpha/" "fake" "main")
                   session healr--sessions)
          (with-current-buffer (get-buffer-create " *healr-test-fleetd*")
            (healr-list-mode)
            (tabulated-list-print)
            (goto-char (point-min))
            (cl-letf (((symbol-function 'healr-session-detach)
                       (lambda (s) (setq detached s)))
                      ((symbol-function 'healr-rehydrate) #'ignore))
              (healr-list-detach))
            (should (eq detached session))))
      (kill-buffer (healr-session-buffer session))
      (when-let* ((buf (get-buffer " *healr-test-fleetd*")))
        (kill-buffer buf)))))

(ert-deftest healr-test-dispatch-rehydrates-first ()
  (let ((healr-project-root-function (lambda () "/tmp/proj/"))
        (rehydrated 0)
        (fake (healr-test--fake-session :root "/tmp/proj/")))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-rehydrate)
                   (lambda () (setq rehydrated (1+ rehydrated))))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "claude"))
                  ((symbol-function 'healr-session-get-or-create)
                   (lambda (&rest _) fake))
                  ((symbol-function 'healr-session-toggle) #'ignore))
          (call-interactively #'healr)
          (should (= rehydrated 1))))
      (kill-buffer (healr-session-buffer fake))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — void `healr-status--mark-detached`, `healr-rehydrate`, `healr-list-detach`.

- [ ] **Step 3: Implement**

In `healr-status.el`, add after `healr-status--mark-dead`:

```elisp
(defun healr-status--mark-detached (session)
  "Mark SESSION detached and stop its idle timer.
The agent keeps running inside tmux; no Emacs buffer is attached."
  (when-let* ((timer (healr-session-timer session)))
    (cancel-timer timer)
    (setf (healr-session-timer session) nil))
  (healr-status--set session 'detached))
```

Replace the sentinel inside `healr-status--wrap-process` with:

```elisp
    (set-process-sentinel
     proc
     (lambda (process event)
       (when orig-sentinel
         (ignore-errors (funcall orig-sentinel process event)))
       (unless (process-live-p process)
         (if-let* ((tmux-name (healr-session-tmux session)))
             (when (or (not (buffer-live-p (healr-session-buffer session)))
                       (eq process
                           (get-buffer-process
                            (healr-session-buffer session))))
               (if (healr-term--tmux-alive-p tmux-name)
                   (healr-status--mark-detached session)
                 (healr-status--mark-dead session)))
           (when (eq (process-buffer process)
                     (healr-session-buffer session))
             (healr-status--mark-dead session)))))))
```

Append the rehydrate section (before the fleet buffer section):

```elisp
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
```

In the fleet section: add the `d` binding and command, and make the fleet rehydrate before listing:

```elisp
(keymap-set healr-list-mode-map "d" #'healr-list-detach)
```

```elisp
(defun healr-list-detach ()
  "Detach the warm session at point; the agent keeps running."
  (interactive nil healr-list-mode)
  (when-let* ((session (healr-list--session-at-point)))
    (healr-session-detach session)
    (healr-list-refresh)))
```

Replace `healr-list-refresh` and `healr-list` with:

```elisp
(defun healr-list-refresh ()
  "Recompute the fleet buffer, rehydrating from tmux first."
  (interactive nil healr-list-mode)
  (healr-rehydrate)
  (tabulated-list-print t))

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
```

In `healr.el`, add rehydrate to both dispatch commands:

```elisp
(defun healr (agent)
  "Open or toggle AGENT's main session in the current project.
Rehydrates warm sessions from tmux first."
  (interactive
   (let ((default (healr--default-agent (funcall healr-project-root-function))))
     (list (completing-read
            (if default (format "Agent (%s): " default) "Agent: ")
            (healr-agent-names) nil t nil nil default))))
  (healr-rehydrate)
  (healr-session-toggle
   (healr-session-get-or-create agent (funcall healr-project-root-function))))
```

```elisp
(defun healr-new-session (agent name)
  "Create a new session NAME for AGENT in the current project.
Rehydrates warm sessions from tmux first, so duplicates of warm
sessions are caught by the existing-session check."
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: `69 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add healr-status.el healr.el test/healr-test.el
git commit -m "feat: detached state, rehydrate, fleet detach"
```

---

### Task 4: docs, version, real-tmux E2E

**Files:**
- Modify: `README.md`, `AGENTS.md`, `QWEN.md`, `healr.el` (Version: 0.3.0)
- Create: `test/e2e-warm.sh`
- Test: full suite + real E2E

**Interfaces:**
- Consumes: everything.
- Produces: documented warm sessions; repeatable E2E script.

- [ ] **Step 1: README — Warm sessions section (after Language workflows)**

```markdown
## Warm sessions (persistence)

Give an agent `:persist t` and it runs inside a detached tmux session:
it keeps running when you kill its buffer or quit Emacs, and the fleet
finds it again when you come back.

```elisp
(setq healr-agent-list
      '(("claude" :command "claude" :persist t)))
```

- Killing a warm session's buffer **detaches** instead of destroying —
  the fleet shows the session as `detached` and `RET` reattaches with
  the tmux scrollback intact.
- `M-x healr` on a detached `main` session reattaches instead of
  spawning a duplicate.
- Fleet buffer `d` detaches; `k` still kills (tmux session included).
- Agent exit with nothing attached shows as `dead` at the next
  rehydrate; `r` respawns it under the same tmux name.
- Requires `tmux` on PATH — only for `:persist` agents; everything
  else works without it.

Rehydration runs on `M-x healr`, `M-x healr-new-session`, and whenever
the fleet buffer opens or refreshes; `M-x healr-rehydrate` does it on
demand. Sidecar metadata lives in `healr-session-metadata-directory`
(default `~/.cache/healr/sessions/`). `healr-persist-default` makes
persistence the default for every agent.
```

- [ ] **Step 2: AGENTS.md updates**

- State model line becomes: "four states — `working`, `idle`,
  `detached` (tmux alive, no Emacs buffer), `dead`".
- Struct fields: add `tmux` (tmux session name or nil).
- Defcustom list: add `healr-persist-default`,
  `healr-session-metadata-directory`.
- Fleet keys: add `d` detach.
- Add: "Warm sessions (`:persist`) run the agent in a detached tmux
  session; the sentinel branches `detached`/`dead` via
  `healr-term--tmux-alive-p`, guarded on the dying process being the
  session's current client. All tmux calls go through
  `healr-term--tmux-run` / `healr-term--tmux-output`, which degrade
  quietly when tmux is absent."
- Add `:persist` to the agent plist keys list.

- [ ] **Step 3: QWEN.md updates**

- Data flow step 2: mention tmux spawn/attach for warm sessions.
- Terminal backends section: add a short "Warm sessions" subsection
  (persist opt-in, detached state, sidecars, rehydrate).
- Custom vars: add `healr-persist-default`,
  `healr-session-metadata-directory`.

- [ ] **Step 4: healr.el version**

`;; Version: 0.2.0` → `;; Version: 0.3.0`.

- [ ] **Step 5: Create test/e2e-warm.sh**

```bash
#!/usr/bin/env bash
# e2e-warm.sh --- Real-tmux E2E for warm sessions (no API keys needed).
# Spawns the fake agent warm, detaches by killing the buffer, simulates
# an Emacs restart (clears the registry), rehydrates, reattaches, pings.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EAT_DIR="${HEALR_EAT_DIR:-$HOME/.config/emacs/.local/straight/build-29.4/eat}"
COMPAT_DIR="${HEALR_COMPAT_DIR:-$HOME/.config/emacs/.local/straight/build-29.4/compat}"

emacs -Q --batch -L "$COMPAT_DIR" -L "$EAT_DIR" -L "$REPO_DIR" --eval "
(progn
  (require 'healr)
  (setq healr-agent-list
        (list (list \"fake\" :command \"$REPO_DIR/test/fake-agent.sh\"
                    :persist t)))
  (let* ((root \"$REPO_DIR/\")
         (session (healr-session-get-or-create \"fake\" root)))
    (sleep-for 2)
    (message \"E2E-WARM tmux-alive: %s\"
             (healr-term--tmux-alive-p (healr-session-tmux session)))
    (kill-buffer (healr-session-buffer session))
    (sleep-for 1)
    (message \"E2E-WARM state-after-detach: %s\"
             (healr-session-state session))
    (clrhash healr--sessions)
    (healr-rehydrate)
    (let ((s (healr-session-get root \"fake\" \"main\")))
      (message \"E2E-WARM rehydrated-state: %s\"
               (and s (healr-session-state s)))
      (healr-session-attach s)
      (sleep-for 2)
      (healr-term-send-string (healr-session-buffer s) \"warm ping\")
      (healr-term-send-return (healr-session-buffer s))
      (sleep-for 2)
      (with-current-buffer (healr-session-buffer s)
        (message \"E2E-WARM echo: %s\"
                 (if (save-excursion (goto-char (point-min))
                                     (search-forward \"you said: warm ping\" nil t))
                     \"YES\" \"NO\")))
      (healr-session-kill s)
      (message \"E2E-WARM tmux-gone: %s\"
               (not (healr-term--tmux-alive-p (healr-session-tmux s))))))
" 2>&1 | grep "E2E-WARM"
```

Run: `chmod +x test/e2e-warm.sh`

Expected output:

```
E2E-WARM tmux-alive: t
E2E-WARM state-after-detach: detached
E2E-WARM rehydrated-state: detached
E2E-WARM echo: YES
E2E-WARM tmux-gone: t
```

- [ ] **Step 6: Run full suite + E2E**

Run: `emacs -Q --batch -L . -l test/healr-test.el -f ert-run-tests-batch-and-exit`
Expected: `69 passed, 0 failed`.
Run: `./test/e2e-warm.sh`
Expected: the five E2E-WARM lines above.

- [ ] **Step 7: Commit**

```bash
git add README.md AGENTS.md QWEN.md healr.el test/e2e-warm.sh
git commit -m "docs: warm sessions (v0.3.0) and real-tmux e2e"
```

---

## Self-review notes (completed by plan author)

- Spec coverage: persist plumbing (T1), lifecycle incl. sidecars and detach/attach (T2), detached state + sentinel contract + rehydrate + fleet/dispatch (T3), docs + real E2E (T4). Every spec section maps to a task.
- The sentinel contract in Task 3 matches the spec amendment exactly: current-client-or-buffer-gone, then `has-session` branch; non-warm sessions keep the v1.1 buffer-identity guard.
- Detached sessions carry `buffer = nil`; every consumer touched by this plan (toggle, kill, fleet entries, DWIM's `healr-term-alive-p` filter) is nil-safe or excludes them.
- tmux-less machines: `healr-term--tmux-run` returns 1 and `healr-term--tmux-output` nil without tmux, so rehydrate is a silent no-op; the only loud failure is the explicit spawn (`user-error`).
- Test counts: 45 → 52 (T1) → 61 (T2) → 69 (T3).
