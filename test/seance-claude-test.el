;;; seance-claude-test.el --- ERT tests for the claude CLI transport  -*- lexical-binding: t; -*-

;;; Commentary:
;; Argument construction, session ids, and the stream parser. The real `claude'
;; CLI never runs: it wants a login and costs tokens. The parser is tested
;; against test/fake-claude instead, which prints canned stream-json.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seance)
(require 'seance-claude)

;;; CLI argument construction

(ert-deftest seance-claude-base-args-are-streaming-json ()
  (let ((seance-claude-lean nil)
        (seance-claude-model nil)
        (seance-claude-extra-args nil))
    (let ((args (seance-claude--base-args nil)))
      (should (member "-p" args))
      (should (member "--output-format" args))
      (should (member "stream-json" args)))))

(ert-deftest seance-claude-base-args-honor-lean-model-and-extras ()
  (let ((seance-claude-lean t)
        (seance-claude-model "some-model")
        (seance-claude-extra-args '("--disallowed-tools" "Bash")))
    (let ((args (seance-claude--base-args '("--resume" "id"))))
      (should (member "--setting-sources" args))
      (should (member "some-model" args))
      (should (member "--disallowed-tools" args))
      ;; EXTRA lands last so it can override
      (should (equal '("--resume" "id") (last args 2))))))

(ert-deftest seance-claude-base-args-omit-model-when-nil ()
  (let ((seance-claude-lean nil)
        (seance-claude-model nil)
        (seance-claude-extra-args nil))
    (should-not (member "--model" (seance-claude--base-args nil)))))

(ert-deftest seance-claude-base-args-omit-lean-flags-when-disabled ()
  (let ((seance-claude-lean nil)
        (seance-claude-model nil)
        (seance-claude-extra-args nil))
    (should-not (member "--setting-sources" (seance-claude--base-args nil)))))

;;; Session ids

(ert-deftest seance-claude-uuid-is-v4-shaped-and-unique ()
  (let ((a (seance-claude--uuid)) (b (seance-claude--uuid)))
    (should (string-match-p
             "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'" a))
    (should-not (equal a b))))

;;; Missing CLI

(ert-deftest seance-claude-executable-errors-helpfully-when-missing ()
  (let ((seance-claude-program "definitely-not-a-real-program-xyz"))
    (should-error (seance-claude--executable) :type 'user-error)))

;;; Profile: this backend overrides the global default

(ert-deftest seance-claude-asks-for-the-full-profile-by-default ()
  (should (eq :full (default-value 'seance-claude-profile))))

(ert-deftest seance-claude-profile-nil-inherits-the-global-default ()
  (let ((seance-claude-profile nil)
        (seance-profile :lean))
    (should (eq :lean (or seance-claude-profile seance-profile)))))

;;; Sending outside a chat buffer

(ert-deftest seance-claude-send-refuses-outside-a-chat-buffer ()
  (with-temp-buffer
    (should-error (seance-claude-send) :type 'user-error)))

;;; The session only counts once the CLI says it made one.
;;;
;;; --started used to be set at dispatch. A first turn that died left the
;;; buffer resuming a session that never existed, which fails forever after.

(ert-deftest seance-claude-first-turn-is-not-started-until-it-succeeds ()
  (with-temp-buffer
    (setq seance-claude--session "abc" seance-claude--started nil)
    (let ((finalize nil))
      (cl-letf (((symbol-function 'seance-claude--spawn)
                 (lambda (_target _prompt _extra &optional fin)
                   (setq finalize fin)
                   nil)))
        (insert "## You\n\nhello")
        (setq seance-claude--input-start (copy-marker (point-min)))
        (cl-letf (((symbol-function 'seance-context-string-async)
                   (lambda (k &optional _p) (funcall k "<<IMAGE>>"))))
          (seance-claude-send))
        (should finalize)
        ;; the CLI failed, so the next send must still ask for --session-id
        (funcall finalize nil)
        (should-not seance-claude--started)
        ;; and a clean one flips it
        (funcall finalize t)
        (should seance-claude--started)))))

(ert-deftest seance-claude-send-refuses-while-a-turn-is-in-flight ()
  (with-temp-buffer
    (setq seance-claude--session "abc"
          seance-claude--input-start (copy-marker (point-min)))
    (insert "hello")
    (cl-letf (((symbol-function 'process-live-p) (lambda (&rest _) t)))
      (should-error (seance-claude-send) :type 'user-error))))

;;; The message boundary is a marker, not a search for "## You"

(ert-deftest seance-claude-send-takes-the-message-from-the-marker ()
  ;; an answer that happens to contain a "## You" line used to truncate the
  ;; next message at whatever Claude wrote
  (with-temp-buffer
    (setq seance-claude--session "abc" seance-claude--started t)
    (insert "## Claude\n\nhere is a heading:\n\n## You\n\nnot your message\n\n## You\n\n")
    (setq seance-claude--input-start (point-marker))
    (insert "the real message")
    (let ((prompt nil))
      (cl-letf (((symbol-function 'seance-claude--spawn)
                 (lambda (_target p &rest _) (setq prompt p) nil)))
        (seance-claude-send))
      (should (equal "the real message" prompt)))))

;;; Interrupting

(ert-deftest seance-claude-interrupt-refuses-when-nothing-is-running ()
  (with-temp-buffer
    (should-error (seance-claude-interrupt) :type 'user-error)))

;;; The stream parser, end to end against test/fake-claude

(defconst seance-claude-test--fake
  (expand-file-name "fake-claude"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "A stand-in CLI that prints canned stream-json; see the script.")

(defun seance-claude-test--run (scenario)
  "Run the fake CLI through the real transport for SCENARIO.
Returns (TEXT . OK): what landed in the target buffer, and what the finalize
callback was told about the exit."
  (let ((seance-claude-program seance-claude-test--fake)
        (process-environment (cons (concat "SEANCE_FAKE_CLAUDE=" scenario)
                                   process-environment))
        (target (generate-new-buffer " *seance-claude-test*"))
        (done nil)
        (ok nil))
    (unwind-protect
        (let ((proc (seance-claude--spawn target "the prompt" nil
                                          (lambda (exit-ok) (setq done t ok exit-ok)))))
          (with-timeout (10 (error "Fake claude never finished"))
            (while (not done)
              (accept-process-output proc 0.05)))
          (cons (with-current-buffer target (buffer-string)) ok))
      (kill-buffer target))))

(ert-deftest seance-claude-stream-puts-the-deltas-together ()
  (let ((run (seance-claude-test--run "streamed")))
    ;; the delta split across two writes arrives whole, the hook event and
    ;; the stderr line stay out, and the result does not repeat the deltas
    (should (equal "Hello, world." (car run)))
    (should (cdr run))))

(ert-deftest seance-claude-stream-falls-back-to-the-result ()
  (let ((run (seance-claude-test--run "result-only")))
    (should (equal "The whole answer." (car run)))
    (should (cdr run))))

(ert-deftest seance-claude-stream-says-so-when-claude-reports-an-error ()
  (let ((run (seance-claude-test--run "is-error")))
    (should (string-match-p ";; claude error: API Error: overloaded" (car run)))))

(ert-deftest seance-claude-stream-explains-a-failed-exit ()
  (let ((run (seance-claude-test--run "exit-1")))
    (should-not (cdr run))
    (should (string-match-p ";; claude exited 1" (car run)))
    ;; stderr is the only explanation the CLI gives, so it is kept
    (should (string-match-p "is already in use" (car run)))))

(ert-deftest seance-claude-stream-stays-quiet-about-a-requested-stop ()
  (let ((seance-claude-program seance-claude-test--fake)
        (process-environment (cons "SEANCE_FAKE_CLAUDE=streamed" process-environment))
        (target (generate-new-buffer " *seance-claude-test*"))
        (done nil))
    (unwind-protect
        (let ((proc (seance-claude--spawn target "the prompt" nil
                                          (lambda (_ok) (setq done t)))))
          (seance-claude--stop proc)
          (with-timeout (10 (error "Fake claude never finished"))
            (while (not done) (accept-process-output nil 0.05)))
          (let ((text (with-current-buffer target (buffer-string))))
            (should (string-match-p ";; stopped." text))
            (should-not (string-match-p "exited" text))))
      (kill-buffer target))))

(provide 'seance-claude-test)
;;; seance-claude-test.el ends here
