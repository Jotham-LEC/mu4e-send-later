;;; mu4e-send-later.el --- Schedule mail to be sent later -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jotham Lim

;; Author: Jotham Lim <jotham@cothink.ing>
;; Assisted-by: Claude:claude-opus-5-5
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: mail
;; URL: https://github.com/Jotham-LEC/mu4e-send-later
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Schedule a message in mu4e to go out later instead of now, whether
;; written in `message-mode' or with org-msg.
;;
;; `mu4e-send-later' renders the draft exactly as a normal send would,
;; but instead of handing it to `message-send-mail-function' it stores
;; the finished message, plus the settings needed to send it, in a queue
;; directory.  The operating system's scheduler (systemd on GNU/Linux,
;; launchd on macOS) then starts a background Emacs at the due time to
;; send it, so Emacs doesn't need to be running.  Where neither is
;; available an ordinary Emacs timer is used, which only fires while
;; Emacs runs.
;;
;; Nothing is reported as scheduled until the wake-up has been verified,
;; and a message is never dropped: failed sends are retried, then left in
;; the queue marked failed, with desktop notifications and warnings in
;; Emacs along the way.
;;
;; Setup:
;;
;;   (mu4e-send-later-mode 1)   ; sends overdue mail and re-arms at startup
;;
;; then `M-x mu4e-send-later' in a draft.  Scheduled mail shows in mu4e
;; under `mu4e-send-later-maildir'; on a message there, or in `M-x
;; mu4e-send-later-list', `mu4e-send-later-edit', `-reschedule',
;; `-send-now' and `-cancel' act on it.

;;; Code:

(require 'cl-lib)
(require 'filenotify)
(require 'message)
(require 'rfc2047)
(require 'subr-x)
(require 'tabulated-list)

(declare-function notifications-notify "notifications" (&rest params))
(declare-function org-read-date "org"
                  (&optional with-time to-time from-string prompt
                             default-time default-input inactive))
(declare-function org-msg-sanity-check "ext:org-msg" ())
(declare-function org-msg-edit-mode "ext:org-msg" ())
(declare-function mu4e-running-p "ext:mu4e-server" ())
(declare-function mu4e-root-maildir "ext:mu4e-server" ())
(declare-function mu4e--server-add "ext:mu4e-server" (path))
(declare-function mu4e--server-remove "ext:mu4e-server" (docid-or-path))
(declare-function mu4e-message-at-point "ext:mu4e-message" (&optional noerror))
(declare-function mu4e--draft "ext:mu4e-draft" (compose-type compose-func &optional parent))
(declare-function mu4e--delimit-headers "ext:mu4e-draft" (&optional undelimit))

(defvar mu4e-send-later-mode)
(defvar send-mail-function)
(defvar mu4e-send-later--sync-timer)

;;;; Customization

(defgroup mu4e-send-later nil
  "Schedule mail to be sent later."
  :group 'message
  :prefix "mu4e-send-later-")

(defcustom mu4e-send-later-directory
  (expand-file-name "mu4e-send-later/"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "Directory holding the queue of scheduled messages."
  :type 'directory)

(defcustom mu4e-send-later-backend 'auto
  "What wakes up to send a message once it is due.
`systemd' uses a transient systemd user timer, `launchd' a macOS
LaunchAgent; both send even if Emacs isn't running.  `emacs' uses
an Emacs timer, so mail only goes out while Emacs runs.  `auto'
picks the first of these that works here."
  :type '(choice (const :tag "Detect" auto)
                 (const :tag "systemd user timer" systemd)
                 (const :tag "macOS launchd" launchd)
                 (const :tag "Emacs timer (only while Emacs runs)" emacs)))

(defcustom mu4e-send-later-emacs-program nil
  "Emacs executable that sends queued mail in the background.
nil means the Emacs that is running now.  Set this if that path
can disappear, as it can on Nix after the store is garbage-collected."
  :type '(choice (const :tag "The running Emacs" nil) file))

(defcustom mu4e-send-later-retry-delays '(120 300 900 3600)
  "Seconds to wait before each retry of a failed send.
Once these are used up the message is marked failed and left in the
queue for you to retry or cancel from `mu4e-send-later-list'."
  :type '(repeat natnum))

(defcustom mu4e-send-later-variables
  '(user-mail-address
    user-full-name
    mail-host-address
    sendmail-program
    mail-specify-envelope-from
    mail-envelope-from
    message-sendmail-f-is-evil
    message-sendmail-envelope-from
    message-sendmail-extra-arguments
    smtpmail-smtp-server
    smtpmail-smtp-service
    smtpmail-smtp-user
    smtpmail-stream-type
    smtpmail-local-domain
    smtpmail-sendto-domain
    smtpmail-servers-requiring-authorization
    smtpmail-smtp-extra-args
    smtpmail-retries
    auth-sources
    send-mail-function)
  "Variables whose values at scheduling time are used when sending.
The background Emacs doesn't load your init file, so anything your
`message-send-mail-function' reads must be listed here."
  :type '(repeat variable))

(defcustom mu4e-send-later-maildir "/scheduled"
  "Maildir, relative to mu's root, where mu4e shows scheduled mail.
It holds a copy of each queued message, dated when it is due, so a
mu4e bookmark on it lists what is scheduled.  Make sure your mail
sync doesn't upload it."
  :type 'string)

;;;; Errors

(define-error 'mu4e-send-later-error "mu4e-send-later")
(define-error 'mu4e-send-later-backend-error
              "Couldn't arm the send-later wake-up" 'mu4e-send-later-error)
(define-error 'mu4e-send-later-send-error
              "Sending a scheduled message failed" 'mu4e-send-later-error)

;;;; Queue

(defconst mu4e-send-later--format 1
  "Version of the on-disk format of queued items.")

(defun mu4e-send-later--dir (&rest parts)
  "The queue directory, or PARTS joined under it."
  (let ((dir (file-name-as-directory (expand-file-name mu4e-send-later-directory))))
    (if parts (expand-file-name (string-join parts "/") dir) dir)))

(defun mu4e-send-later--make-queue-dir ()
  "Create the queue directory, readable only by you.
An existing one is made private too, as older versions didn't."
  (let ((dir (mu4e-send-later--dir)))
    (with-file-modes #o700
      (make-directory dir t))
    (set-file-modes dir #o700)))

(defun mu4e-send-later--write-data (file data)
  "Atomically replace FILE with the printed representation of DATA."
  (let ((tmp (concat file ".tmp"))
        (print-length nil)
        (print-level nil)
        (print-escape-newlines t)
        (coding-system-for-write 'utf-8-unix))
    (with-file-modes #o700
      (with-temp-file tmp
        (prin1 data (current-buffer))
        (insert "\n")))
    (rename-file tmp file t)))

(defun mu4e-send-later--read-data (file)
  "Read the Lisp data stored in FILE."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (read (current-buffer))))

(defun mu4e-send-later--item-dir (id)
  "Directory of queued item ID."
  (mu4e-send-later--dir id))

(defun mu4e-send-later--meta (id)
  "The metadata plist of queued item ID.
Signal `file-missing' if it has gone, `mu4e-send-later-error' if it
can't be read."
  (let* ((file (expand-file-name "meta.eld" (mu4e-send-later--item-dir id)))
         (meta (condition-case err
                   (mu4e-send-later--read-data file)
                 (file-missing (signal (car err) (cdr err)))
                 (error (signal 'mu4e-send-later-error
                                (list "Unreadable metadata" file (error-message-string err)))))))
    (unless (and (plistp meta) (integerp (plist-get meta :due)))
      (signal 'mu4e-send-later-error (list "Unreadable metadata" file)))
    meta))

(defun mu4e-send-later--checked-meta (id &optional report)
  "The metadata of item ID, or nil if it can't be read.
With REPORT, log and notify that it can't; either way the caller skips
it, so one bad item doesn't hold up the others."
  (condition-case err
      (mu4e-send-later--meta id)
    (mu4e-send-later-error
     (when report
       (mu4e-send-later--notify
        "Scheduled mail unreadable"
        (format "%s is left in the queue, not sent: %s. See M-x mu4e-send-later-list."
                id (error-message-string err))
        t))
     nil)))

(defun mu4e-send-later--set-meta (id meta)
  "Store META as the metadata of queued item ID."
  (mu4e-send-later--write-data
   (expand-file-name "meta.eld" (mu4e-send-later--item-dir id)) meta))

(defun mu4e-send-later--ids ()
  "IDs of every queued item, soonest first."
  (let ((dir (mu4e-send-later--dir)))
    (when (file-directory-p dir)
      (sort (cl-remove-if-not
             (lambda (name)
               (file-exists-p (expand-file-name "meta.eld" (expand-file-name name dir))))
             (directory-files dir nil "\\`[0-9]+-[0-9a-f]+\\'"))
            (lambda (a b) (< (string-to-number a) (string-to-number b)))))))

(defun mu4e-send-later--wake-time (meta)
  "When the item described by META next wants to be sent, or nil if never."
  (when (eq (plist-get meta :state) 'pending)
    (or (plist-get meta :next-attempt) (plist-get meta :due))))

(defconst mu4e-send-later--lock-stale-after 900
  "Seconds after which a lock whose owner can't be asked is broken.")

(defconst mu4e-send-later--pid-reuse-margin 60
  "Seconds a lock's owner may seem to have started after taking it.
A process that started later than that is a newer one, reusing the
PID of the owner, which is gone.  The margin allows for the clock
the start time is worked out from not agreeing with file times.")

(defun mu4e-send-later--lock-dir ()
  "The directory whose existence is the queue lock."
  (mu4e-send-later--dir ".lock"))

(defun mu4e-send-later--lock-owner ()
  "Contents of the lock's owner file, or nil if there is none."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents (expand-file-name "owner" (mu4e-send-later--lock-dir)))
      (string-trim (buffer-string)))))

(defun mu4e-send-later--lock-stale-p (owner)
  "Non-nil if the lock, held by OWNER, was left behind by a dead sender.
An owner on this host is asked directly: the lock is stale as soon as
that process is gone, or is a newer one that reused its PID, and never
while it runs.  Otherwise the lock must be old."
  (let* ((mtime (file-attribute-modification-time
                 (file-attributes (mu4e-send-later--lock-dir))))
         (old (and mtime (> (float-time (time-since mtime))
                            mu4e-send-later--lock-stale-after))))
    (pcase (and mtime owner (split-string owner " "))
      ((and `(,pid ,(pred (equal (system-name))) . ,_)
            ;; Unless processes can't be seen here at all.
            (guard (process-attributes (emacs-pid))))
       (let ((attributes (process-attributes (string-to-number pid))))
         (or (null attributes)
             (let ((start (alist-get 'start attributes)))
               (and start
                    (time-less-p (time-add mtime mu4e-send-later--pid-reuse-margin)
                                 start))))))
      ;; An owner on another host, or none written, as by 0.2.
      (_ old))))

(defun mu4e-send-later--touch-lock ()
  "Show the lock is still in use, so it isn't taken for stale."
  (ignore-errors (set-file-times (mu4e-send-later--lock-dir))))

(defun mu4e-send-later--call-with-lock (fn)
  "Call FN holding the queue lock."
  (let* ((lock (mu4e-send-later--lock-dir))
         (token (format "%d %s %06x" (emacs-pid) (system-name) (random #xffffff)))
         ;; A background sender can wait out a long send; you shouldn't.
         (deadline (+ (float-time) (if noninteractive 60 5))))
    (mu4e-send-later--make-queue-dir)
    (while (condition-case nil
               (progn (make-directory lock) nil)
             (file-already-exists t))
      ;; A sender that died mid-flush leaves its lock behind.
      (let ((owner (mu4e-send-later--lock-owner)))
        (when (and (mu4e-send-later--lock-stale-p owner)
                   ;; Unless someone else broke it and took it meanwhile.
                   (equal owner (mu4e-send-later--lock-owner)))
          (ignore-errors (delete-directory lock t))))
      (when (> (float-time) deadline)
        (if noninteractive
            (signal 'mu4e-send-later-error
                    (list "The queue is locked by another sender" lock))
          (user-error "A send is in progress; try again in a moment")))
      (sleep-for 0.2))
    (condition-case err
        (write-region (concat token "\n") nil (expand-file-name "owner" lock) nil 'silent)
      (error (ignore-errors (delete-directory lock t))
             (signal (car err) (cdr err))))
    (unwind-protect (funcall fn)
      ;; If ours was broken as stale, the lock there now is someone else's.
      (when (equal (mu4e-send-later--lock-owner) token)
        (ignore-errors (delete-directory lock t))))))

(defmacro mu4e-send-later--with-lock (&rest body)
  "Run BODY holding the queue lock."
  (declare (indent 0) (debug t))
  `(mu4e-send-later--call-with-lock (lambda () ,@body)))

(defun mu4e-send-later--log (format-string &rest args)
  "Append a line built from FORMAT-STRING and ARGS to the queue's log."
  (let ((line (apply #'format format-string args)))
    (ignore-errors
      (let ((coding-system-for-write 'utf-8-unix))
        (with-file-modes #o700
          (write-region (format "%s %s\n" (format-time-string "%F %T") line)
                        nil (mu4e-send-later--dir "log") t 'silent))))
    (when noninteractive (message "mu4e-send-later: %s" line))))

;;;; Notifications

(defun mu4e-send-later--notify (title body &optional urgent)
  "Show a desktop notification with TITLE and BODY; URGENT if non-nil.
Also logs it, so it isn't lost where no notification daemon runs."
  (mu4e-send-later--log "%s: %s" title body)
  (condition-case nil
      (if (eq system-type 'darwin)
          (call-process "osascript" nil nil nil "-e"
                        (format "display notification %S with title %S" body title))
        (require 'notifications)
        (notifications-notify :title title :body body
                              :app-name "mu4e-send-later"
                              :urgency (if urgent 'critical 'normal)))
    (error nil)))

;;;; Running programs

(defun mu4e-send-later--call (program &rest args)
  "Run PROGRAM with ARGS; return its output, or signal if it fails."
  (let ((exe (executable-find program)))
    (unless exe
      (signal 'mu4e-send-later-backend-error (list (format "`%s' not found" program))))
    (with-temp-buffer
      (let ((status (apply #'call-process exe nil t nil args)))
        (unless (eql status 0)
          (signal 'mu4e-send-later-backend-error
                  (list (format "`%s %s' exited with %s" program (string-join args " ") status)
                        (string-trim (buffer-string)))))
        (buffer-string)))))

(defun mu4e-send-later--succeeds-p (program &rest args)
  "Non-nil if PROGRAM exists and exits 0 when run with ARGS."
  (when-let* ((exe (executable-find program)))
    (eql 0 (apply #'call-process exe nil nil nil args))))

(defun mu4e-send-later--emacs ()
  "The Emacs executable to send with; signal if it doesn't exist."
  (let ((emacs (or mu4e-send-later-emacs-program
                   (expand-file-name invocation-name invocation-directory))))
    (unless (file-executable-p emacs)
      (signal 'mu4e-send-later-backend-error
              (list "The Emacs that would send the mail doesn't exist" emacs
                    "set `mu4e-send-later-emacs-program'")))
    emacs))

(defun mu4e-send-later--library-dir ()
  "Directory this library was loaded from."
  (file-name-directory
   (or (locate-library "mu4e-send-later")
       (signal 'mu4e-send-later-error '("Can't find mu4e-send-later on `load-path'")))))

(defun mu4e-send-later--command (function &rest args)
  "Command line running FUNCTION with ARGS in a background Emacs."
  (append (list (mu4e-send-later--emacs) "--batch" "-Q"
                "-L" (mu4e-send-later--library-dir)
                "-l" "mu4e-send-later"
                "-f" (symbol-name function)
                (mu4e-send-later--dir))
          args))

;;;; Backends

(defvar mu4e-send-later--emacs-timer nil
  "Timer used by the `emacs' backend.")

(defvar mu4e-send-later--emacs-timer-time nil
  "Unix time `mu4e-send-later--emacs-timer' fires at.")

(defun mu4e-send-later--systemd-available-p ()
  "Non-nil if a systemd user manager is reachable."
  (and (eq system-type 'gnu/linux)
       (executable-find "systemd-run")
       (mu4e-send-later--succeeds-p "systemctl" "--user" "show-environment")))

(defun mu4e-send-later--launchd-available-p ()
  "Non-nil if launchd can be used."
  (and (eq system-type 'darwin) (executable-find "launchctl")))

(defun mu4e-send-later--backend ()
  "The backend to use, resolving `auto'."
  (pcase mu4e-send-later-backend
    ('auto (cond ((mu4e-send-later--systemd-available-p) 'systemd)
                 ((mu4e-send-later--launchd-available-p) 'launchd)
                 (t 'emacs)))
    ('systemd (unless (mu4e-send-later--systemd-available-p)
                (signal 'mu4e-send-later-backend-error
                        '("`mu4e-send-later-backend' is systemd, but no systemd user manager is reachable")))
              'systemd)
    ('launchd (unless (mu4e-send-later--launchd-available-p)
                (signal 'mu4e-send-later-backend-error
                        '("`mu4e-send-later-backend' is launchd, which needs macOS")))
              'launchd)
    ('emacs 'emacs)
    (other (signal 'mu4e-send-later-error
                   (list "Unknown `mu4e-send-later-backend'" other)))))

(cl-defgeneric mu4e-send-later--backend-arm (backend time)
  "Make BACKEND run the queue at TIME, a Unix time in seconds.")
(cl-defgeneric mu4e-send-later--backend-disarm (backend)
  "Cancel every wake-up BACKEND has pending.")
(cl-defgeneric mu4e-send-later--backend-armed-p (backend time)
  "Non-nil if BACKEND will run the queue at TIME.")
(cl-defgeneric mu4e-send-later--backend-run (backend command)
  "Run COMMAND synchronously the way BACKEND would; return its output.")

(defun mu4e-send-later--queue-tag ()
  "Short hash of the queue directory, naming the wake-ups that serve it.
Disarming then only touches this queue's, not those of another queue,
such as the one the integration test uses."
  (substring (secure-hash 'sha1 (mu4e-send-later--dir)) 0 8))

(defun mu4e-send-later--systemd-unit (time)
  "Name of the systemd units that fire at TIME."
  (format "mu4e-send-later-%s-%d" (mu4e-send-later--queue-tag) time))

;; A fresh unit name per wake-up: re-arming happens from inside the
;; service the previous timer started, which can't be replaced while
;; it runs.  Stopping that timer is safe; it doesn't stop the service.
(cl-defmethod mu4e-send-later--backend-arm ((_ (eql systemd)) time)
  "Wake up to run the queue at TIME, with a systemd user timer."
  (apply #'mu4e-send-later--call "systemd-run" "--user" "--quiet" "--collect"
         (concat "--unit=" (mu4e-send-later--systemd-unit time))
         (format "--on-calendar=@%d" time)
         "--timer-property=AccuracySec=1s"
         "--description=Send mail scheduled with mu4e-send-later"
         "--"
         (mu4e-send-later--command 'mu4e-send-later-batch-flush)))

(cl-defmethod mu4e-send-later--backend-disarm ((_ (eql systemd)))
  "Cancel every pending systemd user timer wake-up."
  (mu4e-send-later--call "systemctl" "--user" "stop"
                         (format "mu4e-send-later-%s-*.timer" (mu4e-send-later--queue-tag))))

(cl-defmethod mu4e-send-later--backend-armed-p ((_ (eql systemd)) time)
  "Non-nil if a systemd user timer wake-up is set for TIME."
  (mu4e-send-later--succeeds-p
   "systemctl" "--user" "is-active" "--quiet"
   (concat (mu4e-send-later--systemd-unit time) ".timer")))

;; Run the preflight as a user service too, so it sees the service
;; manager's environment rather than Emacs's.
(cl-defmethod mu4e-send-later--backend-run ((_ (eql systemd)) command)
  "Run COMMAND as a transient user service and return its output."
  (apply #'mu4e-send-later--call "systemd-run" "--user" "--quiet" "--collect"
         "--wait" "--pipe" "--" command))

(defconst mu4e-send-later--launchd-prefix "com.github.jotham-lec.mu4e-send-later"
  "Prefix of the launchd labels this package creates.")

(defun mu4e-send-later--launchd-label (time)
  "Label of the LaunchAgent that fires at TIME."
  (format "%s.%s.%d" mu4e-send-later--launchd-prefix (mu4e-send-later--queue-tag) time))

(defun mu4e-send-later--launchd-agents-dir ()
  "Directory holding the user's LaunchAgents."
  (expand-file-name "~/Library/LaunchAgents/"))

(defun mu4e-send-later--launchd-plist-file (label)
  "Where the LaunchAgent LABEL lives."
  (expand-file-name (concat label ".plist") (mu4e-send-later--launchd-agents-dir)))

(defun mu4e-send-later--launchd-domain ()
  "The launchd domain of the logged-in user."
  (format "gui/%d" (user-uid)))

(defun mu4e-send-later--plist-xml (label command &optional time)
  "LaunchAgent plist LABEL running COMMAND, at TIME if given, else at login."
  (let ((esc (lambda (s) (replace-regexp-in-string
                          "[&<>]" (lambda (c) (pcase c ("&" "&amp;") ("<" "&lt;") (_ "&gt;")))
                          s t t))))
    (concat
     "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
     "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
     "<plist version=\"1.0\">\n<dict>\n"
     "  <key>Label</key><string>" (funcall esc label) "</string>\n"
     "  <key>ProgramArguments</key>\n  <array>\n"
     (mapconcat (lambda (arg) (concat "    <string>" (funcall esc arg) "</string>\n")) command "")
     "  </array>\n"
     (if time
         ;; launchd has minute resolution and no year, so round up to the
         ;; next whole minute; the job disarms itself after running.
         (let ((d (decode-time (seconds-to-time (* 60 (ceiling time 60))))))
           (format (concat "  <key>StartCalendarInterval</key>\n  <dict>\n"
                           "    <key>Month</key><integer>%d</integer>\n"
                           "    <key>Day</key><integer>%d</integer>\n"
                           "    <key>Hour</key><integer>%d</integer>\n"
                           "    <key>Minute</key><integer>%d</integer>\n"
                           "  </dict>\n")
                   (decoded-time-month d) (decoded-time-day d)
                   (decoded-time-hour d) (decoded-time-minute d)))
       "  <key>RunAtLoad</key><true/>\n")
     "  <key>StandardErrorPath</key><string>"
     (funcall esc (mu4e-send-later--dir "launchd.log")) "</string>\n"
     "</dict>\n</plist>\n")))

(defun mu4e-send-later--launchd-load (label xml)
  "Write LaunchAgent LABEL with contents XML and load it."
  (let ((file (mu4e-send-later--launchd-plist-file label)))
    (make-directory (file-name-directory file) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region xml nil file nil 'silent))
    ;; As in disarming, booting out the job running us would kill us.
    (unless (equal label (getenv "XPC_SERVICE_NAME"))
      (ignore-errors
        (mu4e-send-later--call "launchctl" "bootout"
                               (concat (mu4e-send-later--launchd-domain) "/" label))))
    (mu4e-send-later--call "launchctl" "bootstrap" (mu4e-send-later--launchd-domain) file)))

(cl-defmethod mu4e-send-later--backend-arm ((_ (eql launchd)) time)
  "Wake up to run the queue at TIME, with a launchd job."
  (let ((label (mu4e-send-later--launchd-label time)))
    (mu4e-send-later--launchd-load
     label (mu4e-send-later--plist-xml
            label (mu4e-send-later--command 'mu4e-send-later-batch-flush) time))))

;; Booting out the job that is running us would kill us, so the current
;; one (launchd names it in XPC_SERVICE_NAME) only loses its plist.
(cl-defmethod mu4e-send-later--backend-disarm ((_ (eql launchd)))
  "Cancel every pending launchd job wake-up."
  (let ((self (getenv "XPC_SERVICE_NAME"))
        (dir (mu4e-send-later--launchd-agents-dir)))
    (dolist (file (and (file-directory-p dir)
                       (directory-files dir t (concat "\\`" (regexp-quote mu4e-send-later--launchd-prefix)
                                                      "\\." (mu4e-send-later--queue-tag)
                                                      "\\.[0-9]+\\.plist\\'"))))
      (let ((label (file-name-base file)))
        (unless (equal label self)
          (ignore-errors
            (mu4e-send-later--call "launchctl" "bootout"
                                   (concat (mu4e-send-later--launchd-domain) "/" label))))
        (delete-file file)))))

(cl-defmethod mu4e-send-later--backend-armed-p ((_ (eql launchd)) time)
  "Non-nil if a launchd job wake-up is set for TIME."
  (mu4e-send-later--succeeds-p
   "launchctl" "print" (concat (mu4e-send-later--launchd-domain) "/"
                               (mu4e-send-later--launchd-label time))))

(cl-defmethod mu4e-send-later--backend-run ((_ (eql launchd)) command)
  "Run COMMAND directly and return its output."
  (apply #'mu4e-send-later--call command))

(cl-defmethod mu4e-send-later--backend-arm ((_ (eql emacs)) time)
  "Wake up to run the queue at TIME, with a Emacs timer."
  (setq mu4e-send-later--emacs-timer
        (run-at-time (seconds-to-time time) nil #'mu4e-send-later--flush-async)
        mu4e-send-later--emacs-timer-time time))

(cl-defmethod mu4e-send-later--backend-disarm ((_ (eql emacs)))
  "Cancel every pending Emacs timer wake-up."
  (when (timerp mu4e-send-later--emacs-timer)
    (cancel-timer mu4e-send-later--emacs-timer))
  (setq mu4e-send-later--emacs-timer nil
        mu4e-send-later--emacs-timer-time nil))

(cl-defmethod mu4e-send-later--backend-armed-p ((_ (eql emacs)) time)
  "Non-nil if a Emacs timer wake-up is set for TIME."
  (and (timerp mu4e-send-later--emacs-timer)
       (memq mu4e-send-later--emacs-timer timer-list)
       (eql time mu4e-send-later--emacs-timer-time)))

(cl-defmethod mu4e-send-later--backend-run ((_ (eql emacs)) command)
  "Run COMMAND directly and return its output."
  (apply #'mu4e-send-later--call command))

;;;; Arming

(defun mu4e-send-later--write-config (backend)
  "Record the settings the background sender needs, for BACKEND."
  (mu4e-send-later--write-data
   (mu4e-send-later--dir "config.eld")
   (list :backend backend
         :retry-delays mu4e-send-later-retry-delays
         :emacs-program mu4e-send-later-emacs-program)))

(defun mu4e-send-later--next-wake ()
  "Unix time at which the queue next needs running, or nil."
  (let ((times (delq nil (mapcar (lambda (id)
                                   (mu4e-send-later--wake-time
                                    (mu4e-send-later--checked-meta id)))
                                 (mu4e-send-later--ids)))))
    (when times
      ;; A calendar timer set in the past never fires.
      (max (apply #'min times) (+ 2 (floor (float-time)))))))

(defun mu4e-send-later--arm ()
  "Point the wake-up at the next message due and check it took.
Return that time, or nil if nothing is pending."
  (let ((backend (mu4e-send-later--backend))
        (next (mu4e-send-later--next-wake)))
    (mu4e-send-later--write-config backend)
    (mu4e-send-later--backend-disarm backend)
    (when next
      (mu4e-send-later--backend-arm backend next)
      (unless (mu4e-send-later--backend-armed-p backend next)
        (signal 'mu4e-send-later-backend-error
                (list (format "The %s wake-up for %s wasn't there after arming it"
                              backend (format-time-string "%F %T" next))))))
    next))

;;;; Capturing a message

(defvar mu4e-send-later--preflight-ok nil
  "Preflight checks that passed this session, to avoid repeating them.")

(defvar mu4e-send-later--draft nil
  "The draft being scheduled, as the user wrote it, for `--enqueue'.
A plist of :text, :mode and :file, the file it was saved as.")

(defun mu4e-send-later--capture-draft ()
  "The current draft as the user wrote it, before sending renders it."
  (list :text (save-restriction
                (widen)
                (buffer-substring-no-properties (point-min) (point-max)))
        :mode major-mode
        :file buffer-file-name))

(defun mu4e-send-later--readable-p (value)
  "Non-nil if VALUE survives being printed and read back."
  (condition-case nil
      (equal value (car (read-from-string (prin1-to-string value))))
    (error nil)))

(defun mu4e-send-later--snapshot ()
  "Alist of `mu4e-send-later-variables' as they are now."
  (let (vars)
    (dolist (var mu4e-send-later-variables (nreverse vars))
      (when (boundp var)
        (let ((value (symbol-value var)))
          (when (and (eq var 'sendmail-program) (stringp value))
            (setq value (or (executable-find value)
                            (signal 'mu4e-send-later-error
                                    (list "`sendmail-program' not found" value)))))
          (unless (mu4e-send-later--readable-p value)
            (signal 'mu4e-send-later-error
                    (list (format "Can't store `%s' for the background sender" var) value)))
          (push (cons var value) vars))))))

(defun mu4e-send-later--header (name)
  "Decoded value of header NAME in the current message buffer, or \"\"."
  (save-restriction
    (message-narrow-to-headers-or-head)
    (let ((value (message-fetch-field name)))
      (if value (rfc2047-decode-string value) ""))))

(defun mu4e-send-later--effective-send-function (send-function)
  "The function SEND-FUNCTION sends with once `send-mail-function' is read.
Resolves message.el's default the way it resolves itself."
  (require 'sendmail)
  (if (eq send-function 'message--default-send-mail-function)
      (message-default-send-mail-function)
    send-function))

(defun mu4e-send-later--send-function-problem (send-function)
  "Why SEND-FUNCTION can't send from a background Emacs, or nil if it can.
SEND-FUNCTION is resolved with `mu4e-send-later--effective-send-function'."
  (when (or (eq send-function 'sendmail-query-once)
            (and (eq send-function 'message-use-send-mail-function)
                 (eq send-mail-function 'sendmail-query-once)))
    "`send-mail-function' is `sendmail-query-once', which asks how to send and so can't send in the background; set `send-mail-function' (e.g. to `smtpmail-send-it' or `sendmail-send-it')"))

(defun mu4e-send-later--preflight (backend send-function vars)
  "Check the background sender can send with SEND-FUNCTION and VARS on BACKEND."
  (let ((key (list backend (mu4e-send-later--emacs) send-function
                   (alist-get 'sendmail-program vars)
                   (alist-get 'send-mail-function vars))))
    (unless (member key mu4e-send-later--preflight-ok)
      (let ((output (condition-case err
                        (mu4e-send-later--backend-run
                         backend
                         (mu4e-send-later--command
                          'mu4e-send-later-batch-preflight
                          (symbol-name send-function)
                          (or (alist-get 'sendmail-program vars) "")
                          (format "%s" (or (alist-get 'send-mail-function vars) ""))))
                      (mu4e-send-later-error
                       (signal 'mu4e-send-later-backend-error
                               (list "The background sender failed its preflight check"
                                     (error-message-string err)))))))
        (unless (string-match-p "^mu4e-send-later: preflight ok$" output)
          (signal 'mu4e-send-later-backend-error
                  (list "The background sender failed its preflight check" output))))
      (push key mu4e-send-later--preflight-ok))))

(defun mu4e-send-later--enqueue (time send-function)
  "Queue the message in the current buffer for TIME, sent with SEND-FUNCTION.
Called where `message-send-mail-function' would be.  Return the new ID."
  (let* ((backend (mu4e-send-later--backend))
         (vars (mu4e-send-later--snapshot))
         (id (format "%d-%06x" time (random #xffffff)))
         (tmp (mu4e-send-later--dir (concat ".tmp-" id)))
         (meta (list :format mu4e-send-later--format
                     :due time
                     :created (floor (float-time))
                     :state 'pending
                     :attempts 0
                     :send-function send-function
                     :separator mail-header-separator
                     :variables vars
                     :from (mu4e-send-later--header "From")
                     :to (mu4e-send-later--header "To")
                     :subject (mu4e-send-later--header "Subject")
                     :draft-mode (plist-get mu4e-send-later--draft :mode)
                     :draft-file (plist-get mu4e-send-later--draft :file))))
    (mu4e-send-later--preflight backend send-function vars)
    (mu4e-send-later--with-lock
      (with-file-modes #o700
        (make-directory tmp t)
        (save-restriction
          (widen)
          (let ((coding-system-for-write
                 (if enable-multibyte-characters 'utf-8-unix 'no-conversion)))
            (write-region nil nil (expand-file-name "message" tmp) nil 'silent)))
        (when mu4e-send-later--draft
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (plist-get mu4e-send-later--draft :text) nil
                          (expand-file-name "draft" tmp) nil 'silent))))
      (mu4e-send-later--write-data (expand-file-name "meta.eld" tmp) meta)
      ;; The rename is what makes the item visible to a sender.
      (rename-file tmp (mu4e-send-later--item-dir id))
      ;; If the wake-up can't be armed, take the message back out so the
      ;; error aborts the send and the draft stays open.
      (condition-case err
          (mu4e-send-later--arm)
        (error
         (delete-directory (mu4e-send-later--item-dir id) t)
         (ignore-errors (mu4e-send-later--arm))
         (signal (car err) (cdr err)))))
    (mu4e-send-later--log "queued %s for %s: %s" id
                          (format-time-string "%F %T" time) (plist-get meta :subject))
    id))

(defun mu4e-send-later--read-time ()
  "Ask when to send, confirming what the answer was read as."
  (require 'org)
  (let ((time (floor (float-time (org-read-date
                                  t t nil "Send at (e.g. +2h, 16:30, +1d 8:30, mon 14:00): ")))))
    (when (<= time (float-time))
      (user-error "%s has already passed" (format-time-string "%a %e %b %H:%M" time)))
    ;; org-read-date reads "+30m" as months and "tomorrow 9am" as today.
    (unless (y-or-n-p (format-time-string "Send on %a %e %b %Y at %H:%M? " time))
      (user-error "Not scheduled"))
    time))

(defun mu4e-send-later--check-draft ()
  "Signal unless the current buffer is a draft `message-send' can send."
  ;; org-msg's mode derives from `org-mode', yet sends via `message-send'.
  (unless (derived-mode-p 'message-mode 'org-msg-edit-mode)
    (user-error "Not in a message buffer")))

;;;###autoload
(defun mu4e-send-later (time)
  "Send the current draft at TIME instead of now.
TIME is a Unix time in seconds; interactively it is read with
`org-read-date' and confirmed."
  (interactive (progn
                 (mu4e-send-later--check-draft)
                 (list (mu4e-send-later--read-time))))
  (mu4e-send-later--check-draft)
  (let ((send-function message-send-mail-function)
        (mu4e-send-later--draft (mu4e-send-later--capture-draft))
        (id nil))
    (unless (and (symbolp send-function) (fboundp send-function))
      (signal 'mu4e-send-later-error
              (list "`message-send-mail-function' must name a function" send-function)))
    (setq send-function (mu4e-send-later--effective-send-function send-function))
    (when-let* ((problem (mu4e-send-later--send-function-problem send-function)))
      (user-error "Can't schedule: %s" problem))
    ;; message.el sends a message with this header itself, straight away.
    (unless (string-empty-p (mu4e-send-later--header "X-Message-SMTP-Method"))
      (user-error "Scheduling doesn't support X-Message-SMTP-Method yet; remove the header to schedule this message"))
    (when (and (derived-mode-p 'org-msg-edit-mode) (fboundp 'org-msg-sanity-check))
      (org-msg-sanity-check))
    (let ((message-send-mail-function
           (lambda () (setq id (mu4e-send-later--enqueue time send-function))))
          ;; Split sends would queue each part separately.
          (message-send-mail-partially-limit nil)
          ;; Otherwise it adds X-Message-SMTP-Method, which sends now.
          (message-server-alist nil))
      (condition-case err
          (message-send-and-exit)
        (t
         ;; Sending renders the draft, adding headers, and org-msg turns
         ;; it into MML; put back what the user wrote, to try again.
         (let ((text (plist-get mu4e-send-later--draft :text)))
           (save-restriction
             (widen)
             (unless (equal text (buffer-string))
               (erase-buffer)
               (insert text)
               (goto-char (point-min)))))
         (signal (car err) (cdr err)))))
    (unless id
      (signal 'mu4e-send-later-error
              '("The message was sent without passing through the scheduler; check it was not sent now")))
    (mu4e-send-later--report-errors #'mu4e-send-later--mu4e-sync)
    (unless mu4e-send-later-mode
      (display-warning 'mu4e-send-later
                       "`mu4e-send-later-mode' is off, so mail that falls due while Emacs and the scheduler are down won't be sent when Emacs next starts"))
    (message "Scheduled for %s%s" (format-time-string "%a %e %b %H:%M" time)
             (if (eq (mu4e-send-later--backend) 'emacs)
                 " (only sent while Emacs is running)" ""))
    id))

;;;; Sending

(defun mu4e-send-later--restamp-date (separator &optional time)
  "Set the Date header of the message in this buffer to TIME, or now.
SEPARATOR ends the headers."
  (goto-char (point-min))
  (unless (re-search-forward (concat "^" (regexp-quote separator) "$") nil t)
    (signal 'mu4e-send-later-send-error '("Queued message has no header separator")))
  (save-restriction
    (narrow-to-region (point-min) (match-beginning 0))
    (goto-char (point-min))
    (when (re-search-forward "^Date:.*\\(?:\n[ \t].*\\)*" nil t)
      (replace-match (concat "Date: " (message-make-date time)) t t))))

(defun mu4e-send-later--send (id)
  "Send queued item ID now, signalling if that fails."
  (let* ((meta (mu4e-send-later--meta id))
         (send-function (plist-get meta :send-function))
         (vars (plist-get meta :variables)))
    (require 'sendmail)
    (require 'smtpmail nil t)
    (unless (fboundp send-function)
      (signal 'mu4e-send-later-send-error
              (list (format "`%s' isn't defined in the background Emacs" send-function))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally (expand-file-name "message" (mu4e-send-later--item-dir id)))
      (cl-progv (mapcar #'car vars) (mapcar #'cdr vars)
        (let ((mail-header-separator (plist-get meta :separator))
              ;; Otherwise sendmail is told to mail errors back rather
              ;; than report them, and a failure would look like success.
              (message-interactive t))
          (mu4e-send-later--restamp-date mail-header-separator)
          (funcall send-function))))))

(defun mu4e-send-later--record-failure (id meta err)
  "Record that sending item ID, described by META, failed with ERR.
Schedule a retry, or once they are used up, mark it failed."
  (let* ((attempts (1+ (plist-get meta :attempts)))
         (delay (nth (1- attempts) mu4e-send-later-retry-delays))
         (reason (error-message-string err))
         (subject (plist-get meta :subject)))
    (setq meta (plist-put meta :attempts attempts))
    (setq meta (plist-put meta :last-error reason))
    (if delay
        (setq meta (plist-put meta :next-attempt (+ (floor (float-time)) delay)))
      (setq meta (plist-put meta :state 'failed)))
    (mu4e-send-later--set-meta id meta)
    (cond ((not delay)
           (mu4e-send-later--notify
            "Scheduled mail NOT sent"
            (format "%s: gave up after %d attempts (%s). See M-x mu4e-send-later-list."
                    subject attempts reason)
            t))
          ((= attempts 1)
           (mu4e-send-later--notify
            "Scheduled mail not sent yet"
            (format "%s: %s. Retrying." subject reason) t))
          (t (mu4e-send-later--log "retry %d of %s failed: %s" attempts id reason)))))

(defun mu4e-send-later--attempt (id)
  "Try to send item ID; return non-nil on success."
  (let* ((meta (mu4e-send-later--meta id))
         (sent (condition-case err
                   (progn
                     ;; Should we die mid-send, the next flush sees this
                     ;; and doesn't send it again: at most once, loudly.
                     (mu4e-send-later--set-meta
                      id (plist-put (copy-sequence meta) :state 'sending))
                     (mu4e-send-later--send id)
                     t)
                 (error
                  (let ((reason (error-message-string err)))
                    (if (string-prefix-p "Sending...failed to " reason)
                        ;; sendmail exited 0, so it took the message, but
                        ;; it printed something, which message.el and
                        ;; sendmail.el call failing.  Retrying would send
                        ;; the message again.
                        (progn
                          (mu4e-send-later--notify
                           "Scheduled mail sent, with a warning"
                           (format "%s: sendmail said: %s" (plist-get meta :subject)
                                   (string-remove-prefix "Sending...failed to " reason)))
                          t)
                      (mu4e-send-later--record-failure id meta err)
                      nil))))))
    (when sent
      (mu4e-send-later--log "sent %s: %s" id (plist-get meta :subject))
      ;; A failed cleanup mustn't count as a failed send, which would be
      ;; retried.  Left marked `sending', the item is reported, not resent.
      (condition-case err
          (delete-directory (mu4e-send-later--item-dir id) t)
        (error
         (mu4e-send-later--notify
          "Scheduled mail sent, but still queued"
          (format "%s was sent, but couldn't be taken out of the queue: %s"
                  (plist-get meta :subject) (error-message-string err)))))
      t)))

(defconst mu4e-send-later--interrupted-error
  "Interrupted while sending: it may have been sent, please check before sending it again"
  "Last error of an item a sender stopped in the middle of sending.")

(defun mu4e-send-later--mark-interrupted (id meta)
  "Mark item ID, described by META and left `sending', as failed, and say so."
  (mu4e-send-later--set-meta
   id (thread-first meta
                    (plist-put :state 'failed)
                    (plist-put :last-error mu4e-send-later--interrupted-error)))
  (mu4e-send-later--notify
   "Scheduled mail may have been sent"
   (format "%s: %s. See M-x mu4e-send-later-list."
           (plist-get meta :subject) mu4e-send-later--interrupted-error)
   t))

(defun mu4e-send-later--flush ()
  "Send every due message, then re-arm.  Return the number that failed."
  (let ((failed 0))
    (mu4e-send-later--with-lock
      (dolist (id (mu4e-send-later--ids))
        (mu4e-send-later--touch-lock)
        (let* ((meta (mu4e-send-later--checked-meta id t))
               (wake (mu4e-send-later--wake-time meta)))
          (cond ((not meta)
                 (cl-incf failed))
                ((eq (plist-get meta :state) 'sending)
                 (mu4e-send-later--mark-interrupted id meta)
                 (cl-incf failed))
                ((and wake (<= wake (float-time)))
                 (unless (mu4e-send-later--attempt id)
                   (cl-incf failed))))))
      ;; The emacs backend's timer lives in the interactive Emacs, which
      ;; re-arms when this process exits.
      (unless (and noninteractive (eq (mu4e-send-later--backend) 'emacs))
        (mu4e-send-later--arm)))
    failed))

(defun mu4e-send-later--batch-setup ()
  "Adopt the queue directory and settings given on the command line."
  (setq mu4e-send-later-directory (file-name-as-directory (pop command-line-args-left)))
  (let ((config (ignore-errors (mu4e-send-later--read-data
                                (mu4e-send-later--dir "config.eld")))))
    (when config
      (setq mu4e-send-later-backend (plist-get config :backend)
            mu4e-send-later-retry-delays (plist-get config :retry-delays)
            mu4e-send-later-emacs-program (plist-get config :emacs-program)))))

(defun mu4e-send-later-batch-flush ()
  "Send due mail from a background Emacs, as the scheduler does."
  (unless noninteractive
    (error "`mu4e-send-later-batch-flush' is for Emacs in batch mode"))
  (mu4e-send-later--batch-setup)
  (let ((status (condition-case err
                    (if (zerop (mu4e-send-later--flush)) 0 1)
                  (error
                   (mu4e-send-later--notify
                    "Scheduled mail: sender broken"
                    (format "%s. Open Emacs and run M-x mu4e-send-later-list."
                            (error-message-string err))
                    t)
                   2))))
    (kill-emacs status)))

(defun mu4e-send-later-batch-preflight ()
  "Check a background Emacs could send; run by `mu4e-send-later'."
  (mu4e-send-later--batch-setup)
  (require 'sendmail)
  (require 'smtpmail nil t)
  (let* ((send-function (intern (pop command-line-args-left)))
         (program (pop command-line-args-left))
         (send-mail-function-name (pop command-line-args-left))
         (send-mail-function (if (member send-mail-function-name '(nil ""))
                                 send-mail-function
                               (intern send-mail-function-name)))
         (problem (mu4e-send-later--send-function-problem
                   (mu4e-send-later--effective-send-function send-function))))
    (unless (fboundp send-function)
      (message "mu4e-send-later: `%s' isn't defined without your init file" send-function)
      (kill-emacs 1))
    (when problem
      (message "mu4e-send-later: %s" problem)
      (kill-emacs 1))
    (unless (or (string-empty-p program) (file-executable-p program))
      (message "mu4e-send-later: %s isn't executable" program)
      (kill-emacs 1))
    (unless (and (ignore-errors (mu4e-send-later--make-queue-dir) t)
                 (file-writable-p (mu4e-send-later--dir)))
      (message "mu4e-send-later: can't write %s" (mu4e-send-later--dir))
      (kill-emacs 1))
    (princ "mu4e-send-later: preflight ok\n")
    (kill-emacs 0)))

(defun mu4e-send-later--flush-async (&optional on-exit)
  "Send due mail in a background Emacs without blocking this one.
Call ON-EXIT with the exit status when it finishes."
  (mu4e-send-later--make-queue-dir)
  (let* ((buffer (generate-new-buffer " *mu4e-send-later*"))
         ;; In the queue, where it is private, and where the one left by
         ;; a sender that outlived us can be found.
         (out (make-temp-file (mu4e-send-later--dir "flush-") nil ".out"))
         ;; nohup, and output to a file rather than to us, let the send
         ;; outlive this Emacs, which hangs up on its children as it
         ;; exits.  With no stdin, a send function that prompts fails
         ;; instead of waiting forever.
         (command (append (list "sh" "-c"
                                "out=$1; shift; exec nohup \"$@\" </dev/null >\"$out\" 2>&1"
                                "sh" out)
                          (mu4e-send-later--command 'mu4e-send-later-batch-flush))))
    (make-process
     :name "mu4e-send-later" :buffer buffer :command command :noquery t
     :connection-type 'pipe
     :sentinel
     (lambda (proc _event)
       (unless (process-live-p proc)
         (let ((status (process-exit-status proc))
               (output (concat (with-temp-buffer
                                 (ignore-errors (insert-file-contents out))
                                 (buffer-string))
                               ;; Only from sh, if it couldn't start the rest.
                               (with-current-buffer buffer (buffer-string)))))
           (ignore-errors (delete-file out))
           (kill-buffer buffer)
           (unless (zerop status)
             (display-warning
              'mu4e-send-later
              (format "Sending scheduled mail failed (exit %d):\n%s\nSee M-x mu4e-send-later-list."
                      status (string-trim output))
              :error))
           (when (eq (mu4e-send-later--backend) 'emacs)
             (mu4e-send-later--report-errors
              (lambda () (mu4e-send-later--with-lock (mu4e-send-later--arm)))))
           (mu4e-send-later--changed)
           (when on-exit (funcall on-exit status))))))))

;;;; Startup check

(defun mu4e-send-later--report-errors (fn)
  "Call FN, turning any error into a visible warning."
  (condition-case err
      (funcall fn)
    (error (display-warning 'mu4e-send-later (error-message-string err) :error))))

;;;###autoload
(defun mu4e-send-later-check ()
  "Send overdue mail, re-arm the wake-up, and warn about failed messages."
  (interactive)
  (let (overdue failed)
    (dolist (id (mu4e-send-later--ids))
      (let ((meta (mu4e-send-later--checked-meta id t)))
        (pcase (plist-get meta :state)
          ('nil)
          ('failed (push meta failed))
          ;; Only a flush, under the lock, can tell it was interrupted.
          ('sending (push meta overdue))
          (_ (when (<= (mu4e-send-later--wake-time meta) (float-time))
               (push meta overdue))))))
    (when failed
      (display-warning
       'mu4e-send-later
       (format "%d scheduled message(s) failed to send and are waiting in M-x mu4e-send-later-list:\n%s"
               (length failed)
               (mapconcat (lambda (m) (format "  %s — %s" (plist-get m :subject)
                                              (plist-get m :last-error)))
                          failed "\n"))
       :error))
    (mu4e-send-later--report-errors
     (lambda ()
       (if overdue
           (progn
             (message "mu4e-send-later: sending %d overdue message(s)" (length overdue))
             (mu4e-send-later--flush-async))
         (mu4e-send-later--with-lock (mu4e-send-later--arm)))))
    (mu4e-send-later--check-login-job)))

;;;###autoload
(define-minor-mode mu4e-send-later-mode
  "Send scheduled mail that fell due while Emacs wasn't running.
When enabled, and at each Emacs start while it stays enabled,
overdue mail is sent, the wake-up is re-armed after a reboot, and
failed messages are reported."
  :global t
  :group 'mu4e-send-later
  (mu4e-send-later--unwatch)
  (dolist (hook '(mu4e-main-rendered-hook mu4e-index-updated-hook))
    (remove-hook hook #'mu4e-send-later--mu4e-sync-safely))
  (remove-hook 'after-init-hook #'mu4e-send-later-check)
  (when mu4e-send-later--sync-timer
    (cancel-timer mu4e-send-later--sync-timer)
    (setq mu4e-send-later--sync-timer nil))
  (when mu4e-send-later-mode
    (dolist (hook '(mu4e-main-rendered-hook mu4e-index-updated-hook))
      (add-hook hook #'mu4e-send-later--mu4e-sync-safely))
    (mu4e-send-later--watch)
    (if after-init-time
        (mu4e-send-later-check)
      (add-hook 'after-init-hook #'mu4e-send-later-check))))

;;;; Login job

(defconst mu4e-send-later--systemd-login-unit "mu4e-send-later-login.service"
  "User unit that sends overdue mail at login.")

(defun mu4e-send-later--systemd-login-file ()
  "Path of the login unit file."
  (expand-file-name (concat "systemd/user/" mu4e-send-later--systemd-login-unit)
                    (or (getenv "XDG_CONFIG_HOME") "~/.config")))

(defun mu4e-send-later--systemd-quote (arg)
  "Quote ARG for a systemd ExecStart line."
  (concat "\"" (replace-regexp-in-string
                "[\"\\%$]" (lambda (c) (if (equal c "%") "%%" (if (equal c "$") "$$" (concat "\\" c))))
                arg t t)
          "\""))

(defun mu4e-send-later--login-command ()
  "Command line of the login job."
  (mu4e-send-later--command 'mu4e-send-later-batch-flush))

(defun mu4e-send-later--systemd-login-unit-text ()
  "Contents of the login unit file."
  (concat "[Unit]\n"
          "Description=Send mail that fell due while logged out (mu4e-send-later)\n\n"
          "[Service]\nType=oneshot\n"
          "ExecStart=" (mapconcat #'mu4e-send-later--systemd-quote
                                  (mu4e-send-later--login-command) " ")
          "\n\n[Install]\nWantedBy=default.target\n"))

;;;###autoload
(defun mu4e-send-later-install-login-job ()
  "Send overdue mail at login too, not just at the next Emacs start.
Re-run this if the Emacs executable moves, e.g. after an upgrade."
  (interactive)
  (pcase (mu4e-send-later--backend)
    ('systemd
     (let ((file (mu4e-send-later--systemd-login-file)))
       (make-directory (file-name-directory file) t)
       (let ((coding-system-for-write 'utf-8-unix))
         (write-region (mu4e-send-later--systemd-login-unit-text) nil file nil 'silent))
       (mu4e-send-later--call "systemctl" "--user" "daemon-reload")
       (mu4e-send-later--call "systemctl" "--user" "enable" mu4e-send-later--systemd-login-unit)
       (message "Installed %s" file)))
    ('launchd
     (let ((label (concat mu4e-send-later--launchd-prefix ".login")))
       (mu4e-send-later--launchd-load
        label (mu4e-send-later--plist-xml label (mu4e-send-later--login-command)))
       (message "Installed %s" (mu4e-send-later--launchd-plist-file label))))
    (_ (user-error "A login job needs systemd or launchd"))))

;;;###autoload
(defun mu4e-send-later-uninstall-login-job ()
  "Remove the job installed by `mu4e-send-later-install-login-job'."
  (interactive)
  (let ((unit (mu4e-send-later--systemd-login-file))
        (label (concat mu4e-send-later--launchd-prefix ".login")))
    (when (file-exists-p unit)
      (mu4e-send-later--call "systemctl" "--user" "disable" mu4e-send-later--systemd-login-unit)
      (delete-file unit)
      (mu4e-send-later--call "systemctl" "--user" "daemon-reload")
      (message "Removed %s" unit))
    (when (file-exists-p (mu4e-send-later--launchd-plist-file label))
      (ignore-errors
        (mu4e-send-later--call "launchctl" "bootout"
                               (concat (mu4e-send-later--launchd-domain) "/" label)))
      (delete-file (mu4e-send-later--launchd-plist-file label))
      (message "Removed %s" (mu4e-send-later--launchd-plist-file label)))))

(defun mu4e-send-later--check-login-job ()
  "Warn if an installed login job would run an Emacs or a library that moved.
The library moves when the package is upgraded."
  (dolist (file (list (mu4e-send-later--systemd-login-file)
                      (mu4e-send-later--launchd-plist-file
                       (concat mu4e-send-later--launchd-prefix ".login"))))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((emacs (when (re-search-forward
                            (concat "\\(?:ExecStart=\"\\|<key>ProgramArguments</key>"
                                    "\\s-*<array>\\s-*<string>\\)\\([^\"<]+\\)")
                            nil t)
                       (match-string 1)))
              (library (when (re-search-forward
                              "\\(?:\"-L\" \"\\|<string>-L</string>\\s-*<string>\\)\\([^\"<]+\\)"
                              nil t)
                         (match-string 1)))
              (current (ignore-errors (mu4e-send-later--library-dir))))
          (when (and emacs (not (file-executable-p emacs)))
            (display-warning
             'mu4e-send-later
             (format "The login job in %s runs %s, which no longer exists; run M-x mu4e-send-later-install-login-job again"
                     file emacs)
             :error))
          (when (and library current
                     (not (equal (file-name-as-directory library)
                                 (file-name-as-directory current))))
            (display-warning
             'mu4e-send-later
             (format "The login job in %s loads mu4e-send-later from %s, not from %s where it is now; run M-x mu4e-send-later-install-login-job again"
                     file library current)
             :error)))))))

;;;; mu4e

(defconst mu4e-send-later--mirror-regexp
  "\\`\\([0-9]+-[0-9a-f]+\\)\\.send-later:2,"
  "Matches the file name of a message in `mu4e-send-later-maildir'.")

(defvar mu4e-send-later--watch nil
  "The `file-notify' watch on the queue directory.")

(defvar mu4e-send-later--sync-timer nil
  "Timer that resyncs mu4e shortly after the queue changes.")

(defvar mu4e-send-later--mirrored (make-hash-table :test #'equal)
  "Due time each message in `mu4e-send-later-maildir' was written for, by ID.")

(defun mu4e-send-later--mirror-dir ()
  "The cur/ directory of `mu4e-send-later-maildir', or nil without mu4e."
  (when (and (fboundp 'mu4e-running-p) (mu4e-running-p))
    (expand-file-name (concat (string-trim mu4e-send-later-maildir "/" "/") "/cur")
                      (mu4e-root-maildir))))

(defun mu4e-send-later--mirror-id (file)
  "The queue ID that FILE, in `mu4e-send-later-maildir', stands for."
  (let ((name (file-name-nondirectory file)))
    (when (string-match mu4e-send-later--mirror-regexp name)
      (match-string 1 name))))

(defun mu4e-send-later--write-mirror (id file)
  "Write queued item ID to FILE as a plain message, dated when it is due."
  (let ((meta (mu4e-send-later--meta id))
        (tmp (expand-file-name (concat "../tmp/" (file-name-nondirectory file))
                               (file-name-directory file))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally
       (expand-file-name "message" (mu4e-send-later--item-dir id)))
      (mu4e-send-later--restamp-date (plist-get meta :separator) (plist-get meta :due))
      (goto-char (point-min))
      (re-search-forward (concat "^" (regexp-quote (plist-get meta :separator)) "$"))
      (replace-match "" t t)
      (let ((coding-system-for-write 'no-conversion))
        (write-region nil nil tmp nil 'silent)))
    (rename-file tmp file t)))

(defun mu4e-send-later--mu4e-sync ()
  "Make `mu4e-send-later-maildir' match the queue, and tell mu4e.
Does nothing unless mu4e is running."
  (when-let* ((dir (mu4e-send-later--mirror-dir)))
    (dolist (sub '("cur" "new" "tmp"))
      (make-directory (expand-file-name (concat "../" sub) dir) t))
    (let ((ids (mu4e-send-later--ids))
          (mirrors (make-hash-table :test #'equal)))
      ;; By ID, not by name: mu4e renames the file when its flags change.
      (dolist (file (directory-files dir t "\\.send-later:2,"))
        (let ((id (mu4e-send-later--mirror-id file)))
          (if (and (member id ids) (not (gethash id mirrors)))
              (puthash id file mirrors)
            ;; Gone from the queue, or a second copy.  mu deletes the file.
            (mu4e--server-remove file)
            (unless (member id ids)
              (remhash id mu4e-send-later--mirrored)))))
      (dolist (id ids)
        (let ((file (or (gethash id mirrors)
                        (expand-file-name (concat id ".send-later:2,S") dir))))
          ;; Sent between listing the queue and here, or unreadable.
          (ignore-error (file-missing mu4e-send-later-error)
            (let ((due (plist-get (mu4e-send-later--meta id) :due)))
              (unless (and (file-exists-p file)
                           (eql due (gethash id mu4e-send-later--mirrored)))
                (mu4e-send-later--write-mirror id file)
                (mu4e--server-add file)
                (puthash id due mu4e-send-later--mirrored)))))))))

(defun mu4e-send-later--mu4e-sync-safely ()
  "Like `mu4e-send-later--mu4e-sync', but only warn if it fails."
  (mu4e-send-later--report-errors #'mu4e-send-later--mu4e-sync))

(defun mu4e-send-later--changed ()
  "Show a change to the queue in the list and in mu4e."
  (when-let* ((buffer (get-buffer "*mu4e-send-later*")))
    (with-current-buffer buffer (revert-buffer)))
  (mu4e-send-later--mu4e-sync-safely))

(defun mu4e-send-later--queue-event (event)
  "Resync mu4e soon after EVENT, which may be an item coming or going."
  (when (cl-some (lambda (file)
                   (and (stringp file)
                        (string-match-p "\\`[0-9]+-[0-9a-f]+\\'" (file-name-nondirectory file))))
                 (cddr event))
    (when mu4e-send-later--sync-timer
      (cancel-timer mu4e-send-later--sync-timer))
    (setq mu4e-send-later--sync-timer
          (run-with-timer 1 nil #'mu4e-send-later--changed))))

(defun mu4e-send-later--watch ()
  "Resync mu4e on each change to the queue, as when a background send ends."
  (mu4e-send-later--make-queue-dir)
  (setq mu4e-send-later--watch
        (ignore-error file-notify-error
          (file-notify-add-watch (mu4e-send-later--dir) '(change)
                                 #'mu4e-send-later--queue-event))))

(defun mu4e-send-later--unwatch ()
  "Stop `mu4e-send-later--watch'."
  (when mu4e-send-later--watch
    (file-notify-rm-watch mu4e-send-later--watch)
    (setq mu4e-send-later--watch nil)))

(defun mu4e-send-later--open-draft (text meta)
  "Open TEXT, a draft queued with META, for editing."
  (let ((file (plist-get meta :draft-file)))
    (if (and file (fboundp 'mu4e--draft))
        ;; Back in the Drafts maildir it was scheduled from, opened the
        ;; way `mu4e-compose-edit' opens a draft.
        (let ((path (expand-file-name
                     (format "cur/%s.%06x.mu4e-send-later:2,DS"
                             (format-time-string "%s") (random #xffffff))
                     (file-name-directory (directory-file-name (file-name-directory file))))))
          (with-temp-buffer
            (insert text)
            (goto-char (point-min))
            (when (re-search-forward (concat "^" (regexp-quote mail-header-separator) "$") nil t)
              (replace-match "" t t))
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region nil nil path nil 'silent)))
          (when (mu4e-running-p)
            (mu4e--server-add path))
          (with-current-buffer
              (mu4e--draft 'edit
                           (lambda ()
                             (with-current-buffer (find-file-noselect path)
                               (mu4e--delimit-headers)
                               (current-buffer))))
            ;; org-msg only takes over drafts it would have started itself.
            (when (and (eq (plist-get meta :draft-mode) 'org-msg-edit-mode)
                       (fboundp 'org-msg-edit-mode)
                       (not (derived-mode-p 'org-msg-edit-mode)))
              (let ((address user-mail-address))
                (org-msg-edit-mode)
                (setq-local user-mail-address address))
              (set-buffer-modified-p nil))))
      (pop-to-buffer (generate-new-buffer "*unsent mail*"))
      (insert text)
      (funcall (or (plist-get meta :draft-mode) #'message-mode))
      (set-buffer-modified-p nil))))

;;;; Acting on scheduled mail

(defun mu4e-send-later--id-at-point ()
  "ID of the scheduled message at point, in the list or in mu4e."
  (let ((id (if (derived-mode-p 'mu4e-send-later-list-mode)
                (tabulated-list-get-id)
              (when-let* ((msg (and (fboundp 'mu4e-message-at-point)
                                    (mu4e-message-at-point t)))
                          (path (plist-get msg :path)))
                (mu4e-send-later--mirror-id path)))))
    (unless id
      (user-error "Not on a scheduled message"))
    (unless (file-exists-p (expand-file-name "meta.eld" (mu4e-send-later--item-dir id)))
      (mu4e-send-later--changed)
      (user-error "That message is no longer scheduled"))
    id))

(defun mu4e-send-later--unschedule (id)
  "Take ID out of the queue, keeping a copy in cancelled/."
  (mu4e-send-later--with-lock
    (make-directory (mu4e-send-later--dir "cancelled") t)
    (rename-file (mu4e-send-later--item-dir id) (mu4e-send-later--dir "cancelled" id))
    (mu4e-send-later--arm))
  (mu4e-send-later--log "cancelled %s" id)
  (mu4e-send-later--changed))

(defun mu4e-send-later--update (id fn)
  "Under the lock, replace ID's metadata with FN applied to it, then re-arm."
  (mu4e-send-later--with-lock
    (mu4e-send-later--set-meta
     id (funcall fn (condition-case nil
                        (mu4e-send-later--meta id)
                      (file-missing
                       (user-error "That message was already sent, or cancelled")))))
    (mu4e-send-later--arm))
  (mu4e-send-later--changed))

;;;###autoload
(defun mu4e-send-later-cancel ()
  "Unschedule the message at point, keeping a copy in cancelled/."
  (interactive)
  (let* ((id (mu4e-send-later--id-at-point))
         (meta (mu4e-send-later--checked-meta id)))
    (when (yes-or-no-p (format "Cancel \"%s\"? " (or (plist-get meta :subject) id)))
      (mu4e-send-later--unschedule id)
      (message "Cancelled; the message is in %s" (mu4e-send-later--dir "cancelled" id)))))

;;;###autoload
(defun mu4e-send-later-edit ()
  "Reopen the message at point as a draft, and unschedule it.
Schedule it again with `mu4e-send-later' once edited."
  (interactive)
  (let* ((id (mu4e-send-later--id-at-point))
         (meta (mu4e-send-later--meta id))
         (file (expand-file-name "draft" (mu4e-send-later--item-dir id))))
    (unless (file-exists-p file)
      (user-error "This message was scheduled without keeping its draft; cancel it and write it again"))
    (let ((text (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8-unix))
                    (insert-file-contents file))
                  (buffer-string))))
      ;; Draft first: if it can't be opened, nothing has changed.
      (mu4e-send-later--open-draft text meta)
      (condition-case err
          (mu4e-send-later--unschedule id)
        (error
         (error "Opened the draft, but the original is still scheduled (%s); cancel it before sending the draft"
                (error-message-string err))))
      (message "Unscheduled; the original is in %s.  Schedule the draft again when you're done"
               (mu4e-send-later--dir "cancelled" id)))))

;;;###autoload
(defun mu4e-send-later-send-now ()
  "Send the message at point now, retrying it if it had failed."
  (interactive)
  (mu4e-send-later--update (mu4e-send-later--id-at-point)
                           (lambda (meta)
                             (thread-first meta
                                           (plist-put :state 'pending)
                                           (plist-put :attempts 0)
                                           (plist-put :next-attempt nil)
                                           (plist-put :due (floor (float-time))))))
  (mu4e-send-later--flush-async)
  (message "Sending…"))

;;;###autoload
(defun mu4e-send-later-reschedule (time)
  "Move the message at point to TIME."
  (interactive (progn (mu4e-send-later--id-at-point)
                      (list (mu4e-send-later--read-time))))
  (mu4e-send-later--update (mu4e-send-later--id-at-point)
                           (lambda (meta)
                             (thread-first meta
                                           (plist-put :state 'pending)
                                           (plist-put :attempts 0)
                                           (plist-put :next-attempt nil)
                                           (plist-put :due time)))))

;;;; Queue listing

(defvar-keymap mu4e-send-later-list-mode-map
  :doc "Keymap for `mu4e-send-later-list-mode'."
  "RET" #'mu4e-send-later-list-view
  "e" #'mu4e-send-later-edit
  "c" #'mu4e-send-later-cancel
  "s" #'mu4e-send-later-send-now
  "r" #'mu4e-send-later-reschedule)

(define-derived-mode mu4e-send-later-list-mode tabulated-list-mode "Send-Later"
  "List of scheduled messages.
\\{mu4e-send-later-list-mode-map}"
  (setq tabulated-list-format [("Due" 17 t) ("State" 9 t) ("To" 28 t)
                               ("Subject" 40 t) ("Last error" 0 nil)]
        tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'mu4e-send-later--list-refresh nil t)
  (tabulated-list-init-header))

(defun mu4e-send-later--list-row (meta)
  "The list's columns for an item described by META, nil if unreadable."
  (if (not meta)
      (vector "" (propertize "unreadable" 'face 'error) "" ""
              "meta.eld can't be read; view or cancel it")
    (vector (format-time-string "%a %F %H:%M" (plist-get meta :due))
            (let ((state (symbol-name (plist-get meta :state))))
              (if (eq (plist-get meta :state) 'failed)
                  (propertize state 'face 'error)
                (if (> (plist-get meta :attempts) 0)
                    (format "retry %d" (plist-get meta :attempts))
                  state)))
            (or (plist-get meta :to) "")
            (or (plist-get meta :subject) "")
            (or (plist-get meta :last-error) ""))))

(defun mu4e-send-later--list-refresh ()
  "Reload the queue into the list buffer."
  (setq tabulated-list-entries
        (mapcar (lambda (id)
                  (list id (mu4e-send-later--list-row (mu4e-send-later--checked-meta id))))
                (mu4e-send-later--ids))))

;;;###autoload
(defun mu4e-send-later-list ()
  "Show the scheduled messages."
  (interactive)
  (with-current-buffer (get-buffer-create "*mu4e-send-later*")
    (mu4e-send-later-list-mode)
    (mu4e-send-later--list-refresh)
    (tabulated-list-print)
    (pop-to-buffer (current-buffer))))

(defun mu4e-send-later-list-view ()
  "Show the raw message at point."
  (interactive)
  (view-file (expand-file-name "message" (mu4e-send-later--item-dir (mu4e-send-later--id-at-point)))))

(provide 'mu4e-send-later)
;;; mu4e-send-later.el ends here
