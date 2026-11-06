;;;; slynk-seance.asd
;;;;
;;;; SLY loads a contrib's slynk side with whatever loaded slynk itself, and
;;;; SLY usually loads slynk through ASDF. ASDF only finds a module that has a
;;;; system definition, so the contrib needs this file sitting next to
;;;; slynk-seance.lisp. Under slynk's own loader the file is ignored.

(asdf:defsystem :slynk-seance
  :description "Image side of seance: a snapshot of the live Lisp image for an LLM."
  :author "Real Limoges <b.real.limoges@gmail.com>"
  :license "BSD-2-Clause"
  :depends-on (:slynk)
  :components ((:file "slynk-seance")))
