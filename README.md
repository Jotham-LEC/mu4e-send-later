# mu4e-send-later

Schedule an email in mu4e to go out later instead of now, whether you write it
in plain `message-mode` or with org-msg. Scheduled mail shows up in mu4e, where
you can read, edit, reschedule, send or cancel it.

- **Emacs doesn't need to be running.** On GNU/Linux a systemd user timer does
  the waking; on macOS a launchd job. Mail sent while the laptop was asleep goes
  out on wake.
- **Nothing polls.** One timer is set for the next due message and moved
  whenever the queue changes. An empty queue has no timer at all.
- **It fails loudly.** You're only told "Scheduled" once the timer has been
  created *and* checked. Failed sends are retried, then kept and reported, never
  dropped.

## Install

Not on MELPA yet. With `package-vc` (Emacs 29+):

```elisp
(package-vc-install "https://github.com/Jotham-LEC/mu4e-send-later")
```

Doom Emacs (`packages.el`):

```elisp
(package! mu4e-send-later
  :recipe (:host github :repo "Jotham-LEC/mu4e-send-later"))
```

Then turn on the mode, which sends overdue mail and re-arms the timer each time
Emacs starts:

```elisp
(mu4e-send-later-mode 1)
```

Add a bookmark for the scheduled mail. It lives in its own maildir,
`mu4e-send-later-maildir` (`/scheduled` under mu's root); make sure your mail
sync doesn't upload it. mbsync only syncs the folders its channels name.

```elisp
(add-to-list 'mu4e-bookmarks
             '(:name "Scheduled" :query "maildir:/scheduled" :key ?s))
```

There are no default key bindings. For example:

```elisp
(with-eval-after-load 'mu4e
  (define-key mu4e-compose-mode-map (kbd "C-c C-S-s") #'mu4e-send-later)
  (dolist (map (list mu4e-headers-mode-map mu4e-view-mode-map))
    (define-key map (kbd "C-c s e") #'mu4e-send-later-edit)
    (define-key map (kbd "C-c s r") #'mu4e-send-later-reschedule)
    (define-key map (kbd "C-c s s") #'mu4e-send-later-send-now)
    (define-key map (kbd "C-c s c") #'mu4e-send-later-cancel)))
```

org-msg drafts use their own mode, derived from `org-mode` rather than
`message-mode`, so bind `mu4e-send-later` there too:

```elisp
(with-eval-after-load 'org-msg
  (define-key org-msg-edit-mode-map (kbd "C-c C-S-s") #'mu4e-send-later))
```

An org-msg draft is rendered to HTML and plain text when you schedule it, and
org-msg's check for a forgotten attachment runs then too.

## Use

| | |
|---|---|
| `M-x mu4e-send-later` | in a draft: ask for a time, confirm it, queue the message |
| `M-x mu4e-send-later-edit` | unschedule it and reopen the draft as you wrote it, org-msg included |
| `M-x mu4e-send-later-reschedule` | move it to another time |
| `M-x mu4e-send-later-send-now` | send it now, or retry it after it failed |
| `M-x mu4e-send-later-cancel` | unschedule it, keeping a copy in the queue's `cancelled/` |
| `M-x mu4e-send-later-list` | the queue with its state and last error; `RET` view, `e` `r` `s` `c` as above |
| `M-x mu4e-send-later-check` | send anything overdue, re-arm, report failures |
| `M-x mu4e-send-later-install-login-job` | also send overdue mail at login, without opening Emacs |

The four commands in the middle act on the scheduled message at point, in the
Scheduled bookmark (the message list or an open message) or in the list. In mu4e
the date shown is when it will be sent.

The time is read by `org-read-date`: `+2h`, `16:30`, `+1d 8:30`, `mon 14:00`.
You're always shown the date it was read as before anything is queued, because
`org-read-date` reads `+30m` as thirty *months* and `tomorrow 9am` as today.

## How it works

Every `message-mode` client sends through one pluggable step,
`message-send-mail-function`, which receives the finished message: headers
generated, org-msg HTML rendered, MIME-encoded. `mu4e-send-later` does a normal
send with that step swapped for "store in the queue". It also stores your
send function and the settings it reads (`sendmail-program`, `smtpmail-*`,
see `mu4e-send-later-variables`).

At the due time the scheduler starts `emacs --batch -Q` with this package, which
restamps the `Date:` header and calls the stored send function with the stored
settings. Your init file is not loaded, so the result doesn't depend on the
state of your interactive session.

| Backend | Where | Sends while Emacs is closed | After reboot |
|---|---|---|---|
| `systemd` | GNU/Linux with a systemd user manager | yes | when Emacs starts, or at login with the login job |
| `launchd` | macOS | yes | when Emacs starts, or at login with the login job |
| `emacs` | anywhere else | no | when Emacs starts |

`mu4e-send-later-backend` defaults to `auto`, which picks the first that works.
X11 or Wayland makes no difference.

For mu4e, each queued message is also copied into `mu4e-send-later-maildir`,
dated when it is due, and added to mu's index; the copy is removed once the
message is sent, edited or cancelled. Only your interactive Emacs touches that
maildir. It catches up when mu4e starts, after each change you make, and, by
watching the queue, when the background sender sends something.

## When things go wrong

At scheduling time, each of these is an error, and the draft stays open:

- no usable scheduler, or the timer wasn't there after creating it;
- the Emacs executable the timer would run doesn't exist;
- a trial run of the background Emacs, in the scheduler's own environment,
  can't find your send function or `sendmail-program`;
- a setting it would need can't be stored.

At send time a failure is recorded on the message and retried after 2, 5, 15 and
60 minutes (`mu4e-send-later-retry-delays`), with a desktop notification on the
first failure. After the last retry the message is marked failed, you get an
urgent notification, and it stays in the queue until you retry or cancel it.
Each time Emacs starts, `mu4e-send-later-mode` warns about failed messages. That
also catches the case where the timer never fired at all.

Delivery is at most once, and loud about it. A message is marked `sending`
just before it's handed to your send function. If the sender dies right then
(a crash, a power cut), there's no way to know whether the mail server already
took it, so it is never sent again on its own. The next run marks it failed
with "may have been sent, please check", with an urgent notification. I'd
rather tell you than send it twice. Look in your Sent folder or ask the
recipient, then `send-now` or `cancel` it.

Errors are signalled as `mu4e-send-later-backend-error` or
`mu4e-send-later-send-error`, both children of `mu4e-send-later-error`.
Everything is logged to `~/.local/state/mu4e-send-later/log`.

## Caveats

- Anything that happens *on* send happens when you schedule: Fcc/sent-folder
  copies, deleting the draft, marking the parent as replied. (Gmail users with
  `mu4e-sent-messages-behavior` set to `delete` get the Sent copy at the real
  send time, from Gmail.)
- mu4e shows each change straight away, but a newly scheduled message only
  appears in a Scheduled list that is already open once you refresh it (`g`).
- Messages scheduled before the draft was kept (before 2026-09-28) can't be
  edited, only cancelled and written again.
- mu4e is updated through its internal `mu4e--server-add` and
  `mu4e--server-remove`, as of mu 1.14.
- The background Emacs has no access to secrets unlocked in your session. Most
  sendmail setups are fine, including msmtp with `passwordeval`. smtpmail with
  `~/.authinfo.gpg` needs gpg-agent to already have the passphrase cached.
- On Nix, the running Emacs's store path can be garbage-collected after an
  upgrade, taking pending timers' executable with it. The startup check will
  tell you. Set `mu4e-send-later-emacs-program` to a path that survives
  upgrades, and re-run `mu4e-send-later-install-login-job` after upgrading if you
  use it.
- launchd has minute resolution, so on macOS mail goes out up to a minute late.
  **The launchd backend has not been tested on a Mac yet**; reports welcome.

## Development

```sh
make compile   # byte-compile, warnings are errors
make deps      # install org-msg from MELPA into .deps/, for its tests
make test      # unit tests, against a fake scheduler and a fake send function
make integration   # real systemd timers and a fake sendmail (GNU/Linux)
make lint      # checkdoc
```

## License

GPL-3.0-or-later.
