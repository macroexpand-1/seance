;;;; slynk-seance.lisp
;;;;
;;;; The image side of seance. Exposes one RPC, SLYNK-SEANCE:IMAGE-CONTEXT,
;;;; which returns a token-efficient snapshot of the live image for prepending
;;;; to an LLM prompt.
;;;;
;;;; I split it in two: a CL side and an ELisp side. EmacsLisp already has the data
;;;; and can capture it with stable advice. slynk-seance.lisp controls
;;;; what is inside the image: call-graph neighborhood, live REPL stuff, and noted conditions.
;;;;
;;;; The transports (seance-claude.el, seance-gptel.el) share this file, but they differ
;;;; in the PROFILE they ask for and where they send the result.
;;;;
;;;; SLY loads it as the slynk side of the SEANCE contrib (see seance.el), so
;;;; there is nothing to load by hand.
;;;;
;;;; Tested only against SBCL

#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-introspect))

(defpackage :slynk-seance
  (:use :cl)
  (:import-from :slynk-api #:defslyfun)
  (:export #:image-context
           #:note-condition
           #:with-captured-conditions
           #:*max-callers*
           #:*max-conditions*
           #:*max-neighbors*
           #:*max-definition-chars*))

(in-package :slynk-seance)

(defvar *max-callers* 12
  "Cap on the caller list. A hot function has hundreds of them and nobody reads
past the first dozen, so this stops one from swallowing the whole snapshot.")

(defvar *max-conditions* 5
  "Size of recent-conditions ring.")

(defvar *max-neighbors* 6
  "How many callees to expand one hop out in the focus neighborhood.")

(defvar *max-definition-chars* 600
  "Hard cap in chars on any one printed definition.
SBCL keeps the whole lambda expression for a function you defined at the REPL,
which is every function you actually care about here. Under :FULL we print one
for the focus symbol plus every neighbor, so uncapped a handful of ordinary
defuns crowds everything else out of the snapshot.")

(defvar *conditions* '()
  "Recent conditions, most recent first.")

;;; Conditions: you feed the ring yourself.
;;;
;;; slynk rebinds *DEBUGGER-HOOK* per request, so a global hook is already out
;;; of scope by the time your form runs. Wrap the form in
;;; WITH-CAPTURED-CONDITIONS (below), or put NOTE-CONDITION in a HANDLER-BIND
;;; of your own around something narrower.

(defun subseq-safe (list n)
  (subseq list 0 (min n (length list))))

(defun note-condition (condition)
  "Push CONDITION onto the recent-conditions ring and hand it right back, so
   this can sit inside a HANDLER-BIND without swallowing anything."
  (push (princ-to-string condition) *conditions*)
  (setf *conditions* (subseq-safe *conditions* *max-conditions*))
  condition)

(defmacro with-captured-conditions (&body body)
  "Run BODY, noting every SERIOUS-CONDITION signaled inside it into the ring.
   Declines to handle any of them: HANDLER-BIND observes and returns, so
   whatever would have happened without this still happens, SLDB included.

   Wrapping is not laziness on our part, it is the only thing that works.
   SLYNK-BACKEND:CALL-WITH-DEBUGGER-HOOK rebinds *DEBUGGER-HOOK* around every
   request, so a handler installed globally is out of scope by the time your
   form runs. Being inside the form's dynamic extent is the whole trick.

       (slynk-seance:with-captured-conditions
         (your-flaky-thing))

   SERIOUS-CONDITION rather than ERROR, so a STORAGE-CONDITION counts too.
   HANDLER-BIND yourself if you want warnings in there as well."
  `(handler-bind ((serious-condition #'note-condition))
     ,@body))

;;; With a little help(ers) of my friends

(defun resolve-package (designator)
  "The package DESIGNATOR names, or *PACKAGE* when it names none.
   SLY sends a package exactly as the buffer's IN-PACKAGE form spells it, so
   \":foo\", \"foo\", \"#:foo\" and \"FOO\" all have to mean FOO. FIND-PACKAGE
   only understands the last one. SLYNK::GUESS-PACKAGE is what slynk uses to
   read the package of every request, so this reads ours the same way."
  (or (typecase designator
        (string  (slynk::guess-package designator))
        (package designator)
        (symbol  (and designator (find-package designator))))
      *package*))

(defun resolve-symbol (name package-designator)
  "Reads NAME as a symbol in PACKAGE-DESIGNATOR but no eval. NIL on failure.
   Handles case and package qualifiers via reader, so FOO/foo/pkg:foo all behave
   the same as they do in the REPL.

   The reader interns whatever it reads, and a snapshot has no business leaving
   symbols behind in the image it is only meant to be describing: one typo
   under point would do it, permanently. So the read happens in a scratch
   package that gets deleted right after, and an unqualified name is then looked
   up in the real package with FIND-SYMBOL instead of interned into it.

   PKG::NAME for a name that does not exist yet is the case still interned, by
   the reader, into the package you went out of your way to spell."
  (let ((home    (resolve-package package-designator))
        (scratch (make-package (gensym "SEANCE-READ-") :use '())))
    (unwind-protect
         (handler-case
             (let ((obj (let ((*package* scratch)
                              (*read-eval* nil))
                          (read-from-string name))))
               (cond ((not (symbolp obj)) nil)
                     ;; unqualified, so the reader parked it in SCRATCH; ask
                     ;; the real package whether it has one by that name.
                     ((eq (symbol-package obj) scratch)
                      (find-symbol (symbol-name obj) home))
                     (t obj)))
           (error () nil))
      (delete-package scratch))))

(defun first-line (string)
  (let ((nl (position #\Newline string)))
    (if nl (subseq string 0 nl) string)))

(defun truncate-string (string limit)
  "STRING hard-truncated to LIMIT chars, ellipsized when it actually got cut."
  (if (> (length string) limit)
      (concatenate 'string (subseq string 0 limit) " ...")
      string))

(defun truncate-print (object &optional (limit 200))
  "PRIN1 OBJECT with depth/length caps, then hard-truncated to LIMIT chars."
  (truncate-string
   (let ((*print-length* 20)
         (*print-level* 4)
         (*print-readably* nil))
     (prin1-to-string object))
   limit))

(defun strip-name-block (lambda-expression name)
  "LAMBDA-EXPRESSION without the (BLOCK NAME ...) that DEFUN wraps its body in.
The block is implied by DEFUN, so printing it only spends characters and adds a
level of nesting a reader has to see through. Anything that is not a plain
(LAMBDA ARGS . BODY) comes back untouched."
  (if (and (consp lambda-expression)
           (eq (first lambda-expression) 'lambda)
           (consp (rest lambda-expression)))
      (destructuring-bind (lambda-word args &rest body) lambda-expression
        `(,lambda-word ,args
          ,@(mapcan (lambda (form)
                      (if (and (consp form)
                               (eq (first form) 'block)
                               (eq (second form) name))
                          (copy-list (cddr form))
                          (list form)))
                    body)))
      lambda-expression))

(defun truncate-definition (lambda-expression)
  "LAMBDA-EXPRESSION printed for a prompt: downcased, elided, hard-capped.
Looser depth and length limits than TRUNCATE-PRINT allows, because this is code
somebody has to follow rather than a REPL value they only need to recognize.
*PRINT-CASE* does the downcasing that the caller's ~( ~) used to, without also
flattening any string literals inside the definition."
  (truncate-string
   (let ((*print-length* 40)
         (*print-level* 8)
         (*print-readably* nil)
         (*print-case* :downcase))
     (prin1-to-string lambda-expression))
   *max-definition-chars*))

;;; Call graph. Names stay Lisp objects (a symbol, or a list like (SETF FOO))
;;; all the way to the printer, so a callee in another package keeps its
;;; package and can be expanded as itself. Turning them into strings early
;;; meant reading them back in the focus package, which found the wrong symbol
;;; or none at all for anything defined elsewhere.

(defun xref-names (result)
  "Deduped function names out of a SLYNK-BACKEND xref RESULT.
   A backend that can't answer says :NOT-IMPLEMENTED instead of signaling,
   so anything that isn't a list gets NIL. Don't hand a keyword to MAPCAR."
  (when (listp result)
    (remove-duplicates
     (mapcar (lambda (entry)
               ;; entries are like (name . loc) or (name loc); CAR is the name
               (if (consp entry) (car entry) entry))
             result)
     :test #'equal)))

(defun callers (symbol)
  "Who calls SYMBOL. Empty when there's no xref data."
  (handler-case (xref-names (slynk-backend:who-calls symbol))
    (error () '())))

(defun function-name (function)
  (nth-value 2 (function-lambda-expression function)))

(defun callees (symbol)
  "What SYMBOL calls. Empty when nobody can tell us.
   SLYNK-BACKEND:CALLS-WHO just says :NOT-IMPLEMENTED on SBCL, which is the
   only place this actually runs, so ask SB-INTROSPECT instead. Everyone else
   keeps the portable path. Without this the callee list is always empty and
   the one-hop expansion below never fires."
  (handler-case
      (or (xref-names (slynk-backend:calls-who symbol))
          #+sbcl
          (when (fboundp symbol)
            (remove-duplicates
             (remove nil
                     (mapcar #'function-name
                             (sb-introspect:find-function-callees
                              (fdefinition symbol))))
             :test #'equal)))
    (error () '())))

(defun implementation-symbol-p (symbol)
  "True when SYMBOL belongs to the Lisp itself rather than to user code.
A callee like SB-KERNEL:TWO-ARG-+ is a fact about how SBCL compiled your code,
not something you are asking about, so it is listed but never expanded. On
SBCL the implementation's packages are exactly the locked ones."
  (let ((package (symbol-package symbol)))
    (or (null package)
        (eq package (find-package :common-lisp))
        #+sbcl (sb-ext:package-locked-p package))))

(defun expandable-neighbors (focus callees)
  "The callees of FOCUS worth a summary of their own under :FULL."
  (remove-if-not (lambda (name)
                   (and (symbolp name)
                        (not (eq name focus))
                        (fboundp name)
                        (not (implementation-symbol-p name))))
                 callees))

(defun printed-names (names)
  "NAMES as strings for a one-line list, or a single \"<none>\" when empty.
PRIN1 under the caller's *PACKAGE*, so a prefix appears only when it is needed."
  (or (mapcar #'prin1-to-string names) '("<none>")))

(defun symbol-summary (symbol)
  "Definition (or arglist, when there is no definition) and the first doc line,
one indented line each. The name itself is the caller's to print."
  (with-output-to-string (s)
    (when (fboundp symbol)
      (let ((lex (ignore-errors
                  (nth-value 0
                             (function-lambda-expression
                              (fdefinition symbol))))))
        (cond
          ;; SBCL keeps this for interactive-defined fns. NIL otherwise
          (lex (format s " ~A~%" (truncate-definition
                                  (strip-name-block lex symbol))))
          (t (let ((arglist (ignore-errors (slynk-backend:arglist symbol))))
               (when (and arglist (not (eq arglist :not-available)))
                 (format s " arglist: ~(~A~)~%" arglist)))))
        (let ((doc (documentation symbol 'function)))
          (when doc (format s " doc: ~A~%" (first-line doc))))))))

(defun repl-values ()
  (with-output-to-string (s)
    (loop for var in '(* ** ***)
          for label in '("*" "**" "***")
          do (format s "~% ~A => ~A"
                     label
                     (handler-case (truncate-print (symbol-value var))
                       (unbound-variable () "<unbound>")
                       (error () "<unprintable>"))))))

;;; RPC

(defslyfun image-context
    (&optional focus-name
               (package-name (package-name *package*))
               (profile :lean))
  "A snapshot of the live image, ready to prefix onto an LLM prompt. PROFILE is
:lean or :full. FOCUS-NAME is the symbol under point, or NIL when there wasn't
one. PACKAGE-NAME is spelled however the buffer's IN-PACKAGE spells it. Emacs
staples its own eval-log section onto whatever this hands back.

Everything prints with *PACKAGE* bound to the focus package, so names from that
package come out bare and names from anywhere else keep their prefix."
  (let* ((full    (eq profile :full))
         (n-call  (if full *max-callers* (min 6 *max-callers*)))
         (package (resolve-package package-name))
         (*package* package))
    (with-output-to-string (out)
      (format out "=== LISP IMAGE CONTEXT (~(~A~)) ===~%" profile)
      (format out "Package: ~A~%" (package-name package))
      (let ((focus (and focus-name (resolve-symbol focus-name package))))
        (when focus
          (let ((callers (callers focus))
                (callees (callees focus)))
            (format out "~%--- FOCUS: ~S ---~%~A" focus (symbol-summary focus))
            (format out " called-by: ~{~A~^, ~}~%"
                    (printed-names (subseq-safe callers n-call)))
            (format out " calls: ~{~A~^, ~}~%"
                    (printed-names (subseq-safe callees n-call)))
            ;; one hop neighborhood - only full
            (when full
              (dolist (neighbor (subseq-safe (expandable-neighbors focus callees)
                                             *max-neighbors*))
                (format out "~%~S~%~A" neighbor (symbol-summary neighbor))))))
        (when full
          (format out "~%--- LAST REPL VALUES ---~A~%" (repl-values))))
      ;; conditions: one line each under :lean, the whole messy text under :full
      (when *conditions*
        (let ((n-cond (if full *max-conditions* (min 2 *max-conditions*))))
          (format out "~%--- RECENT CONDITIONS ---~%")
          (dolist (c (subseq-safe *conditions* n-cond))
            (format out " ~A~%" (if full c (first-line c)))))))))

(provide :slynk-seance)
