;;; healr-test.el --- ERT tests for healr  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'healr-agents)

(ert-deftest healr-test-agent-normalize-defaults ()
  (let ((agent (healr-agent--normalize "foo" nil)))
    (should (equal (plist-get agent :name) "foo"))
    (should (equal (plist-get agent :command) "foo"))
    (should-not (plist-get agent :args))
    (should-not (plist-get agent :env))
    (should-not (plist-get agent :prompt-regexp))
    (should-not (plist-get agent :backend))))

(ert-deftest healr-test-agent-normalize-explicit ()
  (let ((agent (healr-agent--normalize
                "foo" '(:command "bar" :args ("--baz") :env (("A" . "1"))
                        :prompt-regexp "> " :backend vterm))))
    (should (equal (plist-get agent :command) "bar"))
    (should (equal (plist-get agent :args) '("--baz")))
    (should (equal (plist-get agent :env) '(("A" . "1"))))
    (should (equal (plist-get agent :prompt-regexp) "> "))
    (should (eq (plist-get agent :backend) 'vterm))))

(ert-deftest healr-test-agent-get-known-and-unknown ()
  (let ((healr-agent-list '(("alpha" :command "alpha-cli"))))
    (should (equal (plist-get (healr-agent-get "alpha") :command) "alpha-cli"))
    (should-not (healr-agent-get "nope"))))

(ert-deftest healr-test-agent-names ()
  (let ((healr-agent-list '(("a") ("b" :command "x"))))
    (should (equal (healr-agent-names) '("a" "b")))))


(require 'healr-term)

(ert-deftest healr-test-term-process-env ()
  (let ((merged (healr-term--process-env '(("HEALR_TEST" . "42")))))
    (should (equal (car merged) "HEALR_TEST=42"))
    (should (member (concat "PATH=" (getenv "PATH")) merged))))

(ert-deftest healr-test-term-resolve-backend ()
  (let ((healr-terminal-backend 'eat))
    (should (eq (healr-term--resolve-backend '(:name "a")) 'eat))
    (should (eq (healr-term--resolve-backend '(:name "a" :backend vterm)) 'vterm))))

(ert-deftest healr-test-term-make-unknown-backend ()
  (should-error
   (healr-term-make "*healr-test-x*" '(:name "a" :command "a" :backend bogus) "/tmp/")
   :type 'user-error))

(ert-deftest healr-test-term-make-dispatches-and-tags-buffer ()
  (let (called)
    (cl-letf (((symbol-function 'healr-term--make-eat)
               (lambda (bn cmd args)
                 (setq called (list 'eat bn cmd args))
                 (get-buffer-create bn)))
              ((symbol-function 'healr-term--make-vterm)
               (lambda (bn cmd args)
                 (setq called (list 'vterm bn cmd args))
                 (get-buffer-create bn))))
      (unwind-protect
          (let ((buf (healr-term-make "*healr-test-dispatch*"
                                      '(:name "claude" :command "claude"
                                        :args ("-p") :backend eat)
                                      "/tmp/")))
            (should (eq (car called) 'eat))
            (should (equal (nth 2 called) "claude"))
            (should (equal (nth 3 called) '("-p")))
            (should (eq (buffer-local-value 'healr-term--backend buf) 'eat)))
        (when-let* ((buf (get-buffer "*healr-test-dispatch*")))
          (kill-buffer buf))))))

(ert-deftest healr-test-term-eat-missing-package ()
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _file _noerror)
               (and (not (eq feature 'eat)) t))))
    (should-error
     (healr-term--make-eat "*healr-test-noeat*" "true" nil)
     :type 'user-error)))

(ert-deftest healr-test-term-send-string-dispatch ()
  (let (sent
        (buf (get-buffer-create " *healr-test-send*")))
    (unwind-protect
        (cl-letf (((symbol-function 'eat-term-send-string)
                   (lambda (_term str) (setq sent str))))
          (with-current-buffer buf (setq healr-term--backend 'eat
                               eat-terminal :fake-terminal))
          (healr-term-send-string buf "hello")
          (should (equal sent "hello")))
      (kill-buffer buf))))

(ert-deftest healr-test-term-alive-p ()
  (let ((buf (get-buffer-create " *healr-test-alive*")))
    (unwind-protect
        (should-not (healr-term-alive-p buf))
      (kill-buffer buf))))


(require 'healr-session)

(defmacro healr-test--with-fake-term (&rest body)
  "Run BODY with `healr-term-make' and `executable-find' stubbed."
  (declare (indent 0))
  `(let ((term-calls 0))
     (cl-letf (((symbol-function 'healr-term-make)
                (lambda (buffer-name _agent _dir)
                  (setq term-calls (1+ term-calls))
                  (get-buffer-create buffer-name)))
               ((symbol-function 'executable-find)
                (lambda (_cmd &optional _remote) "/usr/bin/true")))
       ,@body)))

(ert-deftest healr-test-session-buffer-name ()
  (should (equal (healr-session-buffer-name "/tmp/proj/" "claude" "main")
                 "*healr:proj:claude:main*")))

(ert-deftest healr-test-session-buffer-name-collision ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (buf (get-buffer-create "*healr:proj:claude:main*")))
    (unwind-protect
        (progn
          (puthash (healr-session--key "/a/proj/" "claude" "main")
                   (healr-session--create :root "/a/proj/" :agent "claude"
                                          :name "main" :buffer buf)
                   healr--sessions)
          (should (equal (healr-session--buffer-name-for "/a/proj/" "claude" "main")
                         "*healr:proj:claude:main*"))
          (should (string-match-p
                   "\\`\\*healr:proj-[0-9a-f]\\{8\\}:claude:main\\*\\'"
                   (healr-session--buffer-name-for "/b/proj/" "claude" "main"))))
      (kill-buffer buf))))

(ert-deftest healr-test-session-get-or-create-caches ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("claude" :command "claude"))))
    (healr-test--with-fake-term
      (unwind-protect
          (let ((first (healr-session-get-or-create "claude" "/tmp/proj/"))
                (second (healr-session-get-or-create "claude" "/tmp/proj/")))
            (should (eq first second))
            (should (= term-calls 1))
            (should (equal (healr-session-name first) "main"))
            (should (healr-session-live-p first)))
        (mapc #'healr-session-kill (healr-session-list))))))

(ert-deftest healr-test-session-unknown-agent ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list nil))
    (should-error (healr-session-get-or-create "nope" "/tmp/proj/")
                  :type 'user-error)))

(ert-deftest healr-test-session-missing-binary ()
  (let ((healr--sessions (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_cmd &optional _remote) nil)))
      (should-error
       (healr-session-create (healr-agent--normalize "ghost" nil) "/tmp/proj/" "main")
       :type 'user-error))))

(ert-deftest healr-test-session-rename ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("claude" :command "claude"))))
    (healr-test--with-fake-term
      (unwind-protect
          (let ((session (healr-session-get-or-create "claude" "/tmp/proj/")))
            (healr-session-rename session "work")
            (should-not (healr-session-get "/tmp/proj/" "claude" "main"))
            (should (eq (healr-session-get "/tmp/proj/" "claude" "work") session))
            (should (equal (buffer-name (healr-session-buffer session))
                           "*healr:proj:claude:work*"))
            (should-error (healr-session-rename session "work") :type 'user-error))
        (mapc #'healr-session-kill (healr-session-list))))))

(ert-deftest healr-test-session-kill ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("claude" :command "claude"))))
    (healr-test--with-fake-term
      (let* ((session (healr-session-get-or-create "claude" "/tmp/proj/"))
             (buf (healr-session-buffer session)))
        (healr-session-kill session)
        (should-not (healr-session-get "/tmp/proj/" "claude" "main"))
        (should-not (buffer-live-p buf))))))

(ert-deftest healr-test-session-restart-only-when-dead ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("claude" :command "claude"))))
    (healr-test--with-fake-term
      (unwind-protect
          (let ((session (healr-session-get-or-create "claude" "/tmp/proj/")))
            (should-error (healr-session-restart session) :type 'user-error)
            (setf (healr-session-state session) 'dead)
            (let* ((hook-ran 0)
                   (healr-session-created-hook
                    (list (lambda (_s) (setq hook-ran (1+ hook-ran))))))
              (healr-session-restart session)
              (should (= hook-ran 1))
              (should (eq (healr-session-state session) 'working))
              (should (= term-calls 2))))
        (mapc #'healr-session-kill (healr-session-list))))))

(ert-deftest healr-test-session-toggle ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("claude" :command "claude"))))
    (healr-test--with-fake-term
      (unwind-protect
          (let ((session (healr-session-get-or-create "claude" "/tmp/proj/"))
                (popped nil))
            (cl-letf (((symbol-function 'get-buffer-window)
                       (lambda (&rest _) nil))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buf &rest _) (setq popped buf))))
              (healr-session-toggle session)
              (should (eq popped (healr-session-buffer session)))))
        (mapc #'healr-session-kill (healr-session-list))))))


(require 'healr-status)

(cl-defun healr-test--fake-session (&key (root "/tmp/proj/") (agent "claude")
                                      (name "main") (state 'working))
  "Return a fake session struct with a fresh (process-less) buffer."
  (healr-session--create
   :root root :agent agent :name name
   :buffer (get-buffer-create (format " *healr-test-%s-%s*" agent name))
   :state state :last-output (float-time)))

(ert-deftest healr-test-status-set-refreshes-on-change ()
  (let ((refreshed 0)
        (session (healr-test--fake-session)))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-list--maybe-refresh)
                   (lambda () (setq refreshed (1+ refreshed)))))
          (healr-status--set session 'working)
          (should (= refreshed 0))
          (healr-status--set session 'idle)
          (should (= refreshed 1))
          (should (eq (healr-session-state session) 'idle)))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-status-note-output-working ()
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("claude" :command "claude")))
        (session (healr-test--fake-session :state 'idle)))
    (unwind-protect
        (progn
          (healr-status--note-output session "some output")
          (should (eq (healr-session-state session) 'working))
          (should (healr-session-timer session))
          (should (> (healr-session-last-output session) 0)))
      (when-let* ((timer (healr-session-timer session))) (cancel-timer timer))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-status-note-output-prompt-regexp ()
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("claude" :command "claude" :prompt-regexp "^> $")))
        (session (healr-test--fake-session)))
    (unwind-protect
        (progn
          (healr-status--note-output session "thinking...\n> ")
          (should (eq (healr-session-state session) 'idle)))
      (when-let* ((timer (healr-session-timer session))) (cancel-timer timer))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-status-idle-check ()
  (let ((healr-idle-seconds 5)
        (session (healr-test--fake-session)))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-list--maybe-refresh) #'ignore))
          (setf (healr-session-last-output session) (float-time))
          (healr-status--idle-check session)
          (should (eq (healr-session-state session) 'working))
          (setf (healr-session-last-output session) (- (float-time) 60))
          (healr-status--idle-check session)
          (should (eq (healr-session-state session) 'idle)))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-status-mark-dead ()
  (let ((healr-idle-seconds 3600)
        (healr-agent-list nil)
        (session (healr-test--fake-session)))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-list--maybe-refresh) #'ignore))
          (healr-status--note-output session "x")
          (should (healr-session-timer session))
          (healr-status--mark-dead session)
          (should (eq (healr-session-state session) 'dead))
          (should-not (healr-session-timer session)))
      (when-let* ((timer (healr-session-timer session))) (cancel-timer timer))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-status-attach-watches-real-process ()
  (skip-unless (executable-find "cat"))
  (let ((healr-idle-seconds 3600)
        (healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("fake" :command "cat")))
        (buf (generate-new-buffer " *healr-test-cat*"))
        proc session)
    (unwind-protect
        (progn
          (setq proc (make-process :name "healr-test-cat" :buffer buf
                                   :command '("cat") :connection-type 'pipe
                                   :noquery t)
                session (healr-session--create
                         :root "/tmp/" :agent "fake" :name "main"
                         :buffer buf :state 'dead :last-output 0))
          (healr-status-attach session)
          (should (eq (healr-session-state session) 'working))
          (process-send-string proc "hi\n")
          (accept-process-output proc 1)
          (should (> (healr-session-last-output session) 0))
          (delete-process proc)
          (accept-process-output proc 1)
          (should (eq (healr-session-state session) 'dead)))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when-let* ((timer (and session (healr-session-timer session))))
        (cancel-timer timer))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest healr-test-status-fleet-entries ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (live (healr-test--fake-session :root "/tmp/alpha/" :name "main"))
        (dead (healr-test--fake-session :root "/tmp/beta/" :name "old"
                                        :state 'dead)))
    (unwind-protect
        (progn
          (puthash (healr-session--key "/tmp/alpha/" "claude" "main")
                   live healr--sessions)
          (puthash (healr-session--key "/tmp/beta/" "claude" "old")
                   dead healr--sessions)
          (let* ((entries (healr-list--entries))
                 (live-entry (assoc (healr-session--key "/tmp/alpha/" "claude" "main")
                                    entries))
                 (dead-entry (assoc (healr-session--key "/tmp/beta/" "claude" "old")
                                    entries)))
            (should (= (length entries) 2))
            (let ((cols (nth 1 live-entry)))
              (should (equal (elt cols 0) "alpha"))
              (should (equal (elt cols 1) "claude"))
              (should (equal (elt cols 3) "working")))
            (let ((cols (nth 1 dead-entry)))
              (should (equal (elt cols 3) "dead"))
              (should (equal (elt cols 4) "—")))))
      (kill-buffer (healr-session-buffer live))
      (kill-buffer (healr-session-buffer dead)))))

(ert-deftest healr-test-status-fleet-kill-at-point ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (session (healr-test--fake-session :root "/tmp/alpha/"))
        (killed nil))
    (unwind-protect
        (progn
          (puthash (healr-session--key "/tmp/alpha/" "claude" "main")
                   session healr--sessions)
          (with-current-buffer (get-buffer-create " *healr-test-fleet*")
            (healr-list-mode)
            (tabulated-list-print)
            (goto-char (point-min))
            (cl-letf (((symbol-function 'healr-session-kill)
                       (lambda (s) (setq killed s)))
                      ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
              (healr-list-kill))
            (should (eq killed session))))
      (kill-buffer (healr-session-buffer session))
      (when-let* ((buf (get-buffer " *healr-test-fleet*")))
        (kill-buffer buf)))))


(require 'healr)

(ert-deftest healr-test-dwim-reference ()
  (should (equal (healr--dwim-reference "/a/b/c/d.el" "/a/b/")
                 "@c/d.el"))
  (should (equal (healr--dwim-reference "/a/b/c/d.el" "/a/b/" 3 7)
                 "@c/d.el#L3-7"))
  (should (equal (healr--dwim-reference "/a/b/c/d.el" "/a/b/" 3 3)
                 "@c/d.el#L3"))
  (should (equal (healr--dwim-reference "/a/b/c/d.el" "/a/b/" 3 nil)
                 "@c/d.el#L3")))

(ert-deftest healr-test-dispatch-toggles-main-session ()
  (let ((healr-project-root-function (lambda () "/tmp/proj/"))
        (fake (healr-test--fake-session :root "/tmp/proj/"))
        got-args toggled)
    (unwind-protect
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) "claude"))
                  ((symbol-function 'healr-session-get-or-create)
                   (lambda (agent root &optional name)
                     (setq got-args (list agent root name))
                     fake))
                  ((symbol-function 'healr-session-toggle)
                   (lambda (session) (setq toggled session))))
          (call-interactively #'healr)
          (should (equal got-args '("claude" "/tmp/proj/" nil)))
          (should (eq toggled fake)))
      (kill-buffer (healr-session-buffer fake)))))

(ert-deftest healr-test-new-session-rejects-duplicate ()
  (let ((healr-project-root-function (lambda () "/tmp/proj/")))
    (cl-letf (((symbol-function 'healr-session-get)
               (lambda (&rest _) t)))
      (should-error (healr-new-session "claude" "main") :type 'user-error))))

(ert-deftest healr-test-send-dwim-requires-file ()
  (with-current-buffer (get-buffer-create " *healr-test-nofile*")
    (unwind-protect
        (should-error (healr-send-dwim) :type 'user-error)
      (kill-buffer " *healr-test-nofile*"))))

(ert-deftest healr-test-send-dwim-requires-session ()
  (let ((healr-project-root-function (lambda () "/tmp/proj/")))
    (cl-letf (((symbol-function 'healr-session-list) (lambda (&rest _) nil)))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/proj/x.el")
        (should-error (healr-send-dwim) :type 'user-error)))))

(ert-deftest healr-test-send-dwim-sends-reference ()
  (let* ((healr-project-root-function (lambda () "/tmp/proj/"))
         (session (healr-test--fake-session :root "/tmp/proj/"))
         sent popped)
    (unwind-protect
        (cl-letf (((symbol-function 'healr-session-list)
                   (lambda (&optional _root) (list session)))
                  ((symbol-function 'healr-term-send-string)
                   (lambda (_buf str) (setq sent str)))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buf &rest _) (setq popped buf))))
          (with-temp-buffer
            (setq buffer-file-name "/tmp/proj/src/x.el")
            (healr-send-dwim)
            (should (equal sent "@src/x.el "))
            (should (eq popped (healr-session-buffer session))))))
      (kill-buffer (healr-session-buffer session))))

(ert-deftest healr-test-send-dwim-region-lines ()
  (let* ((healr-project-root-function (lambda () "/tmp/proj/"))
         (session (healr-test--fake-session :root "/tmp/proj/"))
         sent)
    (unwind-protect
        (cl-letf (((symbol-function 'healr-session-list)
                   (lambda (&optional _root) (list session)))
                  ((symbol-function 'healr-term-send-string)
                   (lambda (_buf str) (setq sent str)))
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (with-temp-buffer
            (transient-mark-mode 1)
            (setq buffer-file-name "/tmp/proj/src/x.el")
            (insert "l1\nl2\nl3\nl4\n")
            (goto-char (point-min))
            (forward-line 1)
            (set-mark (point))
            (forward-line 2)
            (activate-mark)
            (healr-send-dwim)
            (should (equal sent "@src/x.el#L2-3 "))))
      (kill-buffer (healr-session-buffer session)))))

;;; healr-test.el ends here
