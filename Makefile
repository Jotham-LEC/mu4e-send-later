EMACS ?= emacs
# Test and lint dependencies (org-msg, package-lint), installed by `make deps'.
DEPS = $(CURDIR)/.deps
# Prefer newer sources, so a stale .elc from `make compile' isn't tested.
BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' \
	--eval '(setq package-user-dir "$(DEPS)")' -f package-initialize -L .

.PHONY: all compile test integration lint checkdoc package-lint deps clean

all: compile lint test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile mu4e-send-later.el

test:
	$(BATCH) -l test/mu4e-send-later-test.el -f ert-run-tests-batch-and-exit

# Arms real systemd user timers, for a queue of its own; needs a running
# systemd user manager.
integration:
	MU4E_SEND_LATER_INTEGRATION=1 $(BATCH) -l test/mu4e-send-later-test.el \
	  --eval '(ert-run-tests-batch-and-exit (quote (tag :integration)))'

deps:
	$(BATCH) --eval '(progn (push (quote ("melpa" . "https://melpa.org/packages/")) package-archives) (package-refresh-contents) (package-install (quote org-msg)) (package-install (quote package-lint)))'

lint: checkdoc package-lint

# checkdoc reports through the *Warnings* buffer and exits 0 regardless, so
# print that buffer and fail if there is one.  Emacs 31 turned the verb check
# off by default and 29 and 30 leave it on, so ask for it either way and a
# local run says what CI will.
checkdoc:
	$(BATCH) --eval '(progn (require (quote checkdoc)) (setq checkdoc-verb-check-experimental-flag t) (checkdoc-file "mu4e-send-later.el") (let ((warnings (get-buffer "*Warnings*"))) (when warnings (princ (with-current-buffer warnings (buffer-string))) (kill-emacs 1))))'

package-lint:
	$(BATCH) --eval '(require (quote package-lint))' -f package-lint-batch-and-exit mu4e-send-later.el

clean:
	rm -f *.elc test/*.elc
