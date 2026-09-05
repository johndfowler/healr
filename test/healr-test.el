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

;;; healr-test.el ends here
