;;; seance-test.el --- ERT tests for the seance core  -*- lexical-binding: t; -*-

;;; Commentary:
;; CAPTURE (the log ring, truncation, focus stashing) and ASSEMBLE
;; (`seance-context-string-async' and how it picks a focus symbol).
;;
;; ASSEMBLE gets tested by stubbing `sly-eval-async', so no live image needed. The
;; image side has its own suite over in test/run-tests.lisp.
;;
;;   emacs -Q --batch -L . -L test -L $SLY_DIR -l test/seance-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sly)
(require 'seance)

;;; Helpers

(defmacro seance-test--with-clean-state (&rest body)
  "Run BODY with a fresh capture ring and predictable limits."
  (declare (indent 0))
  `(let ((seance--log nil)
         (seance--pending nil)
         (seance--last-focus nil)
         (seance--compiler-notes nil)
         (seance-log-size 12)
         (seance-form-limit 300)
         (seance-profile :lean))
     ,@body))

(defmacro seance-test--capturing-async-rpc (var reply &rest body)
  "Run BODY with SLY connected and `sly-eval-async' stubbed.
Records the form the stub was handed into VAR and immediately calls the
continuation with REPLY, so the callback has already run by the time BODY's
assertions execute. Assertions therefore belong inside BODY."
  (declare (indent 2))
  (let ((arg  (gensym "rpc-form-"))
        (cont (gensym "rpc-cont-")))
    `(let ((,var nil))
       (cl-letf (((symbol-function 'sly-connected-p) (lambda (&rest _) t))
                 ((symbol-function 'sly-eval-async)
                  (lambda (,arg &optional ,cont &rest _)
                    (setq ,var ,arg)
                    (when ,cont (funcall ,cont ,reply)))))
         ,@body))))

;;; CAPTURE: truncation

(ert-deftest seance-truncate-leaves-short-strings-alone ()
  (let ((seance-form-limit 10))
    (should (equal "abc" (seance--truncate "abc")))))

(ert-deftest seance-truncate-caps-long-strings ()
  (let ((seance-form-limit 3))
    (should (equal "abc ..." (seance--truncate "abcdef")))))

(ert-deftest seance-truncate-passes-nil-through ()
  (should (null (seance--truncate nil))))

;;; CAPTURE: the ring

(ert-deftest seance-record-pushes-newest-first ()
  (seance-test--with-clean-state
    (seance--record 'eval "(first)" "1")
    (seance--record 'eval "(second)" "2")
    (should (equal "(second)" (plist-get (car seance--log) :form)))))

(ert-deftest seance-record-caps-the-ring ()
  (seance-test--with-clean-state
    (let ((seance-log-size 3))
      (dotimes (i 10) (seance--record 'eval (format "(form %d)" i) "v"))
      (should (= 3 (length seance--log)))
      (should (equal "(form 9)" (plist-get (car seance--log) :form))))))

(ert-deftest seance-record-truncates-both-form-and-result ()
  (seance-test--with-clean-state
    (let ((seance-form-limit 2))
      (seance--record 'eval "abcdef" "ghijkl")
      (let ((e (car seance--log)))
        (should (equal "ab ..." (plist-get e :form)))
        (should (equal "gh ..." (plist-get e :result)))))))

(ert-deftest seance-clear-log-empties-ring-and-pending ()
  (seance-test--with-clean-state
    (setq seance--log '(:x) seance--pending "(pending)")
    (seance-clear-log)
    (should (null seance--log))
    (should (null seance--pending))))

;;; CAPTURE: eval/result pairing

(ert-deftest seance-note-result-without-pending-form-is-ignored ()
  (seance-test--with-clean-state
    (seance--note-result "stray")
    (should (null seance--log))))

(ert-deftest seance-note-transcript-then-result-pairs-them ()
  (seance-test--with-clean-state
    (with-temp-buffer
      (lisp-mode)
      (seance--note-transcript '(slynk:interactive-eval "(+ 1 1)")))
    (seance--note-result "2")
    (let ((e (car seance--log)))
      (should (equal "(+ 1 1)" (plist-get e :form)))
      (should (equal "2" (plist-get e :result))))
    ;; pending is consumed, so a second result does not double-record
    (seance--note-result "3")
    (should (= 1 (length seance--log)))))

;;; CAPTURE: focus stashing

(ert-deftest seance-stash-focus-remembers-symbol-under-point ()
  (seance-test--with-clean-state
    (with-temp-buffer
      (lisp-mode)
      (insert "(defun my-defun () nil)")
      (goto-char (point-min))
      (search-forward "my-defun")
      (backward-char 2)
      (seance--stash-focus))
    (should (equal "my-defun" (car seance--last-focus)))))

(ert-deftest seance-note-transcript-stashes-focus ()
  ;; capture advice runs while point is still in the Lisp buffer
  (seance-test--with-clean-state
    (with-temp-buffer
      (lisp-mode)
      (insert "(my-defun 1)")
      (goto-char (point-min))
      (forward-char 2)
      (seance--note-transcript '(slynk:interactive-eval "(my-defun 1)")))
    (should (equal "my-defun" (car seance--last-focus)))))

;;; ASSEMBLE: rendering

(ert-deftest seance-render-log-is-empty-when-log-is-empty ()
  (seance-test--with-clean-state
    (should (equal "" (seance--render-log)))))

(ert-deftest seance-render-log-orders-oldest-first ()
  ;; the ring is newest-first; the prompt wants newest *last*
  (seance-test--with-clean-state
    (seance--record 'eval "(older)" "1")
    (seance--record 'eval "(newer)" "2")
    (let ((out (seance--render-log)))
      (should (< (string-match-p (regexp-quote "(older)") out)
                 (string-match-p (regexp-quote "(newer)") out))))))

(ert-deftest seance-render-log-marks-defs-and-shows-eval-results ()
  (seance-test--with-clean-state
    (seance--record 'def "(defun f ())")
    (seance--record 'eval "(+ 1 1)" "2")
    (let ((out (seance--render-log)))
      (should (string-match-p (regexp-quote "(def) (defun f ())") out))
      (should (string-match-p (regexp-quote "(+ 1 1)\n => 2") out)))))

(ert-deftest seance-render-log-says-so-for-a-missing-result ()
  (seance-test--with-clean-state
    (seance--record 'eval "(hangs)" nil)
    (should (string-match-p (regexp-quote "=> (no value: aborted, or still running)")
                            (seance--render-log)))))

;;; ASSEMBLE: focus resolution, the bug that made the merge worth doing.
;;;
;;; Old sly-claude.el called (sly-symbol-at-point) unconditionally, then
;;; assembled context from inside its own chat buffer. So the focus it shipped
;;; was whatever word your cursor was parked on in your own prose ("slow", out
;;; of "why is my defun slow"), or just nil. These keep it fixed.

(ert-deftest seance-focus-comes-from-point-inside-a-lisp-buffer ()
  (seance-test--with-clean-state
    (with-temp-buffer
      (lisp-mode)
      (insert "(frobnicate 1)")
      (goto-char (point-min))
      (forward-char 2)
      (should (equal "frobnicate" (car (seance--focus)))))))

(ert-deftest seance-focus-falls-back-to-stash-outside-lisp-buffers ()
  (seance-test--with-clean-state
    (setq seance--last-focus (cons "my-defun" "MY-PKG"))
    (with-temp-buffer                   ; fundamental-mode: a chat buffer
      (insert "why is my defun slow")
      (goto-char (point-max))
      (backward-word 1)                 ; point is on "slow"
      (let ((focus (seance--focus)))
        (should (equal "my-defun" (car focus)))
        (should (equal "MY-PKG" (cdr focus)))
        (should-not (equal "slow" (car focus)))))))

(ert-deftest seance-focus-defaults-package-when-nothing-is-stashed ()
  (seance-test--with-clean-state
    (with-temp-buffer
      (insert "prose")
      (let ((focus (seance--focus)))
        (should (null (car focus)))
        (should (equal "COMMON-LISP-USER" (cdr focus)))))))

;;; ASSEMBLE: the async RPC, the path every transport uses.

(ert-deftest seance-async-context-does-not-touch-the-image-when-disconnected ()
  (seance-test--with-clean-state
    (let ((called nil) (got nil))
      (cl-letf (((symbol-function 'sly-connected-p) (lambda (&rest _) nil))
                ((symbol-function 'sly-eval-async) (lambda (&rest _) (setq called t))))
        (with-temp-buffer
          (seance-context-string-async (lambda (s) (setq got s)))))
      (should-not called)
      (should (string-match-p "not connected" got)))))

(ert-deftest seance-async-context-names-the-rpc-by-string-not-by-symbol ()
  ;; the entire reason the form resolves IMAGE-CONTEXT at runtime: mentioning
  ;; the package literally makes an image that never loaded the contrib fail at
  ;; read time, instead of coming back with a note we can show the user.
  (seance-test--with-clean-state
    (seance-test--capturing-async-rpc form "<<IMAGE>>"
      (with-temp-buffer (seance-context-string-async #'ignore))
      (let ((printed (prin1-to-string form))
            (symbols nil))
        (should (string-match-p "find-package" printed))
        (should (string-match-p "\"IMAGE-CONTEXT\"" printed))
        ;; walk for symbols rather than grepping the printed form: the note the
        ;; RPC returns on failure has SLYNK-SEANCE:IMAGE-CONTEXT in its text,
        ;; and a string is exactly what we do not mind being in there.
        (letrec ((walk (lambda (x)
                         (cond ((consp x) (funcall walk (car x))
                                          (funcall walk (cdr x)))
                               ((symbolp x) (push x symbols))))))
          (funcall walk form))
        (should-not
         (cl-find-if (lambda (s)
                       (string-prefix-p "slynk-seance:" (symbol-name s) t))
                     symbols))))))

(ert-deftest seance-async-context-sends-focus-package-and-profile ()
  (seance-test--with-clean-state
    (setq seance--last-focus (cons "my-defun" "MY-PKG"))
    (seance-test--capturing-async-rpc form "<<IMAGE>>"
      (with-temp-buffer
        (insert "prose")
        (seance-context-string-async #'ignore :full))
      (let ((printed (prin1-to-string form)))
        (should (string-match-p "\"my-defun\"" printed))
        (should (string-match-p "\"MY-PKG\"" printed))
        (should (string-match-p ":full" printed))))))

(ert-deftest seance-async-context-appends-the-eval-log ()
  (seance-test--with-clean-state
    (seance--record 'eval "(+ 1 1)" "2")
    (let ((got nil))
      (seance-test--capturing-async-rpc _form "<<IMAGE>>"
        (with-temp-buffer
          (seance-context-string-async (lambda (s) (setq got s)))))
      (should (string-prefix-p "<<IMAGE>>" got))
      (should (string-match-p (regexp-quote "RECENT EVALS") got))
      (should (string-match-p (regexp-quote "(+ 1 1)") got)))))

(ert-deftest seance-async-context-runs-its-callback-in-the-calling-buffer ()
  ;; a chat buffer's callback has to edit the chat buffer, not whatever buffer
  ;; happened to be current whenever the image got around to answering
  (seance-test--with-clean-state
    (let ((home (generate-new-buffer " *seance-test-home*"))
          (seen nil))
      (unwind-protect
          (seance-test--capturing-async-rpc _form "<<IMAGE>>"
            (with-current-buffer home
              (seance-context-string-async (lambda (_s) (setq seen (current-buffer))))))
        (kill-buffer home))
      (should (eq seen home)))))

(ert-deftest seance-async-context-drops-a-callback-whose-buffer-died ()
  (seance-test--with-clean-state
    (let ((home (generate-new-buffer " *seance-test-doomed*"))
          (called nil))
      (cl-letf (((symbol-function 'sly-connected-p) (lambda (&rest _) t))
                ((symbol-function 'sly-eval-async)
                 (lambda (_form &optional cont &rest _)
                   (kill-buffer home)   ; the image answers after you gave up
                   (when cont (funcall cont "<<IMAGE>>")))))
        (with-current-buffer home
          (seance-context-string-async (lambda (_s) (setq called t)))))
      (should-not called))))

;;; The total snapshot budget. Every other limit is per item.

(ert-deftest seance-context-limit-leaves-a-small-snapshot-alone ()
  (seance-test--with-clean-state
    (let ((seance-context-limit 100))
      (should (equal "short" (seance--trim-context "short"))))))

(ert-deftest seance-context-limit-trims-and-says-so ()
  (seance-test--with-clean-state
    (let* ((seance-context-limit 10)
           (out (seance--trim-context (make-string 500 ?x))))
      (should (string-prefix-p (make-string 10 ?x) out))
      (should (string-match-p "trimmed to 10 chars" out))
      ;; the marker is allowed past the cap; the payload is not
      (should (< (length out) 100)))))

(ert-deftest seance-context-limit-nil-means-no-cap ()
  (seance-test--with-clean-state
    (let ((seance-context-limit nil))
      (should (= 500 (length (seance--trim-context (make-string 500 ?x))))))))

(ert-deftest seance-async-context-honors-the-total-limit ()
  (seance-test--with-clean-state
    (let ((seance-context-limit 12)
          (got nil))
      (seance-test--capturing-async-rpc _form (make-string 400 ?y)
        (with-temp-buffer
          (seance-context-string-async (lambda (s) (setq got s)))))
      (should (string-match-p "trimmed to 12 chars" got)))))

;;; Trimming a section at a time

(defun seance-test--snapshot ()
  "A snapshot shaped like a real one, with every section a known size."
  (concat "=== LISP IMAGE CONTEXT (full) ===\nPackage: P\n"
          "\n--- FOCUS: FOO ---\n" (make-string 200 ?f) "\n"
          "\n--- NEIGHBORS (one hop out) ---\n" (make-string 300 ?n) "\n"
          "\n--- REPL ---\n" (make-string 100 ?r) "\n"
          "\n--- RECENT EVALS (newest last) ---\n"
          "(oldest)\n" (make-string 200 ?e) "\n(newest)\n"))

(ert-deftest seance-split-sections-gives-back-the-whole-string ()
  (let* ((s (seance-test--snapshot))
         (sections (seance--split-sections s)))
    (should (equal s (mapconcat #'cdr sections "")))
    (should (equal '(nil "FOCUS" "NEIGHBORS" "REPL" "RECENT EVALS")
                   (mapcar #'car sections)))))

(ert-deftest seance-trim-takes-the-neighbors-first ()
  (let* ((s (seance-test--snapshot))
         (seance-context-limit (- (length s) 100))
         (out (seance--trim-context s)))
    (should (<= (length out) seance-context-limit))
    (should (string-match-p "--- NEIGHBORS" out))
    (should (string-match-p "chars trimmed" out))
    ;; nothing else had to give
    (should (string-match-p (make-string 200 ?f) out))
    (should (string-match-p (make-string 100 ?r) out))
    (should (string-match-p (regexp-quote "(oldest)") out))))

(ert-deftest seance-trim-keeps-every-heading-and-the-newest-evals ()
  (let* ((s (seance-test--snapshot))
         (seance-context-limit 450)
         (out (seance--trim-context s)))
    (should (<= (length out) seance-context-limit))
    (dolist (heading '("--- FOCUS: FOO ---" "--- NEIGHBORS" "--- REPL ---"
                       "--- RECENT EVALS"))
      (should (string-match-p (regexp-quote heading) out)))
    ;; the eval log gives up its oldest entries, not its newest
    (should (string-match-p (regexp-quote "(newest)") out))
    (should-not (string-match-p (regexp-quote "(oldest)") out))
    ;; and the focus, last in line, kept some of its definition
    (should (string-match-p "fff" out))))

(ert-deftest seance-trim-falls-back-to-the-end-when-sections-are-not-enough ()
  (let* ((seance-context-limit 30)
         (out (seance--trim-context (seance-test--snapshot))))
    (should (string-match-p "trimmed to 30 chars" out))))

;;; Compiler notes and file compiles

(defun seance-test--note (severity message file)
  (list :severity severity :message message
        :location (list :location (list :file file) '(:position 1) nil)))

(ert-deftest seance-compilation-keeps-the-notes-one-line-each ()
  (seance-test--with-clean-state
    (seance--note-compilation
     nil (list (seance-test--note :warning "undefined function:\n  FROB" "/src/a.lisp")
               (seance-test--note :style-warning "unused X" "/src/a.lisp"))
     nil t)
    (should (equal '("warning: undefined function: FROB (a.lisp)"
                     "style-warning: unused X (a.lisp)")
                   seance--compiler-notes))
    (let ((out (seance--render-compiler-notes)))
      (should (string-match-p "--- COMPILER NOTES (last compile) ---" out))
      (should (string-match-p "unused X" out)))))

(ert-deftest seance-compilation-without-notes-clears-the-old-ones ()
  (seance-test--with-clean-state
    (setq seance--compiler-notes '("warning: stale"))
    (seance--note-compilation t nil nil t)
    (should-not seance--compiler-notes)
    (should (equal "" (seance--render-compiler-notes)))))

(ert-deftest seance-compilation-caps-the-notes ()
  (seance-test--with-clean-state
    (let ((seance-compiler-notes-limit 2))
      (seance--note-compilation
       nil (make-list 5 (seance-test--note :warning "w" "/a.lisp")) nil t)
      (should (= 2 (length seance--compiler-notes))))))

(ert-deftest seance-file-compile-enters-the-log ()
  (seance-test--with-clean-state
    (with-temp-buffer
      (setq buffer-file-name "/src/thing.lisp")
      (seance--note-compilation t nil (current-buffer) t)
      (setq buffer-file-name nil))
    (should (string-match-p (regexp-quote "(file) /src/thing.lisp => compiled and loaded")
                            (seance--render-log)))))

(ert-deftest seance-defun-compile-stays-out-of-the-file-log ()
  ;; C-c C-c passes no buffer; its form is logged by the compile advice
  (seance-test--with-clean-state
    (seance--note-compilation t nil nil t)
    (should-not seance--log)))

(ert-deftest seance-install-hooks-compilation-and-connection ()
  (unwind-protect
      (progn
        (seance-install)
        (should (memq #'seance--note-compilation sly-compilation-finished-hook))
        (should (memq #'seance--sync-automatic-conditions sly-connected-hook))
        (seance-uninstall)
        (should-not (memq #'seance--note-compilation sly-compilation-finished-hook))
        (should-not (memq #'seance--sync-automatic-conditions sly-connected-hook)))
    (seance-uninstall)))

;;; Automatic conditions: one request on connect, by name

(ert-deftest seance-automatic-conditions-asks-the-image-by-name ()
  (dolist (setting '(t nil))
    (let ((seance-automatic-conditions setting))
      (seance-test--capturing-async-rpc form nil
        (seance--sync-automatic-conditions)
        (let ((printed (prin1-to-string form)))
          (should (string-match-p "\"AUTOMATIC-CONDITIONS\"" printed))
          (should-not (string-match-p "slynk-seance:automatic" printed))
          (should (string-match-p (format "(cl:funcall fn %s)" setting) printed)))))))

;;; An open debugger

(defmacro seance-test--with-sldb (&rest body)
  "Run BODY with one fake SLDB buffer open, at level 2."
  (declare (indent 0))
  `(let ((sldb (generate-new-buffer " *seance-test-sldb*")))
     (unwind-protect
         (progn
           (with-current-buffer sldb
             (setq major-mode 'sly-db-mode
                   sly-db-level 2
                   sly-db-condition '("The value NIL is not a NUMBER" "   [Condition of type TYPE-ERROR]")
                   sly-db-restarts '(("RETRY" "Retry the request")
                                     ("ABORT" "Return to the top level")))
             (insert "Backtrace:\n")
             (setq sly-db-backtrace-start-marker (point-marker))
             (dotimes (i 2) (insert (format "  %d: (FRAME-%d)\n" i i)))
             (insert "  --more--\n"))
           (cl-letf (((symbol-function 'sly-db-buffers) (lambda (&rest _) (list sldb))))
             ,@body))
       (kill-buffer sldb))))

(ert-deftest seance-debugger-is-empty-without-one ()
  (cl-letf (((symbol-function 'sly-db-buffers) (lambda (&rest _) nil)))
    (should (equal "" (seance--render-debugger)))))

(ert-deftest seance-debugger-carries-condition-restarts-and-top-frames ()
  (seance-test--with-sldb
    (let* ((seance-debugger-frames 3)
           (out (seance--render-debugger)))
      (should (string-match-p "--- DEBUGGER (level 2) ---" out))
      (should (string-match-p "The value NIL is not a NUMBER" out))
      (should (string-match-p (regexp-quote "\n [Condition of type TYPE-ERROR]") out))
      (should (string-match-p (regexp-quote "1: [ABORT] Return to the top level") out))
      (should (string-match-p (regexp-quote "\n  1: (FRAME-1)\n") out))
      (should-not (string-match-p "--more--" out)))))

(ert-deftest seance-debugger-shows-only-the-top-frames ()
  (seance-test--with-sldb
    (let ((seance-debugger-frames 1))
      (should-not (string-match-p (regexp-quote "(FRAME-1)") (seance--render-debugger))))))

(ert-deftest seance-debugger-left-by-stepping-is-not-open ()
  (seance-test--with-sldb
    (with-current-buffer sldb (setq sly-db-level nil))
    (should (equal "" (seance--render-debugger)))))

(ert-deftest seance-async-context-carries-the-debugger ()
  (seance-test--with-clean-state
    (seance-test--with-sldb
      (let ((got nil))
        (seance-test--capturing-async-rpc _form "<<IMAGE>>"
          (with-temp-buffer
            (seance-context-string-async (lambda (s) (setq got s)))))
        (should (string-match-p "<<IMAGE>>\n--- DEBUGGER" got))))))

;;; Evaluating a code block from the chat

(defconst seance-test--chat
  "Try this:\n\n```lisp\n(defun foo () 1)\n(foo)\n```\n\nor that:\n\n```\n(bar)\n```\n")

(ert-deftest seance-fenced-block-is-found-around-point ()
  (with-temp-buffer
    (insert seance-test--chat)
    (should (equal "(defun foo () 1)\n(foo)\n"
                   (seance--fenced-block-at (progn (goto-char (point-min))
                                                   (search-forward "(foo)")
                                                   (point)))))
    (should (equal "(bar)\n"
                   (seance--fenced-block-at (progn (search-forward "(bar")
                                                   (point)))))))

(ert-deftest seance-fenced-block-is-nil-in-prose ()
  (with-temp-buffer
    (insert seance-test--chat)
    (should-not (seance--fenced-block-at (point-min)))
    (should-not (seance--fenced-block-at
                 (progn (goto-char (point-min)) (search-forward "or that") (point))))))

(ert-deftest seance-eval-block-evaluates-in-the-focus-package-and-logs ()
  (seance-test--with-clean-state
    (setq seance--last-focus (cons "my-defun" "MY-PKG"))
    (let ((sent nil) (package nil))
      ;; `sly-eval-with-transcript' goes out through `sly-rex', which is a
      ;; macro, so catch it one step later, as the event it dispatches
      (cl-letf (((symbol-function 'sly-dispatch-event)
                 (lambda (event &rest _)
                   (setq sent (nth 1 event) package (nth 2 event)))))
        (with-temp-buffer
          (setq seance--chat-transport "claude")
          (insert seance-test--chat)
          (goto-char (point-min))
          (search-forward "(foo)")
          (seance-install)
          (unwind-protect (seance-eval-block (point))
            (seance-uninstall))))
      (should (equal '(slynk:interactive-eval-region "(defun foo () 1)\n(foo)") sent))
      (should (equal "MY-PKG" package))
      ;; logged like any other eval, and the focus did not move to the chat
      (should (equal "(defun foo () 1)\n(foo)" (plist-get (car seance--log) :form)))
      (should (equal '("my-defun" . "MY-PKG") seance--last-focus)))))

(ert-deftest seance-eval-block-refuses-outside-a-block ()
  (with-temp-buffer
    (insert "no code here")
    (should-error (seance-eval-block (point-min)) :type 'user-error)))

;;; Profile resolution, shared by both transports

(ert-deftest seance-profile-helper-prefers-the-override ()
  (let ((seance-profile :lean))
    (should (eq :full (seance--profile :full)))
    (should (eq :lean (seance--profile nil)))
    (should (eq :lean (seance--profile)))))

;;; Wiring

(ert-deftest seance-contrib-loads-the-shared-image-side ()
  ;; one contrib, one image load, however many backends are loaded
  (should (equal '(slynk-seance)
                 (sly-contrib--slynk-dependencies (sly-contrib--find-contrib 'seance))))
  (should (file-readable-p (expand-file-name "slynk-seance.lisp" seance--path))))

(ert-deftest seance-defaults-to-the-lean-profile ()
  (should (eq :lean (default-value 'seance-profile))))

(provide 'seance-test)
;;; seance-test.el ends here
