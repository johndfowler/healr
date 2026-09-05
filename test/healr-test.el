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
  `(let ((term-calls 0)
         (healr-session-created-hook nil))
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
        (cl-letf (((symbol-function 'healr-term-alive-p)
                   (lambda (&rest _) t))
                  ((symbol-function 'healr-session-list)
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
        (cl-letf (((symbol-function 'healr-term-alive-p)
                   (lambda (&rest _) t))
                  ((symbol-function 'healr-session-list)
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


;;; Review-hardening regression tests

(ert-deftest healr-test-status-stale-sentinel-ignores-old-process ()
  (skip-unless (executable-find "cat"))
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("fake" :command "cat")))
        (buf1 (generate-new-buffer " *healr-test-stale1*"))
        (buf2 (generate-new-buffer " *healr-test-stale2*"))
        proc session)
    (unwind-protect
        (progn
          (setq proc (make-process :name "healr-test-stale" :buffer buf1
                                   :command '("cat") :connection-type 'pipe
                                   :noquery t)
                session (healr-session--create
                         :root "/tmp/" :agent "fake" :name "main"
                         :buffer buf1 :state 'dead :last-output 0))
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

(ert-deftest healr-test-status-bad-prompt-regexp-keeps-filter ()
  (skip-unless (executable-find "cat"))
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("fake" :command "cat" :prompt-regexp "(")))
        (buf (generate-new-buffer " *healr-test-badre*"))
        proc session)
    (unwind-protect
        (progn
          (setq proc (make-process :name "healr-test-badre" :buffer buf
                                   :command '("cat") :connection-type 'pipe
                                   :noquery t)
                session (healr-session--create
                         :root "/tmp/" :agent "fake" :name "main"
                         :buffer buf :state 'dead :last-output 0))
          (healr-status-attach session)
          (process-send-string proc "hi\n")
          (accept-process-output proc 1)
          (should (with-current-buffer buf
                    (save-excursion
                      (goto-char (point-min))
                      (search-forward "hi" nil t)))))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when-let* ((timer (and session (healr-session-timer session))))
        (cancel-timer timer))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest healr-test-status-prompt-split-across-chunks ()
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("fake" :command "cat" :prompt-regexp "PROMPT> ")))
        (session (healr-test--fake-session :agent "fake")))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-list--maybe-refresh) #'ignore))
          (healr-status--note-output session "blah PROM")
          (should (eq (healr-session-state session) 'working))
          (healr-status--note-output session "PT> ")
          (should (eq (healr-session-state session) 'idle)))
      (when-let* ((timer (healr-session-timer session))) (cancel-timer timer))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-status-attach-without-process-marks-dead ()
  (let ((healr-idle-seconds 3600)
        (session (healr-test--fake-session)))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-list--maybe-refresh) #'ignore))
          (healr-status-attach session)
          (should (eq (healr-session-state session) 'dead))
          (should-not (healr-session-timer session)))
      (when-let* ((timer (healr-session-timer session))) (cancel-timer timer))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-session-kill-disarms-watchers ()
  (skip-unless (executable-find "cat"))
  (let ((healr-idle-seconds 3600)
        (healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("fake" :command "cat")))
        (buf (generate-new-buffer " *healr-test-killwatch*"))
        proc session)
    (unwind-protect
        (progn
          (setq proc (make-process :name "healr-test-kw" :buffer buf
                                   :command '("cat") :connection-type 'pipe
                                   :noquery t)
                session (healr-session--create
                         :root "/tmp/" :agent "fake" :name "main"
                         :buffer buf :state 'dead :last-output 0))
          (puthash (healr-session--key "/tmp/" "fake" "main")
                   session healr--sessions)
          (healr-status-attach session)
          (should (healr-session-timer session))
          (healr-session-kill session)
          (should-not (healr-session-timer session))
          (should-not (buffer-live-p buf))
          (should (= (hash-table-count healr--sessions) 0)))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when-let* ((timer (and session (healr-session-timer session))))
        (cancel-timer timer))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest healr-test-send-dwim-skips-process-less-session ()
  (let* ((healr-project-root-function (lambda () "/tmp/proj/"))
         (session (healr-test--fake-session :root "/tmp/proj/")))
    (unwind-protect
        (cl-letf (((symbol-function 'healr-session-list)
                   (lambda (&optional _root) (list session))))
          (with-temp-buffer
            (setq buffer-file-name "/tmp/proj/x.el")
            (should-error (healr-send-dwim) :type 'user-error)))
      (kill-buffer (healr-session-buffer session)))))

(ert-deftest healr-test-session-create-rejects-duplicate ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("claude" :command "claude"))))
    (healr-test--with-fake-term
      (unwind-protect
          (progn
            (healr-session-get-or-create "claude" "/tmp/proj/")
            (should-error
             (healr-session-create (healr-agent-get "claude") "/tmp/proj/" "main")
             :type 'user-error))
        (mapc #'healr-session-kill (healr-session-list))))))

(ert-deftest healr-test-session-rename-rejects-empty ()
  (let ((healr--sessions (make-hash-table :test 'equal))
        (healr-agent-list '(("claude" :command "claude"))))
    (healr-test--with-fake-term
      (unwind-protect
          (let ((session (healr-session-get-or-create "claude" "/tmp/proj/")))
            (should-error (healr-session-rename session "") :type 'user-error))
        (mapc #'healr-session-kill (healr-session-list))))))


;;; Project-aware agent defaults

(ert-deftest healr-test-default-agent ()
  (let ((root (make-temp-file "healr-proj" t)))
    (unwind-protect
        (let ((healr-project-agent-alist
               '(("mix.exs" . "elixir")
                 ("build.gradle.kts" . "kotlin")))
              (healr-agent-list '(("elixir" :command "claude"))))
          (should-not (healr--default-agent root))
          (write-region "" nil (expand-file-name "build.gradle.kts" root))
          (should-not (healr--default-agent root))
          (write-region "" nil (expand-file-name "mix.exs" root))
          (should (equal (healr--default-agent root) "elixir")))
      (delete-directory root t))))

(ert-deftest healr-test-dispatch-offers-project-default ()
  (let* ((root (make-temp-file "healr-proj" t))
         (healr-project-root-function (lambda () root))
         (healr-project-agent-alist '(("mix.exs" . "elixir")))
         (healr-agent-list '(("elixir" :command "claude")
                             ("claude" :command "claude")))
         (fake (healr-test--fake-session :root root))
         got-default got-prompt)
    (unwind-protect
        (progn
          (write-region "" nil (expand-file-name "mix.exs" root))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt &rest args)
                       (setq got-prompt prompt
                             got-default (nth 5 args))
                       "elixir"))
                    ((symbol-function 'healr-session-get-or-create)
                     (lambda (&rest _) fake))
                    ((symbol-function 'healr-session-toggle) #'ignore))
            (call-interactively #'healr)
            (should (equal got-default "elixir"))
            (should (string-match-p "elixir" got-prompt))))
      (kill-buffer (healr-session-buffer fake))
      (delete-directory root t))))


;;; tmux primitives (Task 1, warm sessions)

(ert-deftest healr-test-term-persist-p ()
  (let ((healr-persist-default nil))
    (should-not (healr-term-persist-p '( :name "a" )))
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
        (healr-session-created-hook nil)
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
          (process-send-eof proc)
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
        proc proc2 session)
    (unwind-protect
        (cl-letf (((symbol-function 'healr-term--tmux-alive-p)
                   (lambda (_) t))
                  ((symbol-function 'healr-list--maybe-refresh) #'ignore))
          (setq proc (make-process :name "healr-test-ws" :buffer buf1
                                   :command '("cat") :connection-type 'pipe
                                   :noquery t)
                proc2 (make-process :name "healr-test-ws2" :buffer buf2
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
      (when (and proc2 (process-live-p proc2)) (delete-process proc2))
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


(ert-deftest healr-test-session-detach-live-process-no-prompt ()
  (skip-unless (executable-find "cat"))
  (let ((healr-idle-seconds 3600)
        (healr-agent-list '(("fake" :command "cat")))
        (buf (generate-new-buffer " *healr-test-dlp*"))
        proc session)
    (unwind-protect
        (cl-letf (((symbol-function 'healr-term--tmux-alive-p)
                   (lambda (_) t))
                  ((symbol-function 'healr-list--maybe-refresh) #'ignore))
          (setq proc (make-process :name "healr-test-dlp" :buffer buf
                                   :command '("cat") :connection-type 'pipe
                                   :noquery t)
                session (healr-session--create
                         :root "/tmp/" :agent "fake" :name "main"
                         :buffer buf :state 'dead :last-output 0
                         :tmux "healr_fake_main_aaaaaaaa"))
          (healr-status-attach session)
          (healr-session-detach session)
          (should-not (buffer-live-p buf))
          (accept-process-output proc 1)
          (should (eq (healr-session-state session) 'detached)))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when-let* ((timer (and session (healr-session-timer session))))
        (cancel-timer timer))
      (when (buffer-live-p buf) (kill-buffer buf)))))


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


;;; Attention mode and alerts (Task 2)

(defun healr-test--registry-with-states (states)
  "Return (HASH-TABLE SESSIONS) with one fake session per state in STATES."
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
          (should (= alerts 0)))
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
          (should (= alerts 0)))
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


;;; Detached polling (Task 3)

(cl-defun healr-test--warm-detached (&key (state 'detached))
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

;;; healr-test.el ends here
