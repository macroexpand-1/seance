# Seance Usage Reference

The full description of seance's commands, configuration, condition capture and test setup.
The top-level `README.md` covers what seance is and how to install it; this page covers everything after that.

## Chat Buffers

`seance-claude` and `seance-gptel` each snapshot the image and open a chat buffer about the symbol in focus.

| Key or Command | Chat | Does |
|---|---|---|
| `C-c C-c` | Claude | Sends the message. |
| gptel's send key | gptel | Sends the message, with a fresh snapshot every time. |
| `C-c C-r` | Claude | Folds a fresh snapshot into the next message, for the chat it is pressed in. |
| `C-c C-k` | Claude | Stops a streaming answer, or gives up on a snapshot fetch that never returned. |
| `M-x seance-cancel-fetch` | gptel | Gives up on a snapshot fetch that never returned. |
| `C-c C-e` | Both | Evaluates every form in the code block at point. |
| `C-u M-x seance-claude` | Claude | Opens a second, independent chat in its own buffer. |
| `M-x seance-preview-context` | Either | Shows exactly what would be sent, without sending it. |
| `M-x seance-clear-log` | Either | Clears the eval log. |

If the image is wedged and the snapshot never comes back, a send waits rather than going out without one; the cancel commands above are the way out.

### The Focus Symbol

The focus symbol is taken from wherever something was last evaluated, not from the cursor position.
So asking a question from the chat buffer still asks about the code you were working on, rather than about the word "slow".

### Evaluating Suggested Code

Got an answer with code in it?
`C-c C-e` evaluates every form in the code block at point, in the package that was in use when the chat was opened.
The eval is logged like any other, so the next turn sees what the suggestion actually did.

### The Debugger

Landed in the debugger?
Just ask.
While an SLDB buffer is open, the snapshot carries its condition, its restarts and the top frames (`seance-debugger-frames` sets how many).
Once SLDB closes, that section drops out of the snapshot again.

## Pointing gptel at a Model

The gptel transport needs to know where the model lives.
`M-x seance-gptel-use-openai-compatible` prompts for a name, a host and a model; with a `C-u` prefix it also saves the answers.
To skip the prompts, set them in the init file:

```elisp
(setq seance-gptel-host "localhost:8080"
      seance-gptel-model-name "qwen2.5-coder-7b")
```

The backend is built from those values the first time a gptel chat opens.

## Doom Keybindings

Doom users (me!): `map!` the lot under your localleader and stop typing `M-x`.
Your wrists will thank you.

```elisp
(after! sly
  (map! :localleader :map lisp-mode-map
        (:prefix ("a" . "ask")
         :desc "Claude"             "a" #'seance-claude
         :desc "Local model"        "l" #'seance-gptel
         :desc "Preview context"    "p" #'seance-preview-context
         :desc "Pick local backend" "b" #'seance-gptel-use-openai-compatible
         :desc "Stop the answer"    "k" #'seance-claude-interrupt
         :desc "Clear eval log"     "c" #'seance-clear-log)))
```

## Capturing Conditions

Slynk rebinds `*debugger-hook*` around every request, so a handler installed globally is out of scope by the time a form runs.
The only place to see a form's conditions is inside the form.

For buffer evals (`C-x C-e`, `C-c C-c`, `C-c C-k`), seance can do that automatically:

```elisp
(setq seance-automatic-conditions t)
```

This hangs a wrapper on `slynk:*eval-for-emacs-wrappers*`, which slynk runs around every request from Emacs.
Conditions still reach SLDB as before; seance only records them on the way past.
It is off by default because it also sees SLY's own background requests, so a failure in one of those is recorded too.

The mREPL does not go through that wrapper, so at the REPL the form is wrapped by hand:

```lisp
(slynk-seance:with-captured-conditions
  (your-flaky-thing))
```

It is `handler-bind` underneath, so it only observes: the condition still goes wherever it was going, SLDB included, and a body that does not signal returns its values untouched.
`slynk-seance:note-condition` is exported for building a narrower `handler-bind` by hand.

Either way, captured conditions appear in the next snapshot, newest first.

## Configuration

Everything on the Emacs side is a defcustom; `C-h v seance-` lists them all.
The ones most worth knowing:

| Variable | Default | Effect |
|---|---|---|
| `seance-profile` | `:lean` | `:lean` trims the snapshot for small local models, which have small windows and big opinions; `:full` adds the one-hop callers and callees. |
| `seance-claude-profile` | `:full` | Overrides `seance-profile` for the Claude transport, because Claude can take it. |
| `seance-claude-extra-args` | `nil` | Extra CLI arguments, such as `'("--disallowed-tools" "Edit" "Write" "Bash")` if you want it answering questions rather than rearranging your repo. |
| `seance-claude-lean` | `t` | Runs the CLI in a neutral directory, so it doesn't drag your whole project's `CLAUDE.md` and hooks along for the ride. |
| `seance-context-limit` | `20000` | Caps the assembled snapshot in characters; `nil` removes the ceiling. |
| `seance-automatic-conditions` | `nil` | See [Capturing Conditions](#capturing-conditions). |
| `seance-debugger-frames` | `8` | How many SLDB frames the snapshot carries. |

### How the Context Limit Trims

Every other limit caps one item at a time; `seance-context-limit` caps the assembled total, which is the number that has to fit in the model's window.
Over the limit, sections give up space one at a time, least useful first: the one-hop neighbors go first and the focus definition last.
Every section keeps its heading and says how much it lost, and the eval log drops its oldest entries rather than its newest.

### Image-Side Limit

`slynk-seance:*max-definition-chars*` (default 600) caps any one printed definition.
SBCL hands back the entire source of anything you defined at the REPL, which is everything you actually ask about, so without this a couple of long defuns are the whole snapshot.

## Tests and CI

```sh
make test
make lint
```

The Lisp suite loads the contrib into a real SBCL and checks the snapshot it produces.
The Emacs suite stubs out `sly-eval`, checks everything up to the point where bytes leave the building, and runs the Claude transport against `test/fake-claude`, a shell script that prints canned stream-json.
No test spends a token.

`make lint` runs package-lint and checkdoc and fails on anything either reports.
It needs a network connection, because package-lint checks that the dependencies are installable.

Paths to dependencies `make` cannot find are passed as variables:

| Variable | Points At |
|---|---|
| `SLY_DIR` | A sly checkout. |
| `GPTEL_DIR` | A gptel checkout; without it the tests that need gptel skip. |
| `PACKAGE_LINT_DIR` | A package-lint checkout, for `make lint`. |

CI runs the Emacs suite both with and without gptel, on Emacs 28.2, 29.4 and 30.1.
It tests against pinned commits of sly and gptel, and once a week against their heads, so an upstream change shows up as a red scheduled run rather than as a mystery failure on a PR.

## Implementation Notes

### Where the Image Side Must Live

`slynk-seance.lisp` and `slynk-seance.asd` are located relative to `seance.el` and must sit in the same directory.
SLY usually loads slynk through ASDF, which is why the `.asd` is needed at all.

### A Broken Image Side

If `slynk-seance.lisp` fails to load, SLY enters SLDB on connect.
Pick the "Continue without SLY contrib slynk-seance" restart and you're back in business, minus seance.
