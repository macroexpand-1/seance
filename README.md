# seance

Come commune with the live image.

When you're twenty redefinitions deep at the REPL, the files on disk are fiction.
The image is the truth. 
So stop pasting source into a chat window. 
Relax, un-wind (the stack) and send the image instead: the symbol at point, who calls it and what it calls.
What you just typed at the REPL and what came back, whatever conditions blew up recently, the debugger you're sitting in, the compiler's complaints, and the evals you just ran.

It's a SLY contrib.
It talks to Claude, or to whatever local model you've got warm.
It's half ELisp for integrating and half Common Lisp for working with the image.

## Two transports

- **`seance-claude`**: shells out to the `claude` CLI, headless. Runs on your
  Claude Code subscription, so no API key. That's the only reason it exists.
- **`seance-gptel`**: gptel, pointed at any OpenAI-compatible server. llama.cpp,
  Ollama, MLX, whatever. Nothing leaves the box.

gptel could talk to Claude too, but it wants an API key for the privilege. 
I'm pretty cheap.

Load one or both. Loading both won't log your evals twice: there's one capture ring in the core. 
So rest easy, multi-model native.

## You'll need

SBCL and SLY. 
Emacs 28.1+ (I use Emacs 31+). 
You need `claude` CLI on your PATH for one transport, or gptel plus something to point it at for the other. 
The image side leans on `sb-introspect`, so SBCL is the only thing that's been tested.
I don't really anticipate supporting beyond SBCL.

## Install

```elisp
;; packages.el
(package! seance :recipe (:host github :repo "real-limoges/seance"
                          :files ("seance*.el" "slynk-seance.lisp" "slynk-seance.asd")))
```

```elisp
;; config.el
(after! sly
  (add-to-list 'sly-contribs 'seance)
  (when (require 'seance-claude nil t)
    (define-key sly-mode-map (kbd "C-c C-S-y") #'seance-claude))
  (when (require 'seance-gptel nil t)
    (define-key sly-mode-map (kbd "C-c C-S-l") #'seance-gptel)))
```

It's a real SLY contrib, so that `add-to-list` is the one line of setup.
SLY does the rest on every connection: it loads the image side and seance starts capturing.
`M-x sly-disable-contrib` turns the whole thing off again.

`slynk-seance.lisp` and `slynk-seance.asd` have to sit next to `seance.el`: that's how SLY finds them.
Don't fight it.
Otherwise just clone it and shove the directory on your `load-path`.

## Using It

Point at a symbol, hit the key, a chat buffer opens.
In the Claude one, `C-c C-c` sends, `C-c C-r` folds a fresh snapshot into your next message, and `C-c C-k` stops an answer you've already seen enough of.
The gptel one sends with whatever key gptel already uses, and re-snapshots every time.
Point at it first with `M-x seance-gptel-use-openai-compatible`.

Suspicious of an answer?
`M-x seance-preview-context` shows you exactly what would be sent, without sending it.
Nine times out of ten the snapshot was wrong before the model was.

Everything else (the rest of the keys, evaluating suggested code, the debugger, capturing conditions, the knobs, Doom bindings, and the tests) is in [the usage reference](docs/reference/internal/usage.md).

## Tests

`make test` runs both suites; nothing spends a token.
`make lint` runs package-lint and checkdoc.

## Gotcha!

You didn't think it would be this easy.
`slynk-backend:calls-who` returns `:NOT-IMPLEMENTED` on SBCL.
It doesn't signal, it just hands you a keyword and lets you find out the hard way.
So `callees` asks `sb-introspect` directly instead.
Without that the callee list is silently always empty, and the one-hop expansion (the whole point of `:full`) never runs.

Ask me how I know (plz don't)

## License

BSD-2-Clause. See [LICENSE](LICENSE).
