;;; seance-claude.el --- seance transport: the claude CLI  -*- lexical-binding: t; -*-

;; Author: Real Limoges <b.real.limoges@gmail.com>
;; URL: https://github.com/real-limoges/seance
;; Version: 0.1.0
;; Keywords: lisp, tools, convenience
;; SPDX-License-Identifier: BSD-2-Clause

;;; Commentary:
;; TRANSPORT for seance: shoves the snapshot at the `claude' CLI in headless
;; mode (-p/--print). Runs on whatever subscription the CLI is logged into, no
;; API key.
;;
;; Which is the entire reason this exists next to seance-gptel.el. gptel can
;; talk to Claude too, but only if you hand it an API key.
;;
;; Wants the `claude' CLI on PATH and logged in (this is Claude Code itself).
;; Set `seance-claude-program' to an absolute path when a GUI Emacs can't find
;; it, which it usually can't.
;;
;; Bind:
;;   (with-eval-after-load 'sly
;;     (define-key sly-mode-map (kbd "C-c C-S-y") #'seance-claude))

;;; Code:

(require 'sly)
(require 'seance)
(require 'json)
(require 'subr-x)

(defgroup seance-claude nil
  "Push live Lisp image context to Claude via the claude CLI."
  :group 'seance)

(defcustom seance-claude-program "claude"
  "The Claude Code CLI this shells out to.
Headless (`-p'), on whatever subscription the CLI is logged into, no API key.
Set an absolute path (e.g. \"/opt/homebrew/bin/claude\") when a GUI Emacs
can't find it on PATH."
  :type 'string)

(defcustom seance-claude-model nil
  "Model passed to `claude --model'.  nil uses the CLI's default."
  :type '(choice (const :tag "CLI default" nil) string))

(defcustom seance-claude-extra-args nil
  "Extra args tacked onto every `claude' invocation.
E.g. \\='(\"--disallowed-tools\" \"Edit\" \"Write\" \"Bash\") to keep it pure
Q&A that never touches your repo."
  :type '(repeat string))

(defcustom seance-claude-profile :full
  "Snapshot size for this backend, overriding `seance-profile'.
Claude's window is big enough that the full one is worth sending. nil to
inherit `seance-profile' instead."
  :type '(choice (const :tag "Inherit seance-profile" nil)
          (const :lean) (const :full)))

(defcustom seance-claude-buffer-name "*seance-claude*"
  "Buffer name for the multi-turn chat."
  :type 'string)

(defcustom seance-claude-lean t
  "When non-nil, run `claude' lean for these one-off calls.
The process gets a neutral directory and `--setting-sources project', so with
no project sitting there the SessionStart hooks never fire and no CLAUDE.md
turns up. Each call carries the image context you sent and nothing else, not
your whole Claude Code project payload. Cheaper, faster, easier on the 5-hour
limit. Keychain auth survives."
  :type 'boolean)

(defcustom seance-claude-preamble
  (concat "You are pair-programming with an experienced Lisper at a live SBCL "
          "REPL via SLY. Definitions evolve in the image; the snapshot below is "
          "the current truth. Prefer small, modular functions. Reply with forms "
          "ready to eval, not file scaffolding.")
  "System prompt for a new chat.
Sent with the first turn only; the CLI keeps it with the session, so turns
continued with `--resume' still have it."
  :type 'string)


;;; Framing: what the CLI actually receives. The sends and the preview share
;;; these, so the preview cannot drift from the real thing.

(defun seance-claude--with-context (ctx msg)
  "MSG with the snapshot CTX folded in ahead of it."
  (concat "Current live-image context:\n```\n" ctx "\n```\n\n" msg))

(defun seance-claude--preview (ctx)
  "What the first turn of a new chat sends, around the snapshot CTX."
  (concat "## System prompt (first turn; the CLI keeps it for the session)\n\n"
          seance-claude-preamble "\n\n"
          "## Message\n\n"
          (seance-claude--with-context ctx "<your message>")))

(seance-register-transport "claude"
                           (lambda () (seance--profile seance-claude-profile))
                           #'seance-claude--preview)


;;; TRANSPORT: the `claude' CLI (your subscription), no gptel / API key

;; (I pick up buffers and put them down)

(defun seance-claude--executable ()
  "Where the claude CLI lives, or an error that states something useful."
  (or (executable-find seance-claude-program)
      (and (file-name-absolute-p seance-claude-program)
           (file-executable-p seance-claude-program)
           seance-claude-program)
      (user-error
       "Seance-claude: can't find `%s' (set `seance-claude-program' to its full path)"
       seance-claude-program)))

(defun seance-claude--base-args (extra)
  "Streaming print-mode args + optional model + `seance-claude-extra-args' + EXTRA."
  (append (list "-p" "--output-format" "stream-json" "--verbose"
                "--include-partial-messages")
          (when seance-claude-lean (list "--setting-sources" "project"))
          (when seance-claude-model (list "--model" seance-claude-model))
          seance-claude-extra-args
          extra))

(defun seance-claude--scroll-to-end (buffer)
  "Park BUFFER's window, if it has one, on the end of BUFFER.
Takes the buffer explicitly and reads `point-max' inside it, because the two
callers run from a process filter and a sentinel, where the current buffer is
whatever happened to be current when output landed."
  (let ((w (get-buffer-window buffer)))
    (when w
      (set-window-point w (with-current-buffer buffer (point-max))))))

(defun seance-claude--emit (target text)
  "Append TEXT at the end of TARGET and keep its window scrolled to the bottom."
  (when (and (stringp text) (> (length text) 0) (buffer-live-p target))
    (with-current-buffer target
      (save-excursion (goto-char (point-max)) (insert text)))
    (seance-claude--scroll-to-end target)))

(defun seance-claude--parse-json (line)
  "LINE parsed as a JSON object, a hash table keyed by strings; nil if it isn't.
Uses the native parser when this Emacs has one. Before Emacs 30 that depends on
how Emacs was built, and calling it blind on a build without one fails on every
line, which reads as an empty answer with no error. json.el is the fallback."
  (condition-case nil
      (if (and (fboundp 'json-available-p) (json-available-p))
          (json-parse-string line :object-type 'hash-table
                             :null-object nil :false-object nil)
        (let ((json-object-type 'hash-table)
              (json-key-type 'string)
              (json-array-type 'list)
              (json-null nil)
              (json-false nil))
          (json-read-from-string line)))
    (json-error nil)))

(defun seance-claude--handle-event (proc obj target)
  "Act on one parsed stream-json OBJ: text deltas go into TARGET.
PROC carries `seance-claude-got-text' so that a `result' arriving with no
deltas before it can still cough up the whole answer."
  (pcase (gethash "type" obj)
    ("stream_event"
     (let ((ev (gethash "event" obj)))
       (when (and ev (equal (gethash "type" ev) "content_block_delta"))
         (let ((delta (gethash "delta" ev)))
           (when (and delta (equal (gethash "type" delta) "text_delta"))
             (process-put proc 'seance-claude-got-text t)
             (seance-claude--emit target (gethash "text" delta)))))))
    ("result"
     (let ((res (gethash "result" obj)))
       (cond
        ((eq (gethash "is_error" obj) t)
         (seance-claude--emit target (format "\n;; claude error: %s\n"
                                             (or res (gethash "subtype" obj)))))
        ((and (not (process-get proc 'seance-claude-got-text)) (stringp res))
         (seance-claude--emit target res)))))))

(defconst seance-claude--diag-lines 5
  "How many non-JSON output lines to keep around as failure diagnostics.")

(defun seance-claude--consume-line (proc line target)
  "Parse one stdout LINE of PROC's stream-json; text goes into TARGET.
Cheap prefix test first, so the enormous SessionStart/hook events get skipped
without paying for a JSON parse.

A line that is not one of our two event shapes and not JSON at all gets kept
as a possible diagnostic rather than dropped. `make-process' with `:stderr'
nil folds standard error into this same stream, and those lines are the only
explanation we ever get when the CLI fails."
  (if (or (string-prefix-p "{\"type\":\"stream_event\"" line)
          (string-prefix-p "{\"type\":\"result\"" line))
      (let ((obj (seance-claude--parse-json line)))
        (when obj (seance-claude--handle-event proc obj target)))
    (let ((trimmed (string-trim line)))
      (unless (or (string-empty-p trimmed) (string-prefix-p "{" trimmed))
        (process-put proc 'seance-claude-diag
                     (last (append (process-get proc 'seance-claude-diag)
                                   (list trimmed))
                           seance-claude--diag-lines))))))

(defun seance-claude--failure-note (proc)
  "Why PROC failed, with whatever the CLI said on its way out.
You asking for the stop is not a failure worth explaining, so that case just
says so and skips the diagnostics."
  (if (process-get proc 'seance-claude-interrupted)
      "\n;; stopped.\n"
    (let ((diag (process-get proc 'seance-claude-diag)))
      (concat (format "\n;; claude exited %d\n" (process-exit-status proc))
              (mapconcat (lambda (line) (format ";; %s\n" line)) diag "")))))

(defun seance-claude--stop (proc)
  "Kill PROC, marking it as stopped on purpose rather than failed."
  (process-put proc 'seance-claude-interrupted t)
  (delete-process proc))

(defun seance-claude--spawn (target prompt extra &optional finalize)
  "Run claude with EXTRA args and PROMPT on stdin; stream the answer back.
TARGET is where it lands. Output is `--output-format stream-json'; we pick the
text deltas out and insert them live.
FINALIZE, if you pass one, runs in TARGET on exit with one argument: non-nil
when the CLI exited cleanly. Callers need that to tell a turn that happened
from one that did not: see how `seance-claude-send' gates `--resume'."
  (let* ((default-directory (if seance-claude-lean
                                (file-name-as-directory temporary-file-directory)
                              default-directory))
         (exe  (seance-claude--executable))
         (proc (make-process
                :name "seance-claude"
                :buffer nil
                :noquery t
                :connection-type 'pipe
                :coding 'utf-8-unix
                :command (cons exe (seance-claude--base-args extra))
                :filter
                (lambda (proc chunk)
                  (when (buffer-live-p target)
                    (let* ((acc   (concat (process-get proc 'seance-claude-acc) chunk))
                           (lines (split-string acc "\n")))
                      ;; hang onto the trailing line, it's probably half a JSON object
                      (process-put proc 'seance-claude-acc (car (last lines)))
                      (dolist (line (butlast lines))
                        (seance-claude--consume-line proc line target)))))
                :sentinel
                (lambda (proc _event)
                  (when (memq (process-status proc) '(exit signal))
                    (let ((rest (process-get proc 'seance-claude-acc)))
                      (when (and rest (> (length rest) 0))
                        (seance-claude--consume-line proc rest target)))
                    (when (buffer-live-p target)
                      (let ((ok (and (eq (process-status proc) 'exit)
                                     (zerop (process-exit-status proc)))))
                        (with-current-buffer target
                          (unless ok
                            (save-excursion
                              (goto-char (point-max))
                              (insert (seance-claude--failure-note proc))))
                          (when finalize (funcall finalize ok))))))))))
    (process-send-string proc prompt)
    (process-send-eof proc)
    proc))


;;; Multi-turn chat. Keeps a real session via --session-id / --resume so the
;;; turns share history; re-running folds a fresh snapshot into the next message.

(defvar-local seance-claude--session nil "Claude session id for this chat buffer.")

(defvar-local seance-claude--started nil
  "Non-nil once the CLI has actually completed a turn on this session.
Set from the process sentinel on a clean exit, never at dispatch: it decides
between `--session-id' and `--resume', and resuming a session the CLI never
managed to create fails every time after.")

(defvar-local seance-claude--refresh nil "Non-nil to ride a fresh snapshot next turn.")

(defvar-local seance-claude--input-start nil
  "Marker at the start of the message you are composing.
Laid down with every `## You' prompt. Beats searching back for that heading,
which cannot tell our prompt from the same line inside an answer Claude wrote.")

(defvar-local seance-claude--proc nil
  "The in-flight `claude' process for this chat buffer, if there is one.")

(defvar seance-claude-chat-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'seance-claude-send)
    (define-key m (kbd "C-c C-r") #'seance-claude)
    (define-key m (kbd "C-c C-k") #'seance-claude-interrupt)
    (define-key m (kbd "C-c C-e") #'seance-eval-block)
    m)
  "Keymap for `seance-claude-chat-mode'.")

(define-minor-mode seance-claude-chat-mode
  "Minor mode for a CLI-backed seance chat buffer.
\\<seance-claude-chat-mode-map>Type after the `## You' prompt and hit
\\[seance-claude-send] to send; \\[seance-claude] refreshes the snapshot and
\\[seance-claude-interrupt] stops an answer in progress. \\[seance-eval-block]
evaluates the code block at point in the image."
  :lighter " Seance")

(defun seance-claude--uuid ()
  "A random v4-shaped UUID, good enough for a session id."
  (format "%04x%04x-%04x-4%03x-%x%03x-%04x%04x%04x"
          (random 65536) (random 65536) (random 65536) (random 4096)
          (+ 8 (random 4)) (random 4096)
          (random 65536) (random 65536) (random 65536)))

(defun seance-claude--finish-turn (ok)
  "Wrap up a turn in this chat buffer; OK is non-nil when the CLI exited cleanly.
A clean exit is the only proof the CLI created the session, so only that flips
the chat over to `--resume'. A first turn that failed may still have claimed
its session id (an interrupted one always does), and the CLI refuses a claimed
id with \"already in use\" forever after. So a failed first turn gets a fresh
id for the next try, which is correct whether or not the old one was claimed."
  (cond (ok (setq seance-claude--started t))
        ((not seance-claude--started)
         (setq seance-claude--session (seance-claude--uuid))))
  (setq seance-claude--proc nil)
  (goto-char (point-max))
  (insert "\n\n## You\n\n")
  (setq seance-claude--input-start (point-marker))
  (seance-claude--scroll-to-end (current-buffer)))

(defun seance-claude-send ()
  "Send the text after the last `## You' prompt as the next turn in this chat."
  (interactive)
  (unless seance-claude--session
    (user-error "Seance-claude: not a chat buffer (use M-x seance-claude)"))
  (when (process-live-p seance-claude--proc)
    (user-error "Seance-claude: still working on the last one (C-c C-k to stop it)"))
  (when (seance-fetching-p)
    (user-error "Seance-claude: still gathering the snapshot (C-c C-k to give up)"))
  (let* ((start (or (and (markerp seance-claude--input-start)
                         (marker-position seance-claude--input-start))
                    (point-min)))
         (msg (string-trim (buffer-substring-no-properties start (point-max)))))
    (when (string-empty-p msg) (user-error "Seance-claude: empty message"))
    (let* ((want-ctx (or (not seance-claude--started) seance-claude--refresh))
           (extra    (if seance-claude--started
                         (list "--resume" seance-claude--session)
                       (list "--session-id" seance-claude--session
                             "--system-prompt" seance-claude-preamble)))
           (buf      (current-buffer))
           ;; spawn once we have the final prompt. The image fetch is async, so
           ;; this may run a beat after the keystroke, with Emacs live the whole
           ;; time instead of frozen behind a synchronous `sly-eval'.
           (go (lambda (full)
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (setq seance-claude--refresh nil)
                     (goto-char (point-max))
                     (insert "\n\n## Claude\n\n")
                     (setq seance-claude--proc
                           (seance-claude--spawn buf full extra
                                                 #'seance-claude--finish-turn)))))))
      (if want-ctx
          ;; we're in the chat buffer, so focus comes from whatever CAPTURE
          ;; stashed back in the Lisp buffer. see `seance--focus'
          (seance-fetch-context
           (lambda (ctx) (funcall go (seance-claude--with-context ctx msg)))
           (seance--profile seance-claude-profile))
        (funcall go msg)))))

;;;###autoload
(defun seance-claude-interrupt ()
  "Stop whatever this chat is in the middle of: the snapshot fetch, or the answer."
  (interactive)
  (cond ((seance-fetching-p)
         (seance-cancel-fetch))
        ((process-live-p seance-claude--proc)
         (seance-claude--stop seance-claude--proc)
         (message "seance-claude: stopped"))
        (t (user-error "Seance-claude: nothing in flight"))))

(defun seance-claude--stop-on-kill ()
  "Stop this chat's answer when the chat buffer goes away.
Nothing else ties the process to the buffer, and left alone it runs to
completion against your usage limit with nowhere to put the answer."
  (when (process-live-p seance-claude--proc)
    (seance-claude--stop seance-claude--proc)))

;;;###autoload
(defun seance-claude (&optional new)
  "Open (or refresh) a CLI-backed chat buffer seeded with the image context.
Runs on your Claude Code subscription. Type after the `## You' prompt, then
\\[seance-claude-send] to send. Re-run it mid-conversation to fold a fresh
snapshot into your next message.

With a prefix argument, NEW starts a separate chat in its own buffer rather
than refreshing an existing one, so two lines of inquiry can stay open at once.
Run from inside a chat buffer it refreshes that buffer, not whichever one
happens to hold the default name."
  (interactive "P")
  (seance-claude--executable)           ; bail now if claude isn't there
  (let* ((name (cond (new (generate-new-buffer-name seance-claude-buffer-name))
                     (seance-claude--session (buffer-name))
                     (t seance-claude-buffer-name)))
         (existing (get-buffer name))
         (buf (get-buffer-create name)))
    (with-current-buffer buf
      (if existing
          (progn
            (setq seance-claude--refresh t)
            (message "Seance-claude: a fresh image snapshot will ride along with your next send"))
        (when (fboundp 'markdown-mode) (markdown-mode))
        (seance-claude-chat-mode 1)
        (setq seance--chat-transport "claude"
              seance-claude--session (seance-claude--uuid)
              seance-claude--started nil
              seance-claude--refresh nil)
        (add-hook 'kill-buffer-hook #'seance-claude--stop-on-kill nil t)
        (insert "# seance-claude chat\n\n"
                "Type below, then `C-c C-c' to send. `C-c C-r' refreshes the "
                "image snapshot, `C-c C-k' stops an answer in progress, "
                "`C-c C-e' evaluates the code block at point. "
                "Runs on your Claude Code subscription.\n\n"
                "## You\n\n")
        (setq seance-claude--input-start (point-marker))))
    (pop-to-buffer buf)
    (goto-char (point-max))))

(provide 'seance-claude)
;;; seance-claude.el ends here
