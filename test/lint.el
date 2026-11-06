;;; lint.el --- package-lint and checkdoc over seance, failing on any complaint  -*- lexical-binding: t; -*-

;;; Commentary:
;; Run by `make lint'. Neither tool fails a build by itself: checkdoc only
;; warns, and package-lint is usually run interactively. This counts what both
;; say and exits nonzero when either said anything.
;;
;; package-lint checks that every dependency can be installed, so it needs
;; package archive contents, which it fetches into a scratch directory rather
;; than your own ~/.emacs.d.

;;; Code:

(require 'cl-lib)
(require 'checkdoc)
(require 'package)
(require 'package-lint)

(defconst seance-lint-files '("seance.el" "seance-claude.el" "seance-gptel.el"))

(defvar seance-lint-problems 0)

;; every checkdoc complaint goes through here, whatever buffer it is aimed at
(advice-add 'checkdoc-error :before
            (lambda (&rest _) (cl-incf seance-lint-problems)))

;; house style is one space after a period, in docstrings as everywhere else
(setq sentence-end-double-space nil)

;; The voice check matches verbs anywhere in the first line, so "text goes
;; into TARGET" or "buffer evals" fail it although the docstring opens in the
;; imperative. Emacs 31 turned it off by default as experimental; turning it
;; off here makes every Emacs lint the same.
(setq checkdoc-verb-check-experimental-flag nil)

(dolist (file seance-lint-files)
  (checkdoc-file file))

(setq package-user-dir (make-temp-file "seance-lint-elpa" t)
      package-archives '(("gnu"    . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")))
(package-initialize)
(package-refresh-contents)

;; the transports are part of the seance package, so only seance.el carries
;; the headers
(setq package-lint-main-file "seance.el")

(dolist (file seance-lint-files)
  (with-current-buffer (find-file-noselect file)
    (dolist (issue (package-lint-buffer))
      (cl-destructuring-bind (line col type message) issue
        (cl-incf seance-lint-problems)
        (message "%s:%d:%d: %s: %s" file line col type message)))))

(message "lint: %d problem(s)" seance-lint-problems)
(kill-emacs (if (zerop seance-lint-problems) 0 1))

;;; lint.el ends here
