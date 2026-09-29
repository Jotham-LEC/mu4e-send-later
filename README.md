# mu4e-send-later

Emacs doesn't have to be running. I write an email in mu4e, say when it should
go out, and close Emacs if I like: at that time a systemd user timer (GNU/Linux)
or a launchd job (macOS) starts a background Emacs that sends it. Mail that fell
due while the laptop was asleep goes out when it wakes.

It works whether you write in plain `message-mode` or with org-msg. Scheduled
mail shows up in mu4e, where you can read, edit, reschedule, send or cancel it.

<!-- Screenshot: the Scheduled bookmark in mu4e, with a message or two queued. -->

- **Nothing polls.** One timer is set for the next due message and moved
  whenever the queue changes. An empty queue has no timer at all.
- **It fails loudly.** You're only told "Scheduled" once the timer has been
  created *and* checked. Failed sends are retried, then kept and reported, never
  dropped. A message is sent at most once; if that's ever in doubt, you're told.

## Install

Not on MELPA yet. With `package-vc` (Emacs 29+):

```elisp
(package-vc-install "https://github.com/Jotham-LEC/mu4e-send-later")
```

`use-package` with `:vc` (Emacs 30+):

```elisp
(use-package mu4e-send-later
  :vc (:url "https://github.com/Jotham-LEC/mu4e-send-later" :rev :newest)
  :config (mu4e-send-later-mode 1))
```

straight.el:

```elisp
(straight-use-package
 '(mu4e-send-later :type git :host github :repo "Jotham-LEC/mu4e-send-later"))
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

The background Emacs sends with whatever `message-send-mail-function` was when
you scheduled. If that's message.el's default, it's worked out the way
message.el would, from `send-mail-function`, and that is stored too. Out of the
box `send-mail-function` is `sendmail-query-once`, which asks you how to send,
and nobody's there to answer; so set it (to `smtpmail-send-it`, or
`sendmail-send-it` for msmtp and friends) or set `message-send-mail-function`.

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
- the send function would ask how to send (`sendmail-query-once`, see above);
- the draft has an `X-Message-SMTP-Method` header, which makes message.el send
  it right away through the method it names. That isn't supported yet; take the
  header out to schedule it. `message-server-alist` is ignored while scheduling
  for the same reason;
- a setting it would need can't be stored.

If a background send is under way, scheduling, rescheduling and cancelling wait
up to 5 seconds for it, then say "A send is in progress" so you can try again.
A message that can't be read is left in the queue and reported, and the rest
are sent as usual.

At send time a failure is recorded on the message and retried after 2, 5, 15 and
60 minutes (`mu4e-send-later-retry-delays`), with a desktop notification on the
first failure. After the last retry the message is marked failed, you get an
urgent notification, and it stays in the queue until you retry or cancel it.
Each time Emacs starts, `mu4e-send-later-mode` warns about failed messages. That
also catches the case where the timer never fired at all. A sendmail that
exits 0 but prints something (a warning from msmtp, say) took the message, so
it counts as sent, and what it printed is shown in a notification.

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

- Delivery is at most once (see above). A crash at the wrong moment means a
  message you have to check by hand, never one sent twice.
- Anything that happens *on* send happens when you schedule: Fcc/sent-folder
  copies, deleting the draft, marking the parent as replied. (Gmail users with
  `mu4e-sent-messages-behavior` set to `delete` get the Sent copy at the real
  send time, from Gmail.)
- The copy in the Scheduled maildir is only a view. Deleting or moving it in
  mu4e doesn't cancel the send, and it comes back on the next sync. Use
  `mu4e-send-later-cancel` on it instead. Flagging or marking it read is fine.
- mu4e shows each change straight away, but a newly scheduled message only
  appears in a Scheduled list that is already open once you refresh it (`g`).
- Messages scheduled before the draft was kept (before 2026-09-28) can't be
  edited, only cancelled and written again.
- mu4e is updated through its internal `mu4e--server-add` and
  `mu4e--server-remove`, as of mu 1.14.
- The background Emacs has no access to secrets unlocked in your session. Most
  sendmail setups are fine, including msmtp with `passwordeval`. smtpmail with
  `~/.authinfo.gpg` needs gpg-agent to already have the passphrase cached.
  Nothing can answer a prompt there either: a send that asks for a password
  fails and is retried, rather than waiting.
- A send already under way in the background carries on if you quit Emacs.
- Upgrades. Pending timers and the login job name the Emacs executable and the
  directory this package was loaded from, and an upgrade can move either. The
  startup check re-arms the timers each time Emacs starts, and warns if the
  login job points somewhere stale; re-run `mu4e-send-later-install-login-job`
  then. On Nix the running Emacs's store path can be garbage-collected after an
  upgrade, so set `mu4e-send-later-emacs-program` to a path that survives it.
- Timers are named after the queue directory since 0.3.0. systemd timers armed
  by 0.2 keep their old names; they fire once, send whatever is due, and go
  away. On macOS, 0.2's `com.github.jotham-lec.mu4e-send-later.<number>.plist`
  files in `~/Library/LaunchAgents` are no longer cleaned up; delete them by
  hand.
- **The launchd backend has not been tested on a Mac yet**; reports welcome.
  launchd has minute resolution, so on macOS mail goes out up to a minute late.

## Alternatives

What I looked at before writing this, and why it didn't fit:

- **gnus-delay**, part of Gnus. Delayed messages wait in a Gnus group and go out
  when Gnus next checks for news, so Gnus has to be running. Worth a look if you
  read mail in Gnus.
- **mu4e-send-delay** and **mu4e-delay**. They keep the message as a draft with
  a header saying when to send, and a timer in Emacs sends it, so Emacs has to
  be running at that time.
- **Scheduled send on the server**: Gmail, Fastmail and Outlook all have it in
  their web apps. It doesn't need your computer at all, but it isn't reachable
  over SMTP, so you can't use it from mu4e.
- **msmtpq**, msmtp's queue. It holds mail while you're offline and sends it
  when you're back, which is a different problem: there's no send time.

## Development

```sh
make deps      # install org-msg, package-lint and relint into .deps/
make check     # all of the below but integration; what CI runs
make compile   # byte-compile the package and its tests, warnings are errors
make lint      # checkdoc, package-lint and relint; fails on any warning
make format    # indent as plain emacs -Q does (format-check only reports)
make test      # unit tests, against a fake scheduler and a fake send function
make integration   # real systemd timers, on a queue of its own, and a fake sendmail
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

GPL-3.0-or-later.
