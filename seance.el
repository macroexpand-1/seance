;;; seance.el --- Hand an LLM a snapshot of your live Lisp image  -*- lexical-binding: t; -*-

;; Author: Real Limoges <b.real.limoges@gmail.com>
;; URL: https://github.com/real-limoges/seance
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (sly "1.0.43"))
;; Keywords: lisp, tools, convenience
;; SPDX-License-Identifier: BSD-2-Clause

;;; Commentary:
;; Everything in seance that doesn't care where the bytes end up. Two stages:
;;
;; 1. CAPTURE:  a small ring of recent evals and compiles, grabbed with stable
;;              `advice-add' on SLY's own entry points (not slynk). Also
;;              stashes the focus symbol *while point is still in the Lisp
;;              buffer*, so a chat buffer can ask about it later.
;;
;; 2. ASSEMBLE: `seance-context-string-async' calls SLYNK-SEANCE:IMAGE-CONTEXT
;;              for the in-image stuff and staples the local eval log onto it.
;;
;; TRANSPORT is somebody else's problem. Load one, or both:
;;
;;   seance-claude.el: the `claude' CLI, on your Claude Code subscription
;;   seance-gptel.el:  gptel, pointed at any OpenAI-compatible server
;;
;; They share the ring and the assembler that live here, so loading both
;; doesn't log every eval twice.
;;
;; seance is a SLY contrib. Turn it on once, in your init:
;;
;;   (add-to-list 'sly-contribs 'seance)
;;
;; SLY then loads slynk-seance.lisp into every image it connects to and
;; installs capture, and `sly-disable-contrib' turns the lot off again.

;;; Code:

(require 'sly)
(require 'cl-lib)
(require 'seq)

(defgroup seance nil
  "Push live Lisp image context to an LLM."
  :group 'sly)

(defcustom seance-profile :lean
  "How much snapshot to ask for: `:lean' or `:full'.

That's a question about the model's context budget, not about how the bytes
travel, so a backend can override it: see `seance-claude-profile'.

`:lean' drops the one-hop callee expansion and the REPL values, and trims the
caller and condition lists. Small local windows need room to breathe."
  :type '(choice (const :lean) (const :full)))

(defcustom seance-log-size 12
  "How many recent interactions to keep in the eval log."
  :type 'integer)

(defcustom seance-form-limit 300
  "Hard cap in chars for any single logged form or result."
  :type 'integer)

(defcustom seance-context-limit 20000
  "Hard cap in chars on the whole assembled snapshot, or nil for no cap.
Every other limit here is per item (`seance-form-limit', and the image side's
own `*max-callers*' and friends), and none of them bounds the total, which is
the number that actually has to fit in a model's window.

Trimming takes it off the end, which costs you the tail of the eval log rather
than the image section that leads. That is the wrong way round if the log is
what you cared about; raise the cap in that case rather than reordering, since
the model reads the beginning most carefully anyway."
  :type '(choice (const :tag "No cap" nil) integer))


;;; CAPTURE
;;; entries are the form: (:kind eval|def :form STRING :result STRING-or-nil)

(defvar seance--log nil "Ring of recent interactions, newest first.")

(defvar seance--pending nil
  "The logged eval entry whose result is due next, or nil.
Set when an eval goes out, consumed when its value is displayed.")

(defvar seance--last-focus nil
  "Cons (SYMBOL-STRING . PACKAGE-STRING) from the last capture.
What we fall back on when context gets assembled somewhere that isn't a Lisp
buffer (a chat buffer, say), where `sly-symbol-at-point' would happily hand
back a word out of your own prose.")

(defun seance--truncate (s)
  (if (and s (> (length s) seance-form-limit))
      (concat (substring s 0 seance-form-limit) " ...")
    s))

(defun seance--record (kind form &optional result)
  "Log an interaction and return its entry."
  (let ((entry (list :kind kind
                     :form (seance--truncate form)
                     :result (seance--truncate result))))
    (setq seance--log (seq-take (cons entry seance--log) seance-log-size))
    entry))

(defun seance--stash-focus ()
  "Grab the symbol and package while point is still on the source."
  (let ((sym (ignore-errors (sly-symbol-at-point)))
        (pkg (ignore-errors (sly-current-package))))
    (when (or sym pkg)
      (setq seance--last-focus (cons sym pkg)))))

;;;###autoload
(defun seance-clear-log ()
  "Drop the local eval log."
  (interactive)
  (setq seance--log nil seance--pending nil)
  (message "seance: log cleared"))

;; C-x C-e, C-M-x and an evaluated region all go out through
;; `sly-eval-with-transcript', and on success their value comes back through
;; `sly-display-eval-result'. So the form is logged on the way out and its
;; value filled in on the way back. An eval that aborts never displays a value,
;; which leaves its entry open: the log says so rather than dropping the form
;; that just blew up.

(defconst seance--eval-rpcs
  '(slynk:interactive-eval slynk:interactive-eval-region slynk:re-evaluate-defvar)
  "The `sly-eval-with-transcript' requests that evaluate your source.
Each takes the source string as its one argument. The other requests that go
through the transcript (loading a file, say) are not evals and stay out of the
log.")

(defun seance--note-transcript (form &rest _)
  "Log FORM's source with no result yet, and expect its value next."
  (setq seance--pending
        (when (and (memq (car-safe form) seance--eval-rpcs)
                   (stringp (cadr form)))
          (seance--stash-focus)
          (seance--record 'eval (cadr form)))))

(defun seance--note-result (value &rest _)
  "Fill VALUE into the pending eval entry, if there is one."
  (when seance--pending
    (let ((pending seance--pending)
          (result  (seance--truncate value)))
      (setq seance--log (mapcar (lambda (entry)
                                  (if (eq entry pending)
                                      (plist-put (copy-sequence entry) :result result)
                                    entry))
                                seance--log)
            seance--pending nil))))

(defun seance--forget-pending (&rest _)
  "Stop expecting a value for the pending entry.
An eval in an SLDB frame displays its value through `sly-display-eval-result'
too, without a transcript, so that value belongs to no logged form."
  (setq seance--pending nil))

;; C-c C-c compiles instead of evaling, and might be acting on a region.
(defun seance--note-compile (&rest _)
  (seance--stash-focus)
  (let ((form (ignore-errors
                (cl-destructuring-bind (beg end)
                    (if (use-region-p)
                        (list (region-beginning) (region-end))
                      (sly-region-for-defun-at-point))
                  (buffer-substring-no-properties beg end)))))
    (when form (seance--record 'def form nil))))

;;;###autoload
(defun seance-install ()
  "Install capture advice. Runs twice without complaint.
The contrib does this on load; call it yourself only after `seance-uninstall'."
  (interactive)
  (advice-add 'sly-eval-with-transcript :before #'seance--note-transcript)
  (advice-add 'sly-display-eval-result  :after  #'seance--note-result)
  (advice-add 'sly-db-eval-in-frame     :before #'seance--forget-pending)
  (advice-add 'sly-compile-defun        :before #'seance--note-compile)
  (when (called-interactively-p 'interactive)
    (message "seance: capture installed")))

;;;###autoload
(defun seance-uninstall ()
  "Remove capture advice, for the rest of this Emacs session.
To turn seance off as a whole, image side included, use `sly-disable-contrib'
or take `seance' out of `sly-contribs'."
  (interactive)
  (advice-remove 'sly-eval-with-transcript #'seance--note-transcript)
  (advice-remove 'sly-display-eval-result  #'seance--note-result)
  (advice-remove 'sly-db-eval-in-frame     #'seance--forget-pending)
  (advice-remove 'sly-compile-defun        #'seance--note-compile)
  (when (called-interactively-p 'interactive)
    (message "seance: capture uninstalled")))


;;; ASSEMBLE

(defun seance--profile (&optional override)
  "Profile to ask the image for: OVERRIDE if non-nil, else `seance-profile'.
Each transport keeps its own profile custom that may be nil meaning \"inherit\"
(see `seance-claude-profile' and `seance-gptel-profile'), so they resolve it
through here rather than each spelling out the same `or'."
  (or override seance-profile))

(defun seance--trim-context (string)
  "STRING cut down to `seance-context-limit', saying so where it was cut."
  (if (and seance-context-limit
           (> (length string) seance-context-limit))
      (concat (substring string 0 seance-context-limit)
              (format "\n;; ... trimmed to %d chars (see `seance-context-limit')\n"
                      seance-context-limit))
    string))

(defun seance--render-log ()
  "Render the recent-evals log as a string; empty when the log is empty."
  (if (null seance--log) ""
    (concat
     "\n--- RECENT EVALS (newest last) ---\n"
     (mapconcat
      (lambda (e)
        (pcase (plist-get e :kind)
          ('def (format "(def) %s\n" (plist-get e :form)))
          (_    (format "%s\n => %s\n"
                        (plist-get e :form)
                        (or (plist-get e :result)
                            "(no value: aborted, or still running)")))))
      (reverse seance--log) ""))))

(defun seance--focus ()
  "Cons (FOCUS-STRING . PACKAGE-STRING) for whatever we're asking about.
In a Lisp buffer, point wins. Anywhere else (a chat buffer, mostly), use what
CAPTURE stashed, because out there `sly-symbol-at-point' will cheerfully
return whatever word you're parked on. Ask the image about \"slow\" and you
get what you deserve."
  (if (derived-mode-p 'lisp-mode)
      (cons (sly-symbol-at-point)
            (or (sly-current-package) "COMMON-LISP-USER"))
    (cons (car seance--last-focus)
          (or (cdr seance--last-focus) "COMMON-LISP-USER"))))

(defun seance--image-context-async (focus profile k)
  "Fetch the in-image snapshot for FOCUS at PROFILE, then call K with the string.
Async on purpose. `slynk-seance:image-context' runs synchronously in the Lisp,
and reaching it through `sly-eval' would block all of Emacs until it returned:
a hard freeze whenever the image is busy or wedged. `sly-eval-async' keeps the
editor live; K fires with the image string once the reply lands.

The form resolves the RPC by name at runtime rather than mentioning the
`slynk-seance' package literally, so an image where the contrib never loaded
comes back as a plain note instead of a read-time package error. Any error
inside the RPC is caught in-image and returned as a string, so nothing lands
you in SLDB."
  (if (not (sly-connected-p))
      (funcall k ";; not connected to a Lisp image, so no live snapshot.\n")
    (sly-eval-async
        `(cl:let ((fn (cl:and (cl:find-package :slynk-seance)
                              (cl:find-symbol "IMAGE-CONTEXT" :slynk-seance))))
           (cl:if fn
                  (cl:handler-case
                      (cl:funcall fn ,(car focus) ,(cdr focus) ,profile)
                    (cl:error (e)
                     (cl:format nil ";; SLYNK-SEANCE:IMAGE-CONTEXT failed: ~A~%" e)))
                  (cl:format nil (cl:concatenate 'cl:string
                                                 ";; slynk-seance.lisp is not loaded in the image.~%"
                                                 ";; (add seance to sly-contribs and reconnect)~%"))))
      k)))

(defun seance-context-string-async (k &optional profile)
  "Assemble the snapshot and eventually call K with it, without blocking.
The snapshot is what the image knows, via the slynk RPC, plus our own eval log.
Resolves the focus and log now, in the current buffer, then fires the image RPC.
K runs with the assembled string back in the buffer that was current when this
was called, so a chat buffer's callback still edits the chat buffer. PROFILE
overrides `seance-profile' for this call."
  (let* ((profile (seance--profile profile))
         (focus   (seance--focus))
         (log     (seance--render-log))
         (buf     (current-buffer)))
    (seance--image-context-async
     focus profile
     (lambda (image)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (funcall k (seance--trim-context (concat image log)))))))))


;;; FETCH: one snapshot in flight per chat buffer, and a way to give up on it.
;;; `sly-eval-async' only calls back when the request succeeds, so an image
;;; that aborts the request or never answers would otherwise leave a send
;;; waiting forever, and a second send would queue up behind it.

(defvar-local seance--fetch nil
  "Token for the snapshot fetch this buffer is waiting on, or nil.")

(defun seance-fetching-p ()
  "Non-nil while this buffer is waiting on a snapshot."
  (and seance--fetch t))

(defun seance-fetch-context (k &optional profile)
  "Fetch a snapshot for this buffer and call K with it, unless cancelled first.
Refuses while an earlier fetch here is still waiting: that one would turn into
a second send the moment the image answered. PROFILE is as for
`seance-context-string-async'."
  (when seance--fetch
    (user-error "Seance: still waiting on the image (M-x seance-cancel-fetch to give up)"))
  (let ((token (list 'fetch)))
    (setq seance--fetch token)
    (message "seance: gathering the live-image snapshot...")
    (seance-context-string-async
     (lambda (ctx)
       (when (eq seance--fetch token)
         (setq seance--fetch nil)
         (funcall k ctx)))
     profile)))

;;;###autoload
(defun seance-cancel-fetch ()
  "Give up on the snapshot this buffer is waiting for; its send never happens."
  (interactive)
  (unless seance--fetch
    (user-error "Seance: no snapshot fetch in flight here"))
  (setq seance--fetch nil)
  (message "seance: gave up on the snapshot"))


;;; PREVIEW: what a transport would send, with its own profile and framing.

(defvar seance--transports nil
  "Loaded transports, as an alist of (NAME . PLIST).
PLIST holds :profile, a function of no arguments returning the profile the
transport asks for, and :frame, a function from the snapshot string to the text
the transport sends with it. See `seance-register-transport'.")

(defun seance-register-transport (name profile-fn frame-fn)
  "Make transport NAME previewable.
PROFILE-FN returns the profile NAME asks for; FRAME-FN takes a snapshot and
returns the text NAME actually sends. A transport frames its sends with the
same FRAME-FN it registers, so the preview cannot drift from the real thing."
  (setf (alist-get name seance--transports nil nil #'equal)
        (list :profile profile-fn :frame frame-fn)))

(defvar-local seance--chat-transport nil
  "Name of the transport that owns this chat buffer, set by its chat mode.")

(defun seance--preview-transport ()
  "Transport to preview: this chat's own, the only one loaded, or one you pick.
Nil when no transport is loaded."
  (cond (seance--chat-transport)
        ((null seance--transports) nil)
        ((null (cdr seance--transports)) (caar seance--transports))
        (t (completing-read "Preview for: " (mapcar #'car seance--transports) nil t))))

;;;###autoload
(defun seance-preview-context (&optional profile)
  "Show exactly what would get sent, without sending it.
Previews for this chat buffer's transport, or for the transport you pick when
more than one is loaded, at that transport's profile and in its framing.
With a prefix argument, ask which PROFILE to fetch and show the bare snapshot.
Start here when an answer looks wrong: usually the snapshot was wrong first.
The snapshot arrives async, so the buffer pops up right away and fills in when
the image replies."
  (interactive
   (list (when current-prefix-arg
           (intern (completing-read "Profile: " '(":lean" ":full") nil t)))))
  (let* ((transport (unless profile (seance--preview-transport)))
         (spec      (cdr (assoc transport seance--transports)))
         (profile   (or profile
                        (and spec (funcall (plist-get spec :profile)))))
         (frame     (or (plist-get spec :frame) #'identity))
         (buf       (get-buffer-create "*seance-context*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert ";; fetching the live-image snapshot...\n"))
    (display-buffer buf)
    (seance-context-string-async
     (lambda (s)
       (let ((text (funcall frame s)))
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (erase-buffer)
             (insert text)
             (goto-char (point-min))))))
     profile)))


;;; CONTRIB: SLY loads slynk-seance.lisp into each image and turns capture on.

(define-sly-contrib seance
  "Hand an LLM a snapshot of the live Lisp image."
  (:authors "Real Limoges <b.real.limoges@gmail.com>")
  (:license "BSD-2-Clause")
  (:slynk-dependencies slynk-seance)
  (:on-load (seance-install))
  (:on-unload (seance-uninstall)))

(provide 'seance)
;;; seance.el ends here
