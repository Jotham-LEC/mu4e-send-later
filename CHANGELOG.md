# Changelog

All notable changes to mu4e-send-later are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

## [0.2.0] — 2026-09-28

### Added
- **Scheduled mail shows in mu4e.** Each queued message is copied into its own
  maildir, dated when it is due, so a bookmark lists what is scheduled.
- **Edit, reschedule, send now and cancel from mu4e**, on the message at point, as
  well as from the list. Edit reopens the draft as written, back in its Drafts maildir
  and back in org-msg.

## [0.1.0] — 2026-09-27

First version.

### Added
- **`mu4e-send-later`** queues the fully rendered message and sends it from a
  background Emacs started by a systemd user timer or a launchd job, so Emacs needn't
  be running. Elsewhere an Emacs timer is used.
- Scheduling only reports success once the wake-up is verified. Failed sends are
  retried, then kept and reported.
- org-msg drafts can be scheduled as well as `message-mode` ones.

[Unreleased]: https://github.com/Jotham-LEC/mu4e-send-later/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/Jotham-LEC/mu4e-send-later/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Jotham-LEC/mu4e-send-later/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Jotham-LEC/mu4e-send-later/releases/tag/v0.1.0
