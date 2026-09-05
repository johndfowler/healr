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

;;; healr-test.el ends here
