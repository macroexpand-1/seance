.POSIX:
.PHONY: test test-lisp test-elisp compile lint clean

EMACS ?= emacs
SBCL  ?= sbcl

# Where sly's elisp lives. Override if yours is elsewhere:
#   make test SLY_DIR=/path/to/sly
SLY_DIR ?= $(firstword $(wildcard \
	$(HOME)/.config/emacs/.local/straight/repos/sly \
	$(HOME)/.emacs.d/.local/straight/repos/sly \
	$(HOME)/.emacs.d/straight/repos/sly))

# Where gptel's elisp lives. Optional: gptel is a soft dependency, and without
# it the tests that need it skip rather than fail. Set it to exercise them:
#   make test GPTEL_DIR=/path/to/gptel
GPTEL_DIR ?= $(firstword $(wildcard \
	$(HOME)/.config/emacs/.local/straight/repos/gptel \
	$(HOME)/.emacs.d/.local/straight/repos/gptel \
	$(HOME)/.emacs.d/straight/repos/gptel))

GPTEL_LOAD = $(if $(GPTEL_DIR),-L "$(GPTEL_DIR)")

# Where package-lint lives, for `make lint' only.
PACKAGE_LINT_DIR ?= $(firstword $(wildcard \
	$(HOME)/.config/emacs/.local/straight/repos/package-lint \
	$(HOME)/.emacs.d/.local/straight/repos/package-lint \
	$(HOME)/.emacs.d/straight/repos/package-lint))

test: test-lisp test-elisp

## Image side: image-context, callers/callees, the conditions ring.
test-lisp:
	$(SBCL) --dynamic-space-size 2048 --script test/run-tests.lisp

## Emacs side: capture, assemble, and both transports' argument handling.
## Needs sly on the load-path.
##
## load-prefer-newer, because `load' otherwise takes a stale .elc over a newer
## .el and only warns about it, which quietly tests the code you had before
## your last edit. `make compile' leaves those .elc files lying around, so this
## is the normal state, not a corner case.
test-elisp: guard-sly
	$(EMACS) -Q --batch \
	  --eval '(setq load-prefer-newer t)' \
	  -L . -L test -L "$(SLY_DIR)" -L "$(SLY_DIR)/lib" $(GPTEL_LOAD) \
	  -l test/seance-test.el \
	  -l test/seance-claude-test.el \
	  -l test/seance-gptel-test.el \
	  -f ert-run-tests-batch-and-exit

## Byte-compile every package; warnings are failures. Core first.
## gptel goes on the load-path when we have it, so the compiler can actually
## see its symbols: that is what turns "you wrote an obsolete variable name"
## from a runtime surprise into a build failure.
compile: guard-sly
	$(EMACS) -Q --batch \
	  -L . -L "$(SLY_DIR)" -L "$(SLY_DIR)/lib" $(GPTEL_LOAD) \
	  --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
	  -f batch-byte-compile seance.el seance-claude.el seance-gptel.el

## package-lint and checkdoc; any complaint fails. Fetches the GNU and NonGNU
## ELPA indexes, because package-lint checks that every dependency installs.
lint:
	@test -n "$(PACKAGE_LINT_DIR)" || { \
	  echo "PACKAGE_LINT_DIR is unset and package-lint was not found. Try: make lint PACKAGE_LINT_DIR=/path/to/package-lint"; \
	  exit 1; }
	$(EMACS) -Q --batch -L "$(PACKAGE_LINT_DIR)" -l test/lint.el

guard-sly:
	@test -n "$(SLY_DIR)" || { \
	  echo "SLY_DIR is unset and sly was not found. Try: make test SLY_DIR=/path/to/sly"; \
	  exit 1; }

## run-tests.lisp compiles the fixture into a scratch dir under the system
## temporary directory, not next to the source, so that is where the fasls are.
clean:
	rm -f *.elc test/*.elc
	rm -rf "$${TMPDIR:-/tmp}/seance-test-build"
