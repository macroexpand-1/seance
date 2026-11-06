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
;;              `advice-add' on SLY's own entry points (not slynk), plus the
;;              compiler notes from the last compile. Also stashes the focus
;;              symbol *while point is still in the Lisp buffer*, so a chat
;;              buffer can ask about it later.
;;
;; 2. ASSEMBLE: `seance-context-string-async' calls SLYNK-SEANCE:IMAGE-CONTEXT
;;              for the in-image stuff and staples on what only Emacs knows:
;;              an open debugger, the compiler notes and the eval log.
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
(require 'subr-x)

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

Over the cap, sections give up space one at a time in the order of
`seance--shrink-order': the one-hop neighbors first, the focus definition
last. Every section keeps its heading and says how much it lost, and the eval
log loses its oldest entries rather than its newest."
  :type '(choice (const :tag "No cap" nil) integer))

(defcustom seance-compiler-notes-limit 10
  "How many notes from the last compile to put in the snapshot."
  :type 'integer)

(defcustom seance-debugger-frames 8
  "How many backtrace frames of an open debugger to put in the snapshot."
  :type 'integer)

(defcustom seance-automatic-conditions nil
  "Non-nil to note conditions from every buffer eval without being asked.
The image wraps each request from Emacs (\\[sly-eval-last-expression],
\\[sly-compile-defun], \\[sly-compile-and-load-file]) so that a serious
condition escaping it lands in RECENT CONDITIONS, still going on to SLDB as
before. SLY's own background requests are wrapped too, so one of those failing
shows up as well. Input at the mREPL is not covered: wrap that in
`slynk-seance:with-captured-conditions' as before.

Applies from the next connection; setting it through Custom also applies it
to the current one."
  :type 'boolean
  :initialize #'custom-initialize-default
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (and (fboundp 'sly-connected-p) (sly-connected-p))
           (seance--sync-automatic-conditions))))


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

(defvar seance--compiler-notes nil
  "The last compile's notes, rendered one line each.")

(defun seance--truncate (s)
  "S cut to `seance-form-limit' chars, marked when cut; nil stays nil."
  (if (and s (> (length s) seance-form-limit))
      (concat (substring s 0 seance-form-limit) " ...")
    s))

(defun seance--record (kind form &optional result)
  "Log an interaction of KIND with FORM and RESULT, and return its entry.
KIND is `eval', `def' or `file'; FORM and RESULT are strings, RESULT nil
when there is none (yet)."
  (let ((entry (list :kind kind
                     :form (seance--truncate form)
                     :result (seance--truncate result))))
    (setq seance--log (seq-take (cons entry seance--log) seance-log-size))
    entry))

(defvar-local seance--chat-transport nil
  "Name of the transport that owns this chat buffer, set by its chat mode.")

(defun seance--stash-focus ()
  "Grab the symbol and package while point is still on the source.
Not from a chat buffer, though: a code block evaluated there would otherwise
swap the focus for whatever word of prose point happened to be on."
  (unless seance--chat-transport
    (let ((sym (ignore-errors (sly-symbol-at-point)))
          (pkg (ignore-errors (sly-current-package))))
      (when (or sym pkg)
        (setq seance--last-focus (cons sym pkg))))))

;;;###autoload
(defun seance-clear-log ()
  "Drop the local eval log and the last compile's notes."
  (interactive)
  (setq seance--log nil seance--pending nil seance--compiler-notes nil)
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
  "Log the defun or region about to be compiled, and stash the focus."
  (seance--stash-focus)
  (let ((form (ignore-errors
                (cl-destructuring-bind (beg end)
                    (if (use-region-p)
                        (list (region-beginning) (region-end))
                      (sly-region-for-defun-at-point))
                  (buffer-substring-no-properties beg end)))))
    (when form (seance--record 'def form nil))))

;; Every compile, C-c C-c or C-c C-k, finishes through
;; `sly-compilation-finished-hook' with its notes already parsed. The notes
;; replace the last compile's, so a clean compile clears them; a file compile
;; also goes in the log, so the model knows a whole file was just reloaded.

(defun seance--note-where (note)
  "The file or buffer NOTE points at, or nil."
  (let* ((location (cdr-safe (sly-note.location note)))
         (file     (cadr (assq :file location)))
         (buffer   (cadr (assq :buffer location))))
    (cond (file (file-name-nondirectory file))
          (buffer))))

(defun seance--render-note (note)
  "NOTE as one line: severity, message, and where it points."
  (let ((where (seance--note-where note)))
    (format "%s: %s%s"
            (sly-severity-label (sly-note.severity note))
            (seance--truncate
             (string-trim (replace-regexp-in-string
                           "[ \t\n]+" " " (sly-note.message note))))
            (if where (format " (%s)" where) ""))))

(defun seance--note-compilation (successp notes buffer loadp)
  "Keep NOTES from the compile that just finished; log it when it was a file.
SUCCESSP, BUFFER and LOADP are as `sly-compilation-finished-hook' passes them:
BUFFER is the file's buffer for a file compile and nil otherwise."
  (setq seance--compiler-notes
        (mapcar #'seance--render-note (seq-take notes seance-compiler-notes-limit)))
  (let ((file (and buffer (buffer-file-name buffer))))
    (when file
      (seance--record 'file file
                      (cond ((not successp) "failed")
                            (loadp "compiled and loaded")
                            (t "compiled"))))))

(defun seance--sync-automatic-conditions ()
  "Tell the image whether to note conditions from buffer evals by itself.
See `seance-automatic-conditions'. Resolves the function by name, like the
snapshot does, so an image without the contrib just ignores it."
  (sly-eval-async
      `(cl:let ((fn (cl:and (cl:find-package :slynk-seance)
                            (cl:find-symbol "AUTOMATIC-CONDITIONS" :slynk-seance))))
         (cl:when fn (cl:funcall fn ,(and seance-automatic-conditions t))))))

;;;###autoload
(defun seance-install ()
  "Install capture advice and hooks. Runs twice without complaint.
The contrib does this on load; call it yourself only after `seance-uninstall'."
  (interactive)
  (advice-add 'sly-eval-with-transcript :before #'seance--note-transcript)
  (advice-add 'sly-display-eval-result  :after  #'seance--note-result)
  (advice-add 'sly-db-eval-in-frame     :before #'seance--forget-pending)
  (advice-add 'sly-compile-defun        :before #'seance--note-compile)
  (add-hook 'sly-compilation-finished-hook #'seance--note-compilation)
  ;; SLY has loaded the image side by the time this hook runs
  (add-hook 'sly-connected-hook #'seance--sync-automatic-conditions)
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
  (remove-hook 'sly-compilation-finished-hook #'seance--note-compilation)
  (remove-hook 'sly-connected-hook #'seance--sync-automatic-conditions)
  (when (called-interactively-p 'interactive)
    (message "seance: capture uninstalled")))


;;; ASSEMBLE

(defun seance--profile (&optional override)
  "Profile to ask the image for: OVERRIDE if non-nil, else `seance-profile'.
Each transport keeps its own profile custom that may be nil meaning \"inherit\",
see `seance-claude-profile' and `seance-gptel-profile', so they resolve it
through here rather than each spelling out the same `or'."
  (or override seance-profile))

;;; Trimming. A snapshot is a run of sections, each opening with a
;;; "--- TITLE ---" line. Over `seance-context-limit', the sections give up
;;; space in a fixed order, each keeping its heading, so the model still sees
;;; that a section existed and how much of it went.

(defconst seance--shrink-order
  '("NEIGHBORS" "REPL" "RECENT CONDITIONS" "COMPILER NOTES" "RECENT EVALS"
    "DEBUGGER" "FOCUS")
  "Section titles, first to give up space first.
The neighbors are context around the focus, so they go before it; the focus
definition is what the question is usually about, so it goes last.")

(defconst seance--keep-newest '("RECENT EVALS")
  "Sections that list oldest first, and so are cut from the front.")

(defconst seance--section-heading "^--- \\(.+\\) ---$")

(defun seance--section-key (title)
  "The entry of `seance--shrink-order' that TITLE starts with, or TITLE."
  (or (seq-find (lambda (key) (string-prefix-p key title)) seance--shrink-order)
      title))

(defun seance--split-sections (string)
  "STRING cut at its section headings, as a list of (KEY . TEXT).
Each TEXT runs from just after the previous section up to the end of the line
before the next heading, so concatenating the TEXTs gives back STRING. The
part before the first heading has a nil KEY."
  (let ((starts (let ((pos 0) out)
                  (while (string-match seance--section-heading string pos)
                    (push (match-beginning 0) out)
                    (setq pos (match-end 0)))
                  (nreverse out))))
    (cl-loop for (beg end) on (cons 0 starts)
             for text = (substring string beg end)
             collect (cons (and (string-match seance--section-heading text)
                                (= (match-beginning 0) 0)
                                (seance--section-key (match-string 1 text)))
                           text))))

(defun seance--shrink-section (text excess keep-newest)
  "TEXT, a section, with enough of its body cut to save EXCESS chars.
The heading line stays, and a line saying how much went replaces what was cut.
KEEP-NEWEST cuts from the front of the body rather than the end. A body too
short to cut that much loses all of it."
  (let* ((heading-end (1+ (or (string-search "\n" text) (1- (length text)))))
         (heading     (substring text 0 heading-end))
         (body        (substring text heading-end))
         (note-for    (lambda (n) (format " ;; ... %d chars trimmed\n" n)))
         ;; the note and its newline cost chars too, so cut that much more
         ;; (sized for the whole body, which has at least as many digits)
         (overhead    (1+ (length (funcall note-for (length body)))))
         (cut         (min (length body) (+ excess overhead))))
    (if (<= cut overhead)
        text
      (let ((note (funcall note-for cut)))
        (if keep-newest
            (concat heading note (substring body cut))
          (concat heading (substring body 0 (- (length body) cut)) "\n" note))))))

(defun seance--trim-context (string)
  "STRING cut down to `seance-context-limit', a section at a time.
Sections give up space in `seance--shrink-order'. Should that not be enough,
because the headings alone are over the cap or there are no headings at all,
the end goes, as a last resort, with a note saying where."
  (if (or (null seance-context-limit)
          (<= (length string) seance-context-limit))
      string
    (let ((sections (seance--split-sections string)))
      (dolist (key seance--shrink-order)
        (let ((excess (- (apply #'+ (mapcar (lambda (s) (length (cdr s))) sections))
                         seance-context-limit)))
          (when (> excess 0)
            (setq sections
                  (mapcar (lambda (section)
                            (if (equal (car section) key)
                                (cons key (seance--shrink-section
                                           (cdr section) excess
                                           (member key seance--keep-newest)))
                              section))
                          sections)))))
      (let ((trimmed (mapconcat #'cdr sections "")))
        (if (<= (length trimmed) seance-context-limit)
            trimmed
          (concat (substring trimmed 0 seance-context-limit)
                  (format "\n;; ... trimmed to %d chars (see `seance-context-limit')\n"
                          seance-context-limit)))))))

(defun seance--render-log ()
  "Render the recent-evals log as a string; empty when the log is empty."
  (if (null seance--log) ""
    (concat
     "\n--- RECENT EVALS (newest last) ---\n"
     (mapconcat
      (lambda (e)
        (pcase (plist-get e :kind)
          ('def  (format "(def) %s\n" (plist-get e :form)))
          ('file (format "(file) %s => %s\n" (plist-get e :form) (plist-get e :result)))
          (_     (format "%s\n => %s\n"
                         (plist-get e :form)
                         (or (plist-get e :result)
                             "(no value: aborted, or still running)")))))
      (reverse seance--log) ""))))

(defun seance--render-compiler-notes ()
  "The last compile's notes as a section; empty when it had none."
  (if (null seance--compiler-notes) ""
    (concat "\n--- COMPILER NOTES (last compile) ---\n"
            (mapconcat (lambda (note) (concat " " note "\n")) seance--compiler-notes ""))))

;;; An open debugger is the most useful thing a snapshot can carry: the
;;; condition, the ways out, and where it happened. SLY already has all of it
;;; in the SLDB buffer, so it is read from there rather than asked for again.

(defun seance--debugger-buffer ()
  "The SLDB buffer to describe, or nil when there is none.
This one, when called from one; otherwise the deepest level still open."
  (let ((open (seq-filter (lambda (buf) (buffer-local-value 'sly-db-level buf))
                          (sly-db-buffers))))
    (if (memq (current-buffer) open)
        (current-buffer)
      (car (sort open (lambda (a b)
                        (> (buffer-local-value 'sly-db-level a)
                           (buffer-local-value 'sly-db-level b))))))))

(defun seance--debugger-frames ()
  "The first `seance-debugger-frames' lines of this SLDB buffer's backtrace."
  (if (not (markerp sly-db-backtrace-start-marker)) ""
    (save-excursion
      (goto-char sly-db-backtrace-start-marker)
      (let ((beg (point)))
        (forward-line seance-debugger-frames)
        (buffer-substring-no-properties beg (point))))))

(defun seance--render-debugger ()
  "The open debugger as a section; empty when there is none."
  (let ((buf (seance--debugger-buffer)))
    (if (null buf) ""
      (with-current-buffer buf
        (concat
         (format "\n--- DEBUGGER (level %d) ---\n" sly-db-level)
         (format " %s\n %s\n"
                 (seance--truncate (car sly-db-condition))
                 (string-trim (or (cadr sly-db-condition) "")))
         " restarts:\n"
         (mapconcat (lambda (line) (concat "  " line "\n"))
                    (cl-loop for (name description) in sly-db-restarts
                             for i from 0 below 6
                             collect (format "%d: [%s] %s" i name description))
                    "")
         " backtrace:\n"
         ;; SLDB's own "--more--" button is no use to a model
         (mapconcat (lambda (line) (concat "  " line "\n"))
                    (remove "--more--"
                            (split-string (seance--debugger-frames) "\n" t "[ \t]+"))
                    ""))))))

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
The snapshot is what the image knows, via the slynk RPC, then what only Emacs
knows: an open debugger, the last compile's notes and the eval log. Those are
rendered now, in the current buffer, before the image RPC goes out. K runs
with the assembled string back in the buffer that was current when this was
called, so a chat buffer's callback still edits the chat buffer. PROFILE
overrides `seance-profile' for this call."
  (let* ((profile (seance--profile profile))
         (focus   (seance--focus))
         (local   (concat (seance--render-debugger)
                          (seance--render-compiler-notes)
                          (seance--render-log)))
         (buf     (current-buffer)))
    (seance--image-context-async
     focus profile
     (lambda (image)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (funcall k (seance--trim-context (concat image local)))))))))


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


;;; EVAL FROM THE CHAT: the answer's code, into the image, without copying.

(defun seance--fences ()
  "Every ``` fence line in this buffer, in order, as (BEG . END) of the line."
  (save-excursion
    (goto-char (point-min))
    (let (fences)
      (while (re-search-forward "^[ \t]*```.*$" nil t)
        (push (cons (match-beginning 0) (match-end 0)) fences))
      (nreverse fences))))

(defun seance--fenced-block-at (pos)
  "The code inside the ``` block around POS, or nil when POS is not in one.
Fences pair up in order, opening then closing, as Markdown reads them."
  (cl-loop for (open close) on (seance--fences) by #'cddr
           when (and close (<= (car open) pos (cdr close)))
           return (buffer-substring-no-properties
                   (min (1+ (cdr open)) (car close)) (car close))))

;;;###autoload
(defun seance-eval-block (pos)
  "Evaluate every form in the ``` code block at POS in the live image.
The forms go in the package of the code you were last working on, and the
eval lands in the log like a \\[sly-eval-last-expression] would, so the next
turn sees what the suggestion did. Your focus stays where it was."
  (interactive "d")
  (let ((code (string-trim (or (seance--fenced-block-at pos) ""))))
    (when (string-empty-p code)
      (user-error "Seance: point is not in a ``` code block"))
    (let ((sly-buffer-package (or (cdr seance--last-focus) sly-buffer-package)))
      (sly-eval-with-transcript `(slynk:interactive-eval-region ,code)))))


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
