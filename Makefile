EMACS ?= emacs
# Test and lint dependencies (org-msg, package-lint, relint), installed by
# `make deps'; one directory per Emacs version, as their .elc files differ.
DEPS = $(CURDIR)/.deps/$(shell $(EMACS) -Q --batch --eval '(princ emacs-version)')
# Prefer newer sources, so a stale .elc from `make compile' isn't tested.
BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' \
	--eval '(setq package-user-dir "$(DEPS)")' -f package-initialize -L .

PACKAGE = mu4e-send-later.el
TESTS = test/mu4e-send-later-test.el

.PHONY: all check compile test integration lint checkdoc package-lint relint \
	format format-check deps clean

all: check

check: compile lint format-check test

# The tests are compiled like the package, so their warnings fail too.
compile:
	$(BATCH) --eval '(setq byte-compile-warnings (quote all) byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(PACKAGE) $(TESTS)

test:
	$(BATCH) -l $(TESTS) -f ert-run-tests-batch-and-exit

# Arms real systemd user timers, or on macOS real launchd jobs, for a
# queue of its own; needs a running systemd user manager, or a login
# session on macOS.
integration:
	MU4E_SEND_LATER_INTEGRATION=1 $(BATCH) -l $(TESTS) \
	  --eval '(ert-run-tests-batch-and-exit (quote (tag :integration)))'

deps:
	$(BATCH) --eval '(progn (setq package-quickstart-file (expand-file-name "quickstart.el" package-user-dir)) (push (quote ("melpa" . "https://melpa.org/packages/")) package-archives) (package-refresh-contents) (dolist (p (quote (org-msg package-lint relint))) (package-install p)))'

lint: checkdoc package-lint relint

# checkdoc reports through the *Warnings* buffer and exits 0 regardless, so
# print that buffer and fail if there is one.  Emacs 31 turned the verb check
# off by default and 29 and 30 leave it on, so ask for it either way and a
# local run says what CI will.
checkdoc:
	$(BATCH) --eval '(progn (require (quote checkdoc)) (setq checkdoc-verb-check-experimental-flag t) (checkdoc-file "$(PACKAGE)") (let ((warnings (get-buffer "*Warnings*"))) (when warnings (princ (with-current-buffer warnings (buffer-string))) (kill-emacs 1))))'

package-lint:
	$(BATCH) --eval '(require (quote package-lint))' -f package-lint-batch-and-exit $(PACKAGE)

relint:
	$(BATCH) --eval '(require (quote relint))' -f relint-batch $(PACKAGE) $(TESTS)

# Indented as plain `emacs -Q' indents; see test/format.el.
format:
	$(BATCH) -l test/format.el $(PACKAGE) $(TESTS)

format-check:
	$(BATCH) -l test/format.el --check $(PACKAGE) $(TESTS)

clean:
	rm -f *.elc test/*.elc
