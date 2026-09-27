;;; mu4e-send-later-test.el --- Tests for mu4e-send-later -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests run against a fake `test' backend and a fake send
;; function.  The `:integration' tests arm real systemd timers and only
;; run when MU4E_SEND_LATER_INTEGRATION=1.

;;; Code:

(require 'ert)
(require 'mu4e-send-later)

;;;; Fixtures

(defvar msl-test--armed nil "Times the fake backend was armed at, newest first.")
(defvar msl-test--arm-error nil "If non-nil, the fake backend fails to arm.")
(defvar msl-test--armed-p t "What the fake backend reports when verified.")
(defvar msl-test--sent nil "Messages given to `msl-test-send', newest first.")
(defvar msl-test--send-error nil "If non-nil, `msl-test-send' fails with this.")
(defvar msl-test--notified nil "Notifications shown, newest first.")
(defvar msl-test-setting nil "A setting the fake send function reads.")

(cl-defmethod mu4e-send-later--backend-arm ((_ (eql test)) time)
  (when msl-test--arm-error
    (signal 'mu4e-send-later-backend-error (list msl-test--arm-error)))
  (push time msl-test--armed))
(cl-defmethod mu4e-send-later--backend-disarm ((_ (eql test)))
  (setq msl-test--armed nil))
(cl-defmethod mu4e-send-later--backend-armed-p ((_ (eql test)) time)
  (and msl-test--armed-p (equal (car msl-test--armed) time)))

(defun msl-test-send ()
  "Fake `message-send-mail-function': record what it would send."
  (when msl-test--send-error
    (error "%s" msl-test--send-error))
  (push (list :text (buffer-string) :setting msl-test-setting
              :separator mail-header-separator)
        msl-test--sent))

(defmacro msl-test--with-queue (&rest body)
  "Run BODY with an empty queue, the fake backend and fake notifications."
  (declare (indent 0) (debug t))
  `(let* ((mu4e-send-later-directory (make-temp-file "msl-test-" t))
          (mu4e-send-later-variables '(msl-test-setting))
          (mu4e-send-later-retry-delays '(120 300))
          (mu4e-send-later-mode t)
          (msl-test--armed nil) (msl-test--arm-error nil) (msl-test--armed-p t)
          (msl-test--sent nil) (msl-test--send-error nil) (msl-test--notified nil))
     (cl-letf (((symbol-function 'mu4e-send-later--backend) (lambda () 'test))
               ((symbol-function 'mu4e-send-later--preflight) #'ignore)
               ((symbol-function 'mu4e-send-later--notify)
                (lambda (title body &optional urgent)
                  (push (list title body urgent) msl-test--notified))))
       (unwind-protect (progn ,@body)
         (delete-directory mu4e-send-later-directory t)))))

(defun msl-test--draft (&optional subject)
  "A message-mode draft buffer with SUBJECT."
  (let ((buffer (generate-new-buffer "*msl-draft*")))
    (with-current-buffer buffer
      (message-mode)
      (setq-local message-send-mail-function #'msl-test-send)
      (insert "From: Me <me@example.com>\n"
              "To: You <you@example.com>\n"
              "Bcc: hidden@example.com\n"
              "Subject: " (or subject "Café plans") "\n"
              mail-header-separator "\n"
              "Body with ünïcode.\nDate: this line is body, not a header\n"))
    buffer))

(defun msl-test--schedule (seconds &optional subject)
  "Schedule a fresh draft SECONDS from now; return (ID . BUFFER)."
  (let ((buffer (msl-test--draft subject))
        (message-interactive t))
    (with-current-buffer buffer
      (let ((id (mu4e-send-later (+ (floor (float-time)) seconds))))
        (cons id buffer)))))

(defun msl-test--make-due (id)
  "Make queued item ID due now."
  (let ((meta (mu4e-send-later--meta id)))
    (mu4e-send-later--set-meta id (plist-put meta :due (1- (floor (float-time)))))))

(defun msl-test--org-msg-draft (alternatives body)
  "An org-msg draft buffer sending ALTERNATIVES, with Org BODY.
Skips the test where org-msg isn't installed, except on CI."
  (unless (or (require 'org-msg nil t) (getenv "CI"))
    (ert-skip "org-msg is not installed; see `make deps'"))
  (require 'org-msg)
  (let ((buffer (generate-new-buffer "*msl-org-msg-draft*")))
    (with-current-buffer buffer
      (insert "From: Me <me@example.com>\n"
              "To: You <you@example.com>\n"
              "Subject: Org plans\n"
              mail-header-separator "\n"
              ":PROPERTIES:\n:reply-to: nil\n:attachment: nil\n"
              (format ":alternatives: %S\n" alternatives)
              ":END:\n\n" body "\n")
      (org-msg-edit-mode)
      (setq-local message-send-mail-function #'msl-test-send))
    buffer))

(defun msl-test--stored (id)
  "The stored message of queued item ID, as a string."
  (with-temp-buffer
    (insert-file-contents-literally
     (expand-file-name "message" (mu4e-send-later--item-dir id)))
    (buffer-string)))

;;;; Scheduling

(ert-deftest msl-test-schedule-queues-and-arms ()
  (msl-test--with-queue
    (let* ((msl-test-setting "captured")
           (result (msl-test--schedule 3600))
           (id (car result))
           (meta (mu4e-send-later--meta id)))
      (should (equal (mu4e-send-later--ids) (list id)))
      (should (eq (plist-get meta :state) 'pending))
      (should (eq (plist-get meta :send-function) 'msl-test-send))
      (should (equal (plist-get meta :subject) "Café plans"))
      (should (equal (plist-get meta :to) "You <you@example.com>"))
      (should (equal (plist-get meta :variables) '((msl-test-setting . "captured"))))
      (should (equal msl-test--armed (list (plist-get meta :due))))
      ;; Nothing actually went out, yet message-mode finished the send.
      (should-not msl-test--sent)
      (should (string-prefix-p "*sent" (buffer-name (cdr result))))
      (kill-buffer (cdr result))
      ;; The stored message is the rendered one: encoded headers, Date,
      ;; Message-ID, MIME-encoded body.
      (with-temp-buffer
        (insert-file-contents-literally
         (expand-file-name "message" (mu4e-send-later--item-dir id)))
        (dolist (header '("^Subject: =\\?" "^Date: " "^Message-ID: "
                          ;; Kept: sendmail -t delivers to Bcc and strips it.
                          "^Bcc: hidden@example.com"))
          (goto-char (point-min))
          (should (re-search-forward header nil t)))
        (goto-char (point-min))
        (should-not (search-forward "ünïcode" nil t))))))

(ert-deftest msl-test-schedule-org-msg-html-draft ()
  (msl-test--with-queue
    (let ((buffer (msl-test--org-msg-draft '(utf-8 html) "This is *bold*."))
          (mail-user-agent 'message-user-agent)
          (message-interactive t))
      (unwind-protect
          (let* ((id (with-current-buffer buffer
                       (mu4e-send-later (+ (floor (float-time)) 3600))))
                 (stored (msl-test--stored id)))
            (should (equal (mu4e-send-later--ids) (list id)))
            (should (equal (plist-get (mu4e-send-later--meta id) :subject) "Org plans"))
            (should-not msl-test--sent)
            ;; Stored as org-msg rendered it, not as the Org source.
            (should (string-match-p "multipart/alternative" stored))
            (should (string-match-p "text/html" stored))
            (should (string-match-p "<b>bold</b>" stored))
            (should-not (string-match-p ":PROPERTIES:" stored))
            ;; And sent as stored.
            (msl-test--make-due id)
            (should (zerop (mu4e-send-later--flush)))
            (should (string-match-p "<b>bold</b>" (plist-get (car msl-test--sent) :text))))
        (kill-buffer buffer)))))

(ert-deftest msl-test-schedule-org-msg-text-draft ()
  (msl-test--with-queue
    (let ((buffer (msl-test--org-msg-draft '(text) "Just words."))
          (mail-user-agent 'message-user-agent)
          (message-interactive t))
      (unwind-protect
          (let ((stored (msl-test--stored
                         (with-current-buffer buffer
                           (mu4e-send-later (+ (floor (float-time)) 3600))))))
            (should (string-match-p "Just words\\." stored))
            (should-not (string-match-p "text/html" stored))
            (should-not (string-match-p ":PROPERTIES:" stored)))
        (kill-buffer buffer)))))

(ert-deftest msl-test-org-msg-missing-attachment-aborts ()
  (msl-test--with-queue
    (let ((buffer (msl-test--org-msg-draft '(utf-8 html) "See the attached report."))
          (mail-user-agent 'message-user-agent)
          (message-interactive t))
      (unwind-protect
          (cl-letf (((symbol-function 'y-or-n-p) #'ignore))
            (with-current-buffer buffer
              (should (equal (should-error (mu4e-send-later (+ (floor (float-time)) 3600)))
                             '(error "Aborted"))))
            (should (buffer-live-p buffer))
            (should-not (mu4e-send-later--ids))
            (should-not msl-test--armed))
        (kill-buffer buffer)))))

(ert-deftest msl-test-non-draft-buffer-is-refused ()
  (msl-test--with-queue
    (with-temp-buffer
      (org-mode)
      (should-error (mu4e-send-later (+ (floor (float-time)) 3600))
                    :type 'user-error)
      (should-error (call-interactively #'mu4e-send-later) :type 'user-error))
    (should-not (mu4e-send-later--ids))))

(ert-deftest msl-test-arm-failure-keeps-draft-and-queue-empty ()
  (msl-test--with-queue
    (setq msl-test--arm-error "no scheduler")
    (let ((buffer (msl-test--draft)))
      (unwind-protect
          (with-current-buffer buffer
            (should-error (mu4e-send-later (+ (floor (float-time)) 3600))
                          :type 'mu4e-send-later-backend-error)
            (should (buffer-live-p buffer))
            (should-not (mu4e-send-later--ids)))
        (kill-buffer buffer)))))

(ert-deftest msl-test-unverified-arm-is-an-error ()
  (msl-test--with-queue
    (setq msl-test--armed-p nil)
    (let ((buffer (msl-test--draft)))
      (unwind-protect
          (with-current-buffer buffer
            (should-error (mu4e-send-later (+ (floor (float-time)) 3600))
                          :type 'mu4e-send-later-backend-error)
            (should (buffer-live-p buffer))
            (should-not (mu4e-send-later--ids)))
        (kill-buffer buffer)))))

(ert-deftest msl-test-unreadable-setting-is-an-error ()
  (msl-test--with-queue
    (let ((msl-test-setting (make-marker))
          (buffer (msl-test--draft)))
      (unwind-protect
          (with-current-buffer buffer
            (should-error (mu4e-send-later (+ (floor (float-time)) 3600))
                          :type 'mu4e-send-later-error)
            (should-not (mu4e-send-later--ids)))
        (kill-buffer buffer)))))

(ert-deftest msl-test-anonymous-send-function-is-an-error ()
  (msl-test--with-queue
    (let ((buffer (msl-test--draft)))
      (unwind-protect
          (with-current-buffer buffer
            (setq-local message-send-mail-function (lambda () nil))
            (should-error (mu4e-send-later (+ (floor (float-time)) 3600))
                          :type 'mu4e-send-later-error))
        (kill-buffer buffer)))))

(ert-deftest msl-test-sendmail-program-is-made-absolute ()
  (msl-test--with-queue
    (let ((mu4e-send-later-variables '(sendmail-program))
          (sendmail-program "sh"))
      (should (file-name-absolute-p
               (alist-get 'sendmail-program (mu4e-send-later--snapshot)))))
    (let ((mu4e-send-later-variables '(sendmail-program))
          (sendmail-program "no-such-sendmail-xyz"))
      (should-error (mu4e-send-later--snapshot) :type 'mu4e-send-later-error))))

;;;; Sending

(ert-deftest msl-test-flush-sends-due-with-captured-settings ()
  (msl-test--with-queue
    (let* ((id-due (car (let ((msl-test-setting "first")) (msl-test--schedule 3600 "Due"))))
           (id-later (car (msl-test--schedule 7200 "Later"))))
      (msl-test--make-due id-due)
      (let ((file (expand-file-name "message" (mu4e-send-later--item-dir id-due))))
        (with-temp-file file
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file)
          (goto-char (point-min))
          (re-search-forward "^Date: .*$")
          (replace-match "Date: Mon, 01 Jan 2024 00:00:00 +0000" t t)))
      (let ((msl-test-setting "changed since"))
        (should (zerop (mu4e-send-later--flush))))
      (should (equal (mu4e-send-later--ids) (list id-later)))
      (should (= (length msl-test--sent) 1))
      (let ((sent (car msl-test--sent)))
        (should (equal (plist-get sent :setting) "first"))
        (should (equal (plist-get sent :separator) mail-header-separator))
        (should (string-match-p "Subject: Due" (plist-get sent :text)))
        ;; Dated when it actually went out, not when it was scheduled.
        (should-not (string-match-p "2024" (plist-get sent :text))))
      ;; Re-armed for the one left.
      (should (equal msl-test--armed
                     (list (plist-get (mu4e-send-later--meta id-later) :due)))))))

(ert-deftest msl-test-flush-disarms-when-empty ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600))))
      (msl-test--make-due id)
      (mu4e-send-later--flush)
      (should-not (mu4e-send-later--ids))
      (should-not msl-test--armed))))

(ert-deftest msl-test-date-restamped-in-headers-only ()
  (with-temp-buffer
    (insert "From: a@b\nDate: Mon, 01 Jan 2024 00:00:00 +0000\n  (folded)\nSubject: x\n"
            "--sep--\nDate: body line\n")
    (mu4e-send-later--restamp-date "--sep--")
    (goto-char (point-min))
    (should-not (search-forward "2024" nil t))
    (should-not (search-forward "(folded)" nil t))
    (should (search-forward "Date: body line" nil t))
    (goto-char (point-min))
    (should (re-search-forward (concat "^Date: " (regexp-quote (substring (message-make-date) 0 11)))
                               nil t))))

(ert-deftest msl-test-missing-separator-fails-loudly ()
  (with-temp-buffer
    (insert "From: a@b\n\nbody\n")
    (should-error (mu4e-send-later--restamp-date "--sep--")
                  :type 'mu4e-send-later-send-error)))

(ert-deftest msl-test-failure-retries-then-gives-up ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600 "Flaky")))
          (msl-test--send-error "connection refused"))
      (msl-test--make-due id)
      ;; First failure: retry scheduled, one urgent notification.
      (should (= 1 (mu4e-send-later--flush)))
      (let ((meta (mu4e-send-later--meta id)))
        (should (eq (plist-get meta :state) 'pending))
        (should (= (plist-get meta :attempts) 1))
        (should (string-match-p "connection refused" (plist-get meta :last-error)))
        (should (<= (abs (- (plist-get meta :next-attempt) (+ (float-time) 120))) 2))
        (should (equal msl-test--armed (list (plist-get meta :next-attempt)))))
      (should (= (length msl-test--notified) 1))
      ;; Not due again yet: nothing happens.
      (should (zerop (mu4e-send-later--flush)))
      (should (= (plist-get (mu4e-send-later--meta id) :attempts) 1))
      ;; Second failure is quiet; the third exhausts the delays.
      (dotimes (_ 2)
        (let ((meta (mu4e-send-later--meta id)))
          (mu4e-send-later--set-meta id (plist-put meta :next-attempt 1)))
        (mu4e-send-later--flush))
      (let ((meta (mu4e-send-later--meta id)))
        (should (eq (plist-get meta :state) 'failed))
        (should (= (plist-get meta :attempts) 3)))
      (should (= (length msl-test--notified) 2))
      (should (string-match-p "NOT sent" (car (car msl-test--notified))))
      (should (nth 2 (car msl-test--notified)))
      ;; Failed mail is kept, and no longer wakes anything up.
      (should (equal (mu4e-send-later--ids) (list id)))
      (should-not msl-test--armed))))

(ert-deftest msl-test-undefined-send-function-fails ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600))))
      (msl-test--make-due id)
      (let ((meta (mu4e-send-later--meta id)))
        (mu4e-send-later--set-meta id (plist-put meta :send-function 'msl-no-such-fn)))
      (should (= 1 (mu4e-send-later--flush)))
      (should (string-match-p "msl-no-such-fn"
                              (plist-get (mu4e-send-later--meta id) :last-error))))))

;;;; Arming

(ert-deftest msl-test-next-wake-never-in-the-past ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600))))
      (msl-test--make-due id)
      (should (>= (mu4e-send-later--next-wake) (+ (floor (float-time)) 1))))))

(ert-deftest msl-test-lock-is-exclusive-and-stale-locks-break ()
  (msl-test--with-queue
    (let ((lock (mu4e-send-later--dir ".lock")))
      (make-directory lock t)
      ;; Fresh lock held by someone else: we wait, then give up loudly.
      (cl-letf (((symbol-function 'float-time)
                 (let ((calls 0)) (lambda (&rest _) (cl-incf calls 100)))))
        (should-error (mu4e-send-later--with-lock t) :type 'mu4e-send-later-error))
      ;; Stale lock: broken and taken.
      (set-file-times lock (time-subtract nil 3600))
      (should (eq 'ran (mu4e-send-later--with-lock 'ran)))
      (should-not (file-exists-p lock)))))

;;;; Startup check and listing

(ert-deftest msl-test-check-warns-about-failed-and-sends-overdue ()
  (msl-test--with-queue
    (let ((failed (car (msl-test--schedule 3600 "Broken")))
          (overdue (car (msl-test--schedule 3600 "Overdue")))
          (flushed nil) (warnings nil))
      (mu4e-send-later--set-meta failed (plist-put (plist-put (mu4e-send-later--meta failed)
                                                             :state 'failed)
                                                  :last-error "boom"))
      (msl-test--make-due overdue)
      (cl-letf (((symbol-function 'mu4e-send-later--flush-async)
                 (lambda (&rest _) (setq flushed t)))
                ((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (mu4e-send-later-check))
      (should flushed)
      (should (= (length warnings) 1))
      (should (string-match-p "Broken — boom" (car warnings))))))

(ert-deftest msl-test-list-shows-queue ()
  (msl-test--with-queue
    (msl-test--schedule 3600 "Listed")
    (mu4e-send-later-list)
    (unwind-protect
        (with-current-buffer "*mu4e-send-later*"
          (goto-char (point-min))
          (should (search-forward "Listed" nil t))
          (goto-char (point-min))
          (should (search-forward "pending" nil t)))
      (kill-buffer "*mu4e-send-later*"))))

;;;; Backend details

(ert-deftest msl-test-launchd-plist-rounds-up-and-escapes ()
  (let* ((time (+ (* 60 (ceiling (float-time) 60)) 3600 5))
         (xml (mu4e-send-later--plist-xml "a.b" '("/x/emacs" "a&b<c>") time))
         (d (decode-time (seconds-to-time (+ (- time 5) 60)))))
    (should (string-match-p "<string>a&amp;b&lt;c&gt;</string>" xml))
    (should (string-match-p (format "<key>Minute</key><integer>%d</integer>"
                                    (decoded-time-minute d))
                            xml))
    (should-not (string-match-p "RunAtLoad" xml))
    (should (string-match-p "RunAtLoad"
                            (mu4e-send-later--plist-xml "a.b" '("/x/emacs"))))))

(ert-deftest msl-test-systemd-quoting ()
  (should (equal (mu4e-send-later--systemd-quote "/a b/c\"d%e$f\\g")
                 "\"/a b/c\\\"d%%e$$f\\\\g\"")))

;;;; Integration

(ert-deftest msl-test-integration-systemd-end-to-end ()
  "Schedule through a real systemd timer and a fake sendmail."
  :tags '(:integration)
  (skip-unless (equal (getenv "MU4E_SEND_LATER_INTEGRATION") "1"))
  (skip-unless (mu4e-send-later--systemd-available-p))
  (let* ((dir (make-temp-file "msl-int-" t))
         (mu4e-send-later-directory (expand-file-name "queue/" dir))
         (mu4e-send-later-backend 'systemd)
         (mu4e-send-later-mode t)
         (sink (expand-file-name "sent" dir))
         (sendmail (expand-file-name "fake-sendmail" dir))
         (sendmail-program sendmail)
         (message-sendmail-extra-arguments '("--read-envelope-from"))
         (message-send-mail-function #'message-send-mail-with-sendmail)
         (message-interactive t))
    (unwind-protect
        (progn
          (with-temp-file sendmail
            (insert (format "#!/bin/sh\n{ echo \"ARGS: $*\"; cat; } > %s\n" sink)))
          (set-file-modes sendmail #o755)
          (let ((buffer (msl-test--draft "Integration")))
            (with-current-buffer buffer
              (setq-local message-send-mail-function #'message-send-mail-with-sendmail)
              (mu4e-send-later (+ (floor (float-time)) 3))))
          (should (= 1 (length (mu4e-send-later--ids))))
          (let ((deadline (+ (float-time) 30)))
            (while (and (not (file-exists-p sink)) (< (float-time) deadline))
              (sleep-for 0.5)))
          (should (file-exists-p sink))
          (sleep-for 1)
          (with-temp-buffer
            (insert-file-contents sink)
            (should (search-forward "--read-envelope-from" nil t))
            ;; -oem would have sendmail mail errors back instead of failing.
            (goto-char (point-min))
            (should-not (search-forward "-oem" nil t))
            (should (search-forward "Subject: Integration" nil t))
            (should-not (search-forward mail-header-separator nil t)))
          (should-not (mu4e-send-later--ids)))
      (ignore-errors (mu4e-send-later--backend-disarm 'systemd))
      (delete-directory dir t))))

(provide 'mu4e-send-later-test)
;;; mu4e-send-later-test.el ends here
