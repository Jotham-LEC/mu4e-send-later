EMACS ?= emacs
BATCH = $(EMACS) -Q --batch -L .

.PHONY: all compile test integration lint clean

all: compile lint test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile mu4e-send-later.el

test:
	$(BATCH) -l test/mu4e-send-later-test.el -f ert-run-tests-batch-and-exit

# Arms real systemd user timers; needs a running systemd user manager.
integration:
	MU4E_SEND_LATER_INTEGRATION=1 $(BATCH) -l test/mu4e-send-later-test.el \
	  --eval '(ert-run-tests-batch-and-exit (quote (tag :integration)))'

lint:
	$(BATCH) --eval '(progn (require (quote checkdoc)) (checkdoc-file "mu4e-send-later.el"))'

clean:
	rm -f *.elc test/*.elc
