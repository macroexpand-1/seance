;;; seance-gptel.el --- seance transport: gptel  -*- lexical-binding: t; -*-

;; Author: Real Limoges <b.real.limoges@gmail.com>
;; URL: https://github.com/real-limoges/seance
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (sly "1.0.43") (seance "0.1.0"))
;; Keywords: lisp, tools, convenience
;; SPDX-License-Identifier: BSD-2-Clause

;;; Commentary:
;; TRANSPORT for seance: hands the snapshot to gptel, which will talk to any
;; OpenAI-compatible server: llama.cpp, Ollama, MLX, whatever. The snapshot
;; gets refreshed into the system message before every single send, because
;; the image has probably moved since the last one.
;;
;; gptel is optional. This file loads fine without it; `seance-gptel' just
;; refuses to do anything until gptel is installed and you've picked a backend
;; with `seance-gptel-use-openai-compatible'.
;;
;; Bind:
;;   (with-eval-after-load 'sly
;;     (define-key sly-mode-map (kbd "C-c C-S-l") #'seance-gptel))

;;; Code:

(require 'sly)
(require 'seance)
(require 'gptel nil t)

;; gptel is optional, so the byte-compiler can't see any of its symbols. Declare
;; the ones we use to shut up the "not known to be defined" noise; they resolve
;; at runtime.

(declare-function gptel-send        "gptel")
(declare-function gptel-mode        "gptel")
(declare-function gptel-make-openai "gptel-openai")
(defvar gptel-system-prompt)
(defvar gptel--system-message)
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-stream)

(defgroup seance-gptel nil
  "Push live Lisp image context to a local LLM via gptel."
  :group 'seance)

(defcustom seance-gptel-backend nil
  "GPTEL backend object. See `seance-gptel-use-openai-compatible'."
  :type 'sexp)

(defcustom seance-gptel-model nil
  "GPTEL model symbol."
  :type 'symbol)

;; The backend object above cannot go in your init: it is a struct that only
;; exists once gptel has built it. These three can, and seance builds the
;; backend from them on first use, so picking a server is a thing you do
;; once, rather than every session.

(defcustom seance-gptel-host nil
  "Host and port of an OpenAI-compatible server, like \"localhost:8080\".
Set this and `seance-gptel-model-name' in your init to skip running
`seance-gptel-use-openai-compatible' every time Emacs starts."
  :type '(choice (const :tag "Not set" nil) string))

(defcustom seance-gptel-model-name nil
  "Model to ask that server for, as a string. See `seance-gptel-host'."
  :type '(choice (const :tag "Not set" nil) string))

(defcustom seance-gptel-backend-name "local"
  "Label for the backend built out of `seance-gptel-host'."
  :type 'string)

(defcustom seance-gptel-profile nil
  "Snapshot size for this backend, overriding `seance-profile'.
nil inherits `seance-profile', which is `:lean': about right for the small
local models this thing usually points at."
  :type '(choice (const :tag "Inherit seance-profile" nil)
          (const :lean) (const :full)))

(defcustom seance-gptel-buffer-name "*seance-gptel*"
  "Buffer for the interactive chat."
  :type 'string)

(defcustom seance-gptel-preamble
  (concat "You are at a live SBCL REPL via SLY. The snapshot below is the "
          "current state of the image; trust it over any earlier code in the "
          "conversation. Answer concisely with forms ready to evaluate. "
          "No file scaffolding, no preamble.")
  "This is the system preamble.
Small models follow tight instructions better than vibes."
  :type 'string)


;;; Backend setup

(defun seance-gptel--require ()
  "Require gptel."
  (unless (featurep 'gptel)
    (user-error "seance-gptel: gptel not available: install and configure")))

(defun seance-gptel--require-openai ()
  "Like `seance-gptel--require', and make sure `gptel-make-openai' is callable.
That constructor lives in gptel-openai.el, which a package install autoloads
and a bare `load-path` does not. Asking for it by name beats dying of
void-function halfway through configuring a backend."
  (seance-gptel--require)
  (unless (fboundp 'gptel-make-openai)
    (require 'gptel-openai nil t))
  (unless (fboundp 'gptel-make-openai)
    (user-error "Seance-gptel: gptel is loaded but gptel-openai did not")))

;;;###autoload
(defun seance-gptel-use-openai-compatible (name host model &optional save)
  "Point seance at a local OpenAI-compatible server (llama.cpp, ...).
NAME labels the backend, HOST looks like \"localhost:8080\", MODEL is a symbol.

The choice is written back to `seance-gptel-backend-name', `seance-gptel-host'
and `seance-gptel-model-name', so it can be rebuilt without asking you again.
With a prefix argument, SAVE is non-nil and those get saved through Custom too,
which is what makes the choice outlive this Emacs."
  (interactive
   (progn
     (seance-gptel--require-openai)
     (list (read-string "Backend name: " (or seance-gptel-backend-name "local"))
           (read-string "Host (host:port): " (or seance-gptel-host "localhost:8080"))
           (intern (read-string "Model: " seance-gptel-model-name))
           current-prefix-arg)))
  (seance-gptel--require-openai)
  (setq seance-gptel-backend (gptel-make-openai name
                               :host host
                               :protocol "http"
                               :stream t
                               :models (list model))
        seance-gptel-model model
        seance-gptel-backend-name name
        seance-gptel-host host
        seance-gptel-model-name (symbol-name model))
  (when save
    (dolist (v '(seance-gptel-backend-name seance-gptel-host seance-gptel-model-name))
      (customize-save-variable v (symbol-value v))))
  (message "seance-gptel: using %s @ %s%s" model host (if save " (saved)" "")))

(defun seance-gptel--ensure-backend ()
  "The backend to talk to, built from the customs when we do not have one yet.
Nil when there is nothing configured to build from, which is the case worth
telling the user about."
  (or seance-gptel-backend
      (when (and seance-gptel-host seance-gptel-model-name)
        (seance-gptel-use-openai-compatible seance-gptel-backend-name
                                            seance-gptel-host
                                            (intern seance-gptel-model-name))
        seance-gptel-backend)))


;;; Transport

(defun seance-gptel--system-variable ()
  "The variable this gptel keeps its buffer-local system prompt in.
gptel renamed it: `gptel--system-message' is now an obsolete alias pointing at
`gptel-system-prompt'. Picking whichever one is actually bound keeps current
and older gptel both working, and keeps us off a name that will eventually go
away. The alias still works today, so nothing here is urgent, but writing to
an obsolete variable is how you find out it was dropped."
  (if (boundp 'gptel-system-prompt) 'gptel-system-prompt 'gptel--system-message))

(defun seance-gptel--system-message (ctx)
  "The system message gptel sends: the preamble, then the snapshot CTX.
The preview frames its snapshot with this too, so it shows the real thing."
  (concat seance-gptel-preamble "\n\n" ctx))

(seance-register-transport "gptel"
                           (lambda () (seance--profile seance-gptel-profile))
                           #'seance-gptel--system-message)

;; Re-snapshot the image before each send. The image moved. It always moves.
(defun seance-gptel-send ()
  "Refresh the snapshot into the system message, then send.
Bound to whatever `gptel-send' is bound to inside the chat buffer. The snapshot
is fetched async (so a slow or wedged image never freezes Emacs) and the send
fires once it lands. `seance-cancel-fetch' gives up on one that never does."
  (interactive)
  ;; we're in the chat buffer, so focus comes from whatever CAPTURE stashed.
  ;; see `seance--focus'
  (seance-fetch-context
   (lambda (ctx)
     (set (make-local-variable (seance-gptel--system-variable))
          (seance-gptel--system-message ctx))
     (call-interactively #'gptel-send))
   (seance--profile seance-gptel-profile)))

(defvar seance-gptel-chat-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [remap gptel-send] #'seance-gptel-send)
    m)
  "Keymap for `seance-gptel-chat-mode'.
Remaps `gptel-send' to `seance-gptel-send' so every send grabs a fresh
snapshot first.")

(define-minor-mode seance-gptel-chat-mode
  "Re-snapshot the live Lisp image before every gptel send."
  :lighter " Seance" :keymap seance-gptel-chat-mode-map)

;;;###autoload
(defun seance-gptel ()
  "Open or switch to the chat buffer wired into the gptel backend.
Ask a question, send it with your usual gptel key. The snapshot gets refreshed
into the system message on the way out."
  (interactive)
  (seance-gptel--require)
  (let ((backend (seance-gptel--ensure-backend))
        (buf     (get-buffer-create seance-gptel-buffer-name)))
    (unless backend
      (message "seance-gptel: no backend yet; M-x seance-gptel-use-openai-compatible"))
    (with-current-buffer buf
      (unless (bound-and-true-p gptel-mode) (gptel-mode 1))
      (when backend            (setq-local gptel-backend backend))
      (when seance-gptel-model (setq-local gptel-model seance-gptel-model))
      (setq-local gptel-stream t)       ; local models are slow, stream it
      (setq seance--chat-transport "gptel")
      (seance-gptel-chat-mode 1)
      (goto-char (point-max)))
    (pop-to-buffer buf)))

(provide 'seance-gptel)
;;; seance-gptel.el ends here
