# Changelog

All notable changes to mu4e-send-later are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **A `print-length` or `print-level` of your own refused valid settings.** The
  check that a setting can be stored for the background sender printed it with
  them, so a long or deep list came back cut short and scheduling failed. It is
  now printed in full, as the queue stores it.
- **Mail sent in the background while a command read the queue** made it fail
  with a raw `file-missing` error: the startup check, before it sent overdue
  mail, the list, as it refreshed on its own, and cancel. The message is now
  taken as gone: left out, or for cancel, said to have been sent.
- **Edit failed for mail scheduled from mu4e or org-msg** when that package
  wasn't loaded yet, as their modes aren't autoloaded, and left an empty buffer
  behind. It is now loaded first, and if it can't be, the draft opens in
  `message-mode`. A draft that can't be opened leaves no buffer behind.
- **The copies of scheduled mail shown in mu4e could be read by other users**:
  `mu4e-send-later-maildir` and its messages were made with your umask, though
  they hold the whole message, Bcc included. Like the queue, the maildir is now
  readable only by you, and made so if it exists, and its messages too.
- **Two senders that found the same stale lock could both take it**, and so
  both send the same message: one could break it and take it between the other
  checking it was still the stale one and removing it. A stale lock is now moved
  aside first, which only one sender can do, and only removed if it is still the
  stale one; if not, it is put back. One with no owner written is still only
  broken once it is old.

## [0.3.1] — 2026-09-29

Fixes from a second and a third review: mail sent more than once, or at the
wrong time, sends killed or hung, and locks, drafts and wake-ups left in a bad
state.

### Fixed
- **A sendmail that warned was sent again with every retry.** message.el calls a
  sendmail that exits 0 but prints anything, as msmtp does about an expiring
  certificate, a failure, so the message was retried and delivered up to five
  times. It now counts as sent, with a notification of what sendmail said.
- **Quitting Emacs killed a background send**, the one started for overdue mail,
  send-now or the `emacs` backend, leaving the message "may have been sent". It
  now runs under nohup and finishes after Emacs quits.
- **A send function that prompted hung the background send**, holding the queue
  lock. It now has no stdin, so the prompt fails and the send is retried.
- **A dead sender's lock blocked everything for 15 minutes.** A lock whose owner
  is on this host is now broken as soon as that process is gone, or its PID has
  been reused. A live owner's lock is never broken. Locks with no owner, or one
  on another host, still wait 15 minutes.
- **A failed schedule left an org-msg draft as MML**, with the headers
  message.el adds, and scheduling it again kept that as the draft to edit. The
  draft is now put back as written.
- **Cancel and edit losing the race to a send.** Cancel showed a raw
  `file-missing` error, and edit said the original was still scheduled and to
  cancel it, when it had been sent. Both now say it was sent, and edit that
  sending the draft would send it again.
- **send-now and reschedule resent a message whose send was interrupted**,
  before the next run could mark it "may have been sent". They now refuse, and
  mark it so, and doing it again is your choice.
- **A failed schedule could silently leave earlier mail without a wake-up.**
  That now gets an urgent notification.
- **The list's Due column sorted by weekday name.** It sorts by time.
- **A TIME with a fraction of a second** queued a message that couldn't be read
  back. Any Lisp time value is now rounded down to a second.
- **After a package.el upgrade, pending wake-ups ran the old, deleted
  directory.** Loading the package again with the mode on re-arms them, from the
  directory it was loaded from rather than wherever `load-path` finds it first.
- **The background Emacs loaded a stale .elc** over newer source beside it.
- **launchd**, checked by hand on a GitHub macOS runner, where a new CI job runs
  the integration test: jobs get Emacs's `PATH`, not only the system
  directories; loading a job that is loaded no longer fails; a job unloads
  itself once it has run, instead of staying loaded to fire again next year; and
  a job knows itself by a variable its plist sets, not only by launchd's
  `XPC_SERVICE_NAME`.
- **A failure after the message was queued put the draft back** and said
  scheduling failed: an error writing the Fcc copy or in `message-sent-hook`, or
  C-g as the draft closed. The message was scheduled all the same, so scheduling
  it again sent it twice; and once the draft was killed, the text replaced
  whatever buffer was current. That is now a warning, and the message is
  reported scheduled.
- **C-g while the wake-up was armed** left the message queued, with the draft
  open as though it weren't. It is taken back out, as on any other failure.
- **Reschedule could move another message.** If the message was sent while you
  typed the time, the list refreshed and the message then at point was moved.
  It is the message you asked about, or you're told it was sent.
- **launchd: a job that fired early left nothing to send.** launchd's calendar
  is local time, so a job fires early after a move to a zone further east, or
  as summer time ends. It re-armed for the same time, as itself, then unloaded
  itself. It now arms another job.
- **With Gnus started, its agent took the message** instead of the scheduler,
  queueing it in Gnus while unplugged.
- **A failed schedule lost point** and left the rendered message on the undo
  list. Both are as they were.
- **`unload-feature`** left the mode's watch on the queue, raising an error at
  each change to it.
- **Edit failed for a draft message.el saved itself**, outside any maildir, when
  mu4e was loaded. It opens in a buffer of its own.
- **A failed write left a copy of the message** in a temporary directory in the
  queue, which nothing removed.
- **The startup check warned about the login job** when the path of Emacs or of
  the package held a character the unit file or plist escapes.
- **send-now could report the sender broken.** It arms the wake-up and starts a
  send too; if the first of them held the queue for over a minute, the second
  gave up with an urgent "sender broken". A background sender that finds a live
  sender on this host busy with the queue now leaves it to that one, which
  re-arms as it finishes, and exits quietly. Whatever holds the queue now
  re-arms even when what it was doing fails, so a wake-up that fired meanwhile
  isn't lost. A sender on another host, or one idle for 15 minutes, is waited
  for as before.
- **systemd expanded `$` in the paths it was given.** A queue, package or Emacs
  path with `${VAR}` or `$VAR` in it ran something else. Escaping it as `$$`
  only works until `systemctl daemon-reload`, which from systemd 254 doubles
  every `$` in a timer's command, so the command now reaches systemd in
  environment variables, which it passes as they are, on every version. The
  login job's unit gives the path of Emacs apart from the command, as systemd
  expands `$` in one and not the other, and installing it refuses a path systemd
  won't run, one with quotes or a backslash.

### Changed
- The README says what "at most once" covers: a send cut short is never repeated
  on its own, but a send that fails after the server took the message is retried
  and arrives twice.
- `make check` byte-compiles the tests too, with every warning an error, and
  adds relint, a check of `emacs -Q` formatting, and a test of each option's
  default against its type. CI tests Emacs 29.1, 30.1, 31.1 and snapshot, runs
  the integration test against launchd on macOS, and fails on melpazoid
  warnings.
- The CHANGELOG no longer links to tags that were never made.

## [0.3.0] — 2026-09-28

A review of what could send mail twice, send it now, or not send it at all.

### Changed
- **Delivery is at most once.** A message is marked `sending` before it is handed to
  the send function. If the sender dies then, the next run marks it failed, "may have
  been sent, please check", with an urgent notification, and never sends it again on
  its own. Before, it was sent again.
- **Timers are named after their queue.** systemd units and launchd labels carry a
  short hash of the queue directory, and disarming only touches that queue's. Before,
  any queue, the integration test's included, stopped every other queue's timers.
  Timers armed by 0.2 keep their old names and expire by themselves; on macOS, 0.2's
  plists are no longer cleaned up.
- **The queue is private.** Its directory is 0700 and what's in it is written 0600,
  and an existing queue is made private too.
- **Your own Emacs waits 5 seconds for the lock, not a minute**, then says "A send is
  in progress". Background senders still wait a minute.
- `-check`, `-edit`, `-cancel`, `-send-now` and `-reschedule` are autoloaded.
- `mu4e-send-later-retry-delays` is typed as natural numbers.

### Fixed
- **With message.el's default send function the background Emacs couldn't send.** It
  fell back to `sendmail-query-once`, which asks on stdin. The default is now resolved
  the way message.el does it, `send-mail-function` is stored with the other settings,
  and scheduling is refused, by the preflight too, when it would end in
  `sendmail-query-once`.
- **A draft with `X-Message-SMTP-Method` was sent immediately.** message.el sends such
  a message itself. It is now refused before anything is sent, and
  `message-server-alist` can't add the header while scheduling.
- **The queue lock could be broken while its holder was still sending**, and released
  by someone who no longer held it. The lock records its owner, counts as stale only
  when old and its owner isn't running on this host, is refreshed during a flush, and
  is only deleted by its owner.
- **A failed cleanup after a good send was counted as a failed send** and retried.
- **One unreadable `meta.eld` stopped the whole queue.** Such an item is now skipped,
  reported and left for you; the rest are sent.
- **`mu4e-send-later-edit` unscheduled before opening the draft**, so a draft that
  failed to open was lost from view. It now opens the draft first.
- **Rescheduling a message that had just been sent** raised a bare `file-missing`; it
  now says it was already sent.
- **Flagging the Scheduled copy in mu4e made a second copy**, because mu4e renames the
  file. Copies are matched by queue ID.
- **The login job check** now also warns when the job loads this package from a
  directory it has moved out of, as after an upgrade. On macOS it never worked: it
  read the job's label as its program.
- Loading a launchd job no longer boots out the job that is running.
- Turning the mode off removes its startup hook and cancels a pending mu4e resync.
- `make lint` fails on checkdoc warnings, and runs package-lint. CI adds Emacs 31.1
  and melpazoid.

## 0.2.0 — 2026-09-28

### Added
- **Scheduled mail shows in mu4e.** Each queued message is copied into its own
  maildir, dated when it is due, so a bookmark lists what is scheduled.
- **Edit, reschedule, send now and cancel from mu4e**, on the message at point, as
  well as from the list. Edit reopens the draft as written, back in its Drafts maildir
  and back in org-msg.

## 0.1.0 — 2026-09-27

First version.

### Added
- **`mu4e-send-later`** queues the fully rendered message and sends it from a
  background Emacs started by a systemd user timer or a launchd job, so Emacs needn't
  be running. Elsewhere an Emacs timer is used.
- Scheduling only reports success once the wake-up is verified. Failed sends are
  retried, then kept and reported.
- org-msg drafts can be scheduled as well as `message-mode` ones.

[Unreleased]: https://github.com/Jotham-LEC/mu4e-send-later/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/Jotham-LEC/mu4e-send-later/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Jotham-LEC/mu4e-send-later/releases/tag/v0.3.0
