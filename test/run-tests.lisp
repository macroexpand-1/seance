;;;; run-tests.lisp: test suite for slynk-seance.lisp
;;;;
;;;; Dependency-free: no test framework, just SBCL and a slynk to load against.
;;;;
;;;;   sbcl --script test/run-tests.lisp
;;;;
;;;; slynk is located, in order:
;;;;   1. $SEANCE_SLYNK_LOADER: absolute path to slynk-loader.lisp
;;;;   2. Quicklisp, if ~/quicklisp/setup.lisp exists  (ql:quickload :slynk)
;;;;   3. a few well-known straight.el / ELPA checkouts
;;;;
;;;; Exits non-zero if any assertion fails.

(require :asdf)
(require :uiop)

;;; harness

(defvar *passed* 0)
(defvar *failed* '())

(defun chk (name ok)
  (if ok
      (progn (incf *passed*) (format t "  ok    ~A~%" name))
      (progn (push name *failed*) (format t "  FAIL  ~A~%" name))))

(defun chk= (name expected actual)
  (let ((ok (equal expected actual)))
    (chk name ok)
    (unless ok
      (format t "          expected: ~S~%          actual:   ~S~%" expected actual))))

(defmacro section (title &body body)
  `(progn (format t "~&~%== ~A ==~%" ,title) ,@body))

(defun contains (needle haystack)
  (and (search needle haystack) t))

(defun count-matches (needle haystack)
  (loop for start = (search needle haystack) then (search needle haystack :start2 (1+ start))
        while start
        count t))

;;; locate slynk

(defun slynk-loader-path ()
  (let ((env (uiop:getenv "SEANCE_SLYNK_LOADER")))
    (when (and env (probe-file env))
      (return-from slynk-loader-path (probe-file env))))
  (let ((ql (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
    (when (probe-file ql)
      (load ql)
      (funcall (read-from-string "ql:quickload") :slynk :silent t)
      (return-from slynk-loader-path nil)))       ; loaded via quicklisp
  (dolist (glob '("~/.config/emacs/.local/straight/repos/sly/slynk/slynk-loader.lisp"
                  "~/.emacs.d/.local/straight/repos/sly/slynk/slynk-loader.lisp"
                  "~/.emacs.d/straight/repos/sly/slynk/slynk-loader.lisp"))
    (let ((p (probe-file (uiop:native-namestring (uiop:parse-native-namestring glob)))))
      (when p (return-from slynk-loader-path p))))
  (format *error-output* "~&No slynk found. Set SEANCE_SLYNK_LOADER=/path/to/slynk-loader.lisp~%")
  (uiop:quit 2))

(let ((loader (slynk-loader-path)))
  (when loader
    (load loader)
    (funcall (read-from-string "slynk-loader:init") :setup nil)))

(unless (find-package :slynk-api)
  (format *error-output* "~&slynk loaded but :SLYNK-API is missing.~%")
  (uiop:quit 2))

;;; load fixture + unit under test

(defvar *here* (uiop:pathname-directory-pathname *load-truename*))

;; compile-file so xref + code-object callees exist, into a scratch dir.
(let ((tmp (uiop:ensure-directory-pathname
            (uiop:merge-pathnames* "seance-test-build/" (uiop:temporary-directory)))))
  (ensure-directories-exist tmp)
  (load (compile-file (merge-pathnames "fixture.lisp" *here*)
                      :output-file (merge-pathnames "fixture.fasl" tmp)
                      :verbose nil :print nil)))

(load (merge-pathnames "../slynk-seance.lisp" *here*))

(defmacro sq (name) `(find-symbol ,(string-upcase (string name)) :slynk-seance))
(defun call-sq (name &rest args) (apply (symbol-function (find-symbol (string-upcase name) :slynk-seance)) args))

(defun image-context (&rest args)
  (apply #'call-sq "IMAGE-CONTEXT" args))

;;; tests

(section "loading"
  (chk "package :slynk-seance exists" (and (find-package :slynk-seance) t))
  (chk "image-context is fbound"      (and (sq image-context) (fboundp (sq image-context))))
  (chk "note-condition is exported"
       (eq :external (nth-value 1 (find-symbol "IMAGE-CONTEXT" :slynk-seance)))))

(section "xref-names: regression, :NOT-IMPLEMENTED must not blow up MAPCAR"
  ;; slynk-backend:calls-who answers :NOT-IMPLEMENTED on SBCL. Before the fix
  ;; this reached MAPCAR, signaled, got swallowed, and silently produced an
  ;; empty callee list, making the whole one-hop expansion dead code.
  (chk= ":not-implemented -> nil" nil (call-sq "XREF-NAMES" :not-implemented))
  (chk= "nil -> nil"              nil (call-sq "XREF-NAMES" nil))
  (chk= "(name . loc) pairs"      '(foo) (call-sq "XREF-NAMES" '((foo . :loc))))
  (chk= "bare names"              '(foo) (call-sq "XREF-NAMES" '(foo)))
  (chk= "dedupes"                 '(foo) (call-sq "XREF-NAMES" '((foo . :a) (foo . :b)))))

(section "callers / callees against compiled fixture"
  ;; names come back as function names (symbols), not strings; STRING-EQUAL
  ;; compares a symbol by its name.
  (let ((callers (call-sq "CALLERS" 'seance-fixture:focus))
        (callees (call-sq "CALLEES" 'seance-fixture:focus)))
    (chk "focus is called by CALLER"  (member "CALLER" callers :test #'string-equal))
    (chk "focus calls CALLEE-A"       (member "CALLEE-A" callees :test #'string-equal))
    (chk "focus calls CALLEE-B"       (member "CALLEE-B" callees :test #'string-equal))
    (chk "callees is non-empty (calls-who is :not-implemented on SBCL)" callees))
  (chk "callees of an unbound symbol is empty" (null (call-sq "CALLEES" 'no-such-fn-anywhere)))
  (chk "callers of an unbound symbol is empty" (null (call-sq "CALLERS" 'no-such-fn-anywhere))))

(section "helpers"
  (chk "resolve-symbol is case-insensitive like the reader"
       (eq 'seance-fixture:focus (call-sq "RESOLVE-SYMBOL" "focus" :seance-fixture)))
  (chk "resolve-symbol handles package qualifiers"
       (eq 'seance-fixture:focus (call-sq "RESOLVE-SYMBOL" "seance-fixture:focus" :cl-user)))
  (chk "resolve-symbol returns nil on garbage"
       (null (call-sq "RESOLVE-SYMBOL" "#<not a symbol" :cl-user)))
  (chk "resolve-symbol does not eval"
       (null (call-sq "RESOLVE-SYMBOL" "#.(error \"pwned\")" :cl-user)))
  ;; describing the image must not modify it: a typo under point used to get
  ;; interned into the user's package and stay there.
  (chk "resolve-symbol returns nil for a name the package does not have"
       (null (call-sq "RESOLVE-SYMBOL" "no-such-symbol-please" :seance-fixture)))
  (chk "resolve-symbol interned nothing while failing"
       (null (nth-value 1 (find-symbol "NO-SUCH-SYMBOL-PLEASE" :seance-fixture))))
  (chk "resolve-symbol leaves no scratch packages behind"
       (notany (lambda (p) (search "SEANCE-READ-" (package-name p)))
               (list-all-packages)))
  (chk "first-line stops at newline"
       (string= "a" (call-sq "FIRST-LINE" (format nil "a~%b"))))
  (chk "truncate-print caps length"
       (<= (length (call-sq "TRUNCATE-PRINT" (make-list 500 :initial-element 'x) 40)) 45))
  (chk "subseq-safe tolerates n > length"
       (equal '(1 2) (call-sq "SUBSEQ-SAFE" '(1 2) 99))))

(section "symbol-summary: a sprawling interactive definition gets capped"
  ;; EVAL, not COMPILE-FILE: SBCL only retains the lambda expression for
  ;; interactively defined functions, which is exactly the case the cap exists
  ;; for. Everything you care about at a live REPL you defined interactively,
  ;; so uncapped this branch is the one that dominates the snapshot.
  (eval (read-from-string
         (with-output-to-string (src)
           (format src "(defun seance-fixture::sprawler (x) \"Sprawler doc.\" (declare (ignore x)) (list")
           (dotimes (i 300)
             (format src " ~S" "A Fairly Long String Element That Pads This Definition Out"))
           (format src "))"))))
  (let* ((sym     (find-symbol "SPRAWLER" :seance-fixture))
         (lex     (nth-value 0 (function-lambda-expression (fdefinition sym))))
         (summary (call-sq "SYMBOL-SUMMARY" sym))
         (cap     (symbol-value (sq *max-definition-chars*))))
    ;; if SBCL ever stops retaining this, the cap goes untested rather than
    ;; silently broken, so assert the precondition before the behavior.
    (chk "SBCL retained the lambda expression (else this proves nothing)" lex)
    (chk "uncapped the definition would have been enormous"
         (> (length (prin1-to-string lex)) (* 4 cap)))
    (chk "summary stays within a doc line or two of the cap"
         (< (length summary) (+ cap 200)))
    (chk "the truncation is visibly marked" (contains "..." summary))
    (chk "the doc line still survives" (contains "doc: Sprawler doc." summary))
    ;; *print-case* :downcase replaced a ~(~S~) that also flattened string
    ;; literals inside the definition. Symbols downcase; strings must not.
    (chk "symbols are downcased"        (contains "(declare (ignore x))" summary))
    (chk "string literals keep their case"
         (contains "A Fairly Long String Element" summary))))

(section "note-condition"
  (setf (symbol-value (sq *conditions*)) '())
  (let* ((c (make-condition 'simple-error :format-control "ring me"))
         (returned (call-sq "NOTE-CONDITION" c)))
    (chk "returns its argument (transparent in handler-bind)" (eq c returned)))
  (chk "condition landed in the ring"
       (contains "ring me" (first (symbol-value (sq *conditions*)))))
  (dotimes (i 20)
    (call-sq "NOTE-CONDITION" (make-condition 'simple-error :format-control "spam")))
  (chk= "ring is capped at *max-conditions*"
        (symbol-value (sq *max-conditions*))
        (length (symbol-value (sq *conditions*)))))

(section "with-captured-conditions"
  (setf (symbol-value (sq *conditions*)) '())
  (chk "the macro is exported"
       (eq :external (nth-value 1 (find-symbol "WITH-CAPTURED-CONDITIONS" :slynk-seance))))
  ;; it observes and declines, so the error still reaches the caller's handler
  (let ((reached nil))
    (handler-case
        (eval (read-from-string
               "(slynk-seance:with-captured-conditions (error \"noted but not handled\"))"))
      (error () (setf reached t)))
    (chk "declines to handle, so the condition still propagates" reached))
  (chk "and the condition landed in the ring"
       (contains "noted but not handled" (first (symbol-value (sq *conditions*)))))
  ;; a body that does not signal returns its values untouched
  (chk= "passes values through"
        3
        (eval (read-from-string
               "(slynk-seance:with-captured-conditions (+ 1 2))"))))

(section "image-context: :full vs :lean"
  (setf (symbol-value (sq *conditions*)) '())
  (handler-case
      (handler-bind ((error (symbol-function (sq note-condition))))
        (error "boom line one~%boom line two"))
    (error () nil))

  (let ((full (image-context "focus" "SEANCE-FIXTURE" :full))
        (lean (image-context "focus" "SEANCE-FIXTURE" :lean)))

    (chk "full header tagged (full)" (contains "=== LISP IMAGE CONTEXT (full) ===" full))
    (chk "lean header tagged (lean)" (contains "=== LISP IMAGE CONTEXT (lean) ===" lean))
    (chk "package line"              (contains "Package: SEANCE-FIXTURE" full))
    (chk "focus block"               (contains "--- FOCUS: " full))

    (chk "full lists callers"        (contains "called-by:" full))
    (chk "full names the caller"     (contains "CALLER" full))
    (chk "full names a callee"       (contains "CALLEE-A" full))
    (chk "lean names a callee"       (contains "CALLEE-A" lean))

    (chk "focus doc is first line only" (contains "doc: Focus doc line one." full))
    (chk "focus docstring 2nd line withheld"
         (not (contains "Second line must not reach" full)))

    ;; the one-hop expansion is what :full buys you; it was dead before the
    ;; calls-who fix, so assert both halves.
    (chk "full expands one hop into callee docs"  (contains "Callee A doc." full))
    (chk "full does NOT expand two hops"          (not (contains "Leaf doc." full)))
    (chk "lean does not expand one hop"           (not (contains "Callee A doc." lean)))

    (chk "full puts the neighbors in their own section"
         (contains "--- NEIGHBORS (one hop out) ---" full))
    (chk "lean has no neighbors section" (not (contains "--- NEIGHBORS" lean)))

    (chk "full has a REPL section"   (contains "--- REPL ---" full))
    (chk "lean has a REPL section"   (contains "--- REPL ---" lean))

    (chk "full keeps multi-line condition text"   (contains "boom line two" full))
    (chk "lean trims condition to first line"     (and (contains "boom line one" lean)
                                                       (not (contains "boom line two" lean))))))

(section "image-context: degenerate inputs"
  (let ((no-focus (image-context nil "SEANCE-FIXTURE" :full))
        (bad      (image-context "nonexistent-symbol-xyz" "SEANCE-FIXTURE" :full))
        (bad-pkg  (image-context "focus" "NO-SUCH-PACKAGE" :full)))
    (chk "nil focus still yields a snapshot"    (contains "=== LISP IMAGE CONTEXT" no-focus))
    (chk "nil focus has no FOCUS block"         (not (contains "--- FOCUS:" no-focus)))
    (chk "unknown symbol does not signal"       (contains "=== LISP IMAGE CONTEXT" bad))
    (chk "unknown package does not signal"      (contains "=== LISP IMAGE CONTEXT" bad-pkg)))
  (chk "profile defaults to :lean"
       (contains "(lean)" (image-context "focus" "SEANCE-FIXTURE"))))

(section "image-context: the package arrives spelled as IN-PACKAGE spells it"
  ;; SLY sends the package string straight out of the buffer's IN-PACKAGE
  ;; form. FIND-PACKAGE only understood the first of these, so the others
  ;; silently lost the FOCUS section.
  (dolist (spelling '("SEANCE-FIXTURE" ":seance-fixture" "seance-fixture"
                      "#:seance-fixture"))
    (let ((out (image-context "focus" spelling :full)))
      (chk (format nil "~S finds the focus" spelling) (contains "--- FOCUS: " out))
      (chk (format nil "~S names the package properly" spelling)
           (contains "Package: SEANCE-FIXTURE" out)))))

(section "image-context: a callee in another package"
  (let ((full (image-context "reach" "SEANCE-FIXTURE" :full)))
    (chk "listed with its package prefix"
         (contains "calls: SEANCE-FIXTURE-UTIL:HELPER" full))
    (chk "expanded one hop out as itself"
         (contains "Helper doc, from another package." full)))
  (let ((focus (image-context "focus" "SEANCE-FIXTURE" :full)))
    (chk "a same-package callee prints bare"
         (and (contains "CALLEE-A" focus)
              (not (contains "SEANCE-FIXTURE:CALLEE-A" focus))))
    (chk "the focus definition has no package prefixes"
         (not (contains "seance-fixture::" focus)))
    (chk "the focus definition has no DEFUN block wrapper"
         (not (contains "(block focus" focus)))
    (chk "the focus name is printed once"
         (= 1 (count-matches "FOCUS:" focus)))))

(section "image-context: the REPL section"
  ;; a live request runs inside the listener's bindings; here, bind them.
  (let ((+ '(seance-fixture:focus 1))
        (++ '(defun seance-fixture:focus () "stale"))
        (+++ nil)
        (* 5)
        (** 'seance-fixture:focus)
        (*** "Third"))
    (let ((full (image-context "focus" "SEANCE-FIXTURE" :full))
          (lean (image-context "focus" "SEANCE-FIXTURE" :lean)))
      (chk "full shows the last form read, from the focus package"
           (contains " + (focus 1)" full))
      (chk "full shows older forms" (contains " ++ (defun focus" full))
      (chk "a form never read is left out" (not (contains " +++ " full)))
      (chk "full shows the last value" (contains " * 5" full))
      (chk "full shows older values" (contains " *** \"Third\"" full))
      (chk "lean shows the last form and value"
           (and (contains " + (focus 1)" lean) (contains " * 5" lean)))
      (chk "lean leaves the older ones out"
           (and (not (contains " ++ " lean)) (not (contains " ** " lean)))))))

(section "automatic conditions through *eval-for-emacs-wrappers*"
  (let ((slynk:*eval-for-emacs-wrappers* '()))
    (setf (symbol-value (sq *conditions*)) '())
    (chk "turning it on reports on"   (eq t (call-sq "AUTOMATIC-CONDITIONS" t)))
    (call-sq "AUTOMATIC-CONDITIONS" t)
    (chk "turning it on twice installs one wrapper"
         (= 1 (length slynk:*eval-for-emacs-wrappers*)))
    (let* ((wrapper (first slynk:*eval-for-emacs-wrappers*))
           (reached nil)
           (out (funcall wrapper (lambda () 42))))
      (chk "a quiet request passes its value through" (eql 42 (funcall out)))
      (handler-case
          (funcall (funcall wrapper (lambda () (error "escaped the request"))))
        (error () (setf reached t)))
      (chk "the condition still reaches slynk's handlers" reached)
      (chk "and it landed in the ring"
           (contains "escaped the request" (first (symbol-value (sq *conditions*))))))
    (chk "turning it off reports off" (null (call-sq "AUTOMATIC-CONDITIONS" nil)))
    (chk "turning it off removes the wrapper" (null slynk:*eval-for-emacs-wrappers*))))

;;; report

(format t "~&~%~A~%" (make-string 60 :initial-element #\-))
(if *failed*
    (progn
      (format t "~D passed, ~D FAILED:~%" *passed* (length *failed*))
      (dolist (f (reverse *failed*)) (format t "  - ~A~%" f))
      (uiop:quit 1))
    (progn
      (format t "all ~D assertions passed~%" *passed*)
      (uiop:quit 0)))
