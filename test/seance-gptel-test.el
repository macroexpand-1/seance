;;; seance-gptel-test.el --- ERT tests for the gptel transport  -*- lexical-binding: t; -*-

;;; Commentary:
;; gptel is a soft dependency, so mostly what's worth checking is that the file
;; loads without it and then refuses to run, rather than calling void functions
;; at you. Nothing here issues a request.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seance)
(require 'seance-gptel)
;; the M-x sweep below covers both transports, so don't lean on the Makefile
;; happening to load seance-claude-test.el first
(require 'seance-claude)

(ert-deftest seance-gptel-loads-without-gptel ()
  ;; the whole point of the soft (require 'gptel nil t)
  (should (featurep 'seance-gptel)))

(ert-deftest seance-gptel-refuses-without-gptel ()
  (skip-unless (not (featurep 'gptel)))
  (should-error (seance-gptel--require) :type 'user-error))

(ert-deftest seance-gptel-chat-refuses-without-gptel ()
  (skip-unless (not (featurep 'gptel)))
  (should-error (seance-gptel) :type 'user-error))

(ert-deftest seance-gptel-backend-setup-refuses-without-gptel ()
  (skip-unless (not (featurep 'gptel)))
  (should-error (seance-gptel-use-openai-compatible "local" "localhost:8080" 'a-model)
                :type 'user-error))

;;; With gptel actually present. Skipped unless the Makefile found it, so run
;;; these with:  make test GPTEL_DIR=/path/to/gptel

(ert-deftest seance-gptel-targets-the-non-obsolete-system-variable ()
  (skip-unless (featurep 'gptel))
  ;; gptel turned `gptel--system-message' into an obsolete alias pointing at
  ;; `gptel-system-prompt'. Writing the old name still works through the alias,
  ;; right up until it does not.
  (should (eq 'gptel-system-prompt (seance-gptel--system-variable))))

(ert-deftest seance-gptel-send-loads-the-snapshot-then-sends ()
  (skip-unless (featurep 'gptel))
  (let ((sent nil))
    (cl-letf (((symbol-function 'gptel-send)
               (lambda (&rest _) (interactive) (setq sent t)))
              ((symbol-function 'seance-context-string-async)
               (lambda (k &optional _profile) (funcall k "<<IMAGE>>"))))
      (with-temp-buffer
        (seance-gptel-send)
        (should sent)
        (let ((system (symbol-value (seance-gptel--system-variable))))
          (should (string-match-p "<<IMAGE>>" system))
          (should (string-match-p (regexp-quote seance-gptel-preamble) system)))))))

(ert-deftest seance-gptel-send-asks-for-the-configured-profile ()
  (skip-unless (featurep 'gptel))
  (let ((asked :none)
        (seance-gptel-profile :full)
        (seance-profile :lean))
    (cl-letf (((symbol-function 'gptel-send) (lambda (&rest _) (interactive)))
              ((symbol-function 'seance-context-string-async)
               (lambda (k &optional profile) (setq asked profile) (funcall k ""))))
      (with-temp-buffer (seance-gptel-send)))
    (should (eq :full asked))))

(ert-deftest seance-gptel-backend-setup-stores-backend-and-model ()
  (skip-unless (featurep 'gptel))
  (let ((seance-gptel-backend nil)
        (seance-gptel-model nil)
        (seance-gptel-host nil)
        (seance-gptel-model-name nil)
        (seance-gptel-backend-name "local"))
    (seance-gptel-use-openai-compatible "seance-test-local" "localhost:8080" 'a-model)
    (should seance-gptel-backend)
    (should (eq 'a-model seance-gptel-model))
    ;; written through so the choice can be rebuilt without asking again
    (should (equal "localhost:8080"   seance-gptel-host))
    (should (equal "a-model"          seance-gptel-model-name))
    (should (equal "seance-test-local" seance-gptel-backend-name))))

(ert-deftest seance-gptel-builds-a-backend-from-the-customs ()
  ;; the point of the host/model-name customs: set them in your init and never
  ;; run the picker again
  (skip-unless (featurep 'gptel))
  (let ((seance-gptel-backend nil)
        (seance-gptel-model nil)
        (seance-gptel-backend-name "from-init")
        (seance-gptel-host "localhost:9999")
        (seance-gptel-model-name "init-model"))
    (should (seance-gptel--ensure-backend))
    (should (eq 'init-model seance-gptel-model))))

(ert-deftest seance-gptel-ensure-backend-is-nil-with-nothing-configured ()
  (let ((seance-gptel-backend nil)
        (seance-gptel-host nil)
        (seance-gptel-model-name nil))
    (should-not (seance-gptel--ensure-backend))))

;;; Reachable from M-x, which the docs have always claimed

(ert-deftest seance-gptel-backend-setup-is-a-command ()
  (should (commandp 'seance-gptel-use-openai-compatible)))

(ert-deftest seance-commands-are-all-reachable-from-m-x ()
  (dolist (cmd '(seance-clear-log
                 seance-install
                 seance-uninstall
                 seance-preview-context
                 seance-claude
                 seance-claude-send
                 seance-gptel
                 seance-gptel-send
                 seance-gptel-use-openai-compatible))
    (should (fboundp cmd))
    (should (commandp cmd))))

;;; The chat buffer, at parity with the Claude one

(ert-deftest seance-gptel-chat-gives-up-on-a-fetch-with-the-claude-key ()
  (should (eq #'seance-cancel-fetch
              (lookup-key seance-gptel-chat-mode-map (kbd "C-c C-k")))))

(ert-deftest seance-gptel-prefix-opens-a-separate-chat ()
  (skip-unless (featurep 'gptel))
  (let ((seance-gptel-backend nil)
        (seance-gptel-host nil)
        (seance-gptel-model-name nil)
        (seance-gptel-buffer-name " *seance-test-gptel*")
        (made nil))
    (unwind-protect
        (save-window-excursion
          (seance-gptel)
          (push (current-buffer) made)
          ;; again from inside the chat: the same chat
          (seance-gptel)
          (should (eq (car made) (current-buffer)))
          ;; with a prefix: a new one
          (seance-gptel t)
          (push (current-buffer) made)
          (should-not (eq (car made) (cadr made))))
      (mapc #'kill-buffer made))))

;;; Profile: this backend inherits, because it usually points at small models

(ert-deftest seance-gptel-profile-inherits-by-default ()
  (should (null (default-value 'seance-gptel-profile))))

(ert-deftest seance-gptel-inherited-profile-resolves-to-lean ()
  (let ((seance-gptel-profile nil)
        (seance-profile :lean))
    (should (eq :lean (or seance-gptel-profile seance-profile)))))

(ert-deftest seance-gptel-profile-can-override-the-global-default ()
  (let ((seance-gptel-profile :full)
        (seance-profile :lean))
    (should (eq :full (or seance-gptel-profile seance-profile)))))

(provide 'seance-gptel-test)
;;; seance-gptel-test.el ends here
