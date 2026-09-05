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

;;; healr-test.el ends here
