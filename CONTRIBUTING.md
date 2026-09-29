# Contributing

- `make check` must pass: it byte-compiles the package and its tests with every
  warning an error, runs checkdoc, package-lint and relint, checks formatting,
  and runs the tests. `make deps` installs what it needs.
- Every fix comes with a regression test that fails without the fix. Check that
  it does: undo the fix, see the test fail, put it back.
- Tests stub only the boundaries with the operating system and other processes
  (the scheduler, notifications, mu), never the behaviour under test.
- Tests are compiled like the package, so they must compile cleanly too.
- Formatting is plain `emacs -Q` indentation: run `make format`. Quoted lists of
  data go one item per line, so every setup indents them the same way.
