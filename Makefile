EMACS ?= emacs
# Test-only dependencies (org-msg), installed by `make deps'.
DEPS = $(CURDIR)/.deps
# Prefer newer sources, so a stale .elc from `make compile' isn't tested.
BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' \
	--eval '(setq package-user-dir "$(DEPS)")' -f package-initialize -L .

.PHONY: all compile test integration lint deps clean

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
	$(BATCH) --eval '(progn (push (quote ("melpa" . "https://melpa.org/packages/")) package-archives) (package-refresh-contents) (package-install (quote org-msg)))'

lint:
	$(BATCH) --eval '(progn (require (quote checkdoc)) (checkdoc-file "mu4e-send-later.el"))'

clean:
	rm -f *.elc test/*.elc
