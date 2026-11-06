;;;; fixture.lisp: sample definitions for the slynk-seance test suite.
;;;;
;;;; COMPILE-FILE'd (not just loaded) by run-tests.lisp, because xref data and
;;;; code-object callees only exist for compiled definitions, which is how a
;;;; user's code gets into the image anyway (C-c C-k).

(defpackage :seance-fixture
  (:use :cl)
  (:export #:focus #:callee-a #:callee-b #:caller #:leaf))

(in-package :seance-fixture)

(defun callee-a (x)
  "Callee A doc."
  (leaf x))

(defun callee-b (x)
  "Callee B doc."
  (1- x))

(defun leaf (x)
  "Leaf doc."
  (1+ x))

(defun focus (x)
  "Focus doc line one.
Second line must not reach the snapshot."
  (+ (callee-a x) (callee-b x)))

(defun caller (x)
  "Caller doc."
  (focus x))
