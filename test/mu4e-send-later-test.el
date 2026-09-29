;;; mu4e-send-later-test.el --- Tests for mu4e-send-later -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests run against a fake `test' backend and a fake send
;; function.  The `:integration' tests arm real systemd timers, or real
;; launchd jobs on macOS, and only run when
;; MU4E_SEND_LATER_INTEGRATION=1.  They use a queue of their own, and
;; the timers are named after the queue, so they don't touch the timers
;; of the queue you use.

;;; Code:

(require 'cus-edit)
(require 'ert)
(require 'mu4e-send-later)

(declare-function mu4e-root-maildir "ext:mu4e-server" ())
(declare-function org-msg-edit-mode "ext:org-msg" ())

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

;;;; Customization

(ert-deftest msl-test-defaults-match-their-types ()
  (let (checked mismatched)
    (mapatoms
     (lambda (symbol)
       (when (and (string-prefix-p "mu4e-send-later-" (symbol-name symbol))
                  (custom-variable-p symbol))
         (push symbol checked)
         (unless (widget-apply (widget-convert (get symbol 'custom-type))
                               :match (default-value symbol))
           (push symbol mismatched)))))
    (should checked)
    (should-not mismatched)))

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
        (set-buffer-multibyte nil)
        (insert-file-contents-literally
         (expand-file-name "message" (mu4e-send-later--item-dir id)))
        (dolist (header '("^Subject: =\\?" "^Date: " "^Message-ID: "
                          ;; Kept: sendmail -t delivers to Bcc and strips it.
                          "^Bcc: hidden@example.com"))
          (goto-char (point-min))
          (should (re-search-forward header nil t)))
        ;; Compared as bytes: the body is quoted-printable, not raw UTF-8.
        (goto-char (point-min))
        (should (search-forward "=C3=BCn=C3=AFcode" nil t))
        (goto-char (point-min))
        (should-not (search-forward (encode-coding-string "ünïcode" 'utf-8) nil t))))))

(ert-deftest msl-test-time-need-not-be-a-whole-number ()
  (msl-test--with-queue
    (let* ((time (+ (float-time) 3600.7))
           (buffer (msl-test--draft "Float"))
           (id (with-current-buffer buffer
                 (let ((message-interactive t))
                   (mu4e-send-later time)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (should (eql (plist-get (mu4e-send-later--meta id) :due) (floor time)))
      (should (equal msl-test--armed (list (floor time))))
      ;; Nor when rescheduling, or given as a Lisp timestamp.
      (msl-test--in-list "Float" (lambda () (mu4e-send-later-reschedule (+ time 60.5))))
      (should (eql (plist-get (mu4e-send-later--meta id) :due) (floor (+ time 60.5))))
      (msl-test--in-list "Float" (lambda () (mu4e-send-later-reschedule
                                             (time-convert (+ time 120) 'list))))
      (should (eql (plist-get (mu4e-send-later--meta id) :due) (floor (+ time 120)))))))

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

;; A failure while scheduling comes after message.el has added headers
;; and org-msg has turned the draft into MML.
(ert-deftest msl-test-failed-schedule-leaves-the-draft-as-written ()
  (msl-test--with-queue
    (let* ((buffer (msl-test--org-msg-draft '(utf-8 html) "This is *bold*."))
           (written (with-current-buffer buffer (buffer-string)))
           (mail-user-agent 'message-user-agent)
           (message-interactive t))
      (unwind-protect
          (with-current-buffer buffer
            (setq msl-test--arm-error "no scheduler")
            (should-error (mu4e-send-later (+ (floor (float-time)) 3600))
                          :type 'mu4e-send-later-backend-error)
            (should (equal (buffer-string) written))
            (should (derived-mode-p 'org-msg-edit-mode))
            ;; Scheduled again, it is the Org source that is kept to edit.
            (setq msl-test--arm-error nil)
            (let ((id (mu4e-send-later (+ (floor (float-time)) 3600))))
              (with-temp-buffer
                (insert-file-contents (expand-file-name "draft" (mu4e-send-later--item-dir id)))
                (should (equal (buffer-string) written)))
              (should (string-match-p "<b>bold</b>" (msl-test--stored id)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;; message.el goes on once it has handed the message over: Fcc, its
;; hooks, killing the draft, the exit actions.  A failure there, or C-g,
;; leaves the message scheduled, so it mustn't look as if it weren't.
(ert-deftest msl-test-failure-after-queuing-leaves-it-scheduled ()
  (msl-test--with-queue
    (let ((other (generate-new-buffer "*msl-other*"))
          (warnings nil))
      (unwind-protect
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (_type message &rest _) (push message warnings))))
            ;; mu4e's `message-sent-hook' fails.
            (let ((buffer (msl-test--draft "Hooked"))
                  (message-interactive t))
              (with-current-buffer buffer
                (add-hook 'message-sent-hook (lambda () (error "mu server gone")) nil t)
                (should (equal (mu4e-send-later (+ (floor (float-time)) 3600))
                               (car (mu4e-send-later--ids)))))
              (kill-buffer buffer))
            (should (string-match-p "mu server gone" (car warnings)))
            ;; C-g in an exit action, once the draft is killed and another
            ;; buffer is current.
            (with-current-buffer other (insert "Someone's work\n"))
            (let ((buffer (msl-test--draft "Quit"))
                  (message-interactive t))
              (switch-to-buffer other)
              (switch-to-buffer buffer)
              (setq-local message-kill-buffer-on-exit t)
              (setq-local message-exit-actions (list (lambda () (signal 'quit nil))))
              (should (mu4e-send-later (+ (floor (float-time)) 3600)))
              (should-not (buffer-live-p buffer)))
            (should (= (length (mu4e-send-later--ids)) 2))
            (should (equal (with-current-buffer other (buffer-string)) "Someone's work\n")))
        (kill-buffer other)))))

(ert-deftest msl-test-non-draft-buffer-is-refused ()
  (msl-test--with-queue
    (with-temp-buffer
      (org-mode)
      (should-error (mu4e-send-later (+ (floor (float-time)) 3600))
                    :type 'user-error)
      (should-error (call-interactively #'mu4e-send-later) :type 'user-error))
    (should-not (mu4e-send-later--ids))))

(ert-deftest msl-test-queue-is-private ()
  (msl-test--with-queue
    ;; A queue left world-readable by an older version, and a lax umask.
    (set-file-modes mu4e-send-later-directory #o755)
    (with-file-modes #o755
      (let* ((id (car (msl-test--schedule 3600)))
             (item (mu4e-send-later--item-dir id)))
        (dolist (file (list (mu4e-send-later--dir) item
                            (expand-file-name "message" item)
                            (expand-file-name "draft" item)
                            (expand-file-name "meta.eld" item)
                            (mu4e-send-later--dir "config.eld")
                            (mu4e-send-later--dir "log")))
          (should (zerop (logand (file-modes file) #o077))))))))

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

(ert-deftest msl-test-arm-failure-says-what-was-queued-is-unarmed ()
  (msl-test--with-queue
    (let ((earlier (car (msl-test--schedule 3600 "Earlier")))
          (buffer (msl-test--draft "Later")))
      (setq msl-test--arm-error "no scheduler")
      (unwind-protect
          (with-current-buffer buffer
            (should-error (mu4e-send-later (+ (floor (float-time)) 7200))
                          :type 'mu4e-send-later-backend-error))
        (kill-buffer buffer))
      (should (equal (mu4e-send-later--ids) (list earlier)))
      ;; Arming failed for it too, and you're told so, loudly.
      (should-not msl-test--armed)
      (should (= (length msl-test--notified) 1))
      (should (string-match-p "no scheduler" (nth 1 (car msl-test--notified))))
      (should (nth 2 (car msl-test--notified))))))

;; As when systemd-run hangs and you press C-g.
(ert-deftest msl-test-quit-while-arming-takes-the-message-back-out ()
  (msl-test--with-queue
    (let ((earlier (car (msl-test--schedule 3600 "Earlier")))
          (buffer (msl-test--draft "Later"))
          (quits 1))
      (unwind-protect
          (cl-letf* ((arm (symbol-function 'mu4e-send-later--backend-arm))
                     ((symbol-function 'mu4e-send-later--backend-arm)
                      (lambda (backend time)
                        (when (>= (cl-decf quits) 0)
                          (signal 'quit nil))
                        (funcall arm backend time))))
            (with-current-buffer buffer
              (should (equal (condition-case err
                                 (mu4e-send-later (+ (floor (float-time)) 7200))
                               (quit err))
                             '(quit)))))
        (kill-buffer buffer))
      ;; Not scheduled, as the draft left open says, and the rest re-armed.
      (should (equal (mu4e-send-later--ids) (list earlier)))
      (should (equal msl-test--armed (list (plist-get (mu4e-send-later--meta earlier) :due)))))))

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

(defun msl-test--default-variables ()
  "The standard value of `mu4e-send-later-variables'."
  (eval (car (get 'mu4e-send-later-variables 'standard-value)) t))

(ert-deftest msl-test-default-send-function-with-smtpmail-is-resolved ()
  (msl-test--with-queue
    (let ((mu4e-send-later-variables (msl-test--default-variables))
          (send-mail-function #'smtpmail-send-it)
          (buffer (msl-test--draft)))
      (unwind-protect
          (let* ((id (with-current-buffer buffer
                       (setq-local message-send-mail-function
                                   #'message--default-send-mail-function)
                       (mu4e-send-later (+ (floor (float-time)) 3600))))
                 (meta (mu4e-send-later--meta id)))
            ;; What message.el would call at send time, not its dispatcher.
            (should (eq (plist-get meta :send-function) 'message-use-send-mail-function))
            ;; Which reads `send-mail-function' again when it sends.
            (should (eq (alist-get 'send-mail-function (plist-get meta :variables))
                        'smtpmail-send-it)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest msl-test-send-mail-function-is-used-at-send-time ()
  (msl-test--with-queue
    (let* ((mu4e-send-later-variables '(send-mail-function msl-test-setting))
           (id (let ((send-mail-function #'msl-test-send)
                     (buffer (msl-test--draft)))
                 (with-current-buffer buffer
                   (setq-local message-send-mail-function
                               #'message--default-send-mail-function)
                   (mu4e-send-later (+ (floor (float-time)) 3600))))))
      (msl-test--make-due id)
      ;; As in `emacs -Q --batch', where nothing is configured.
      (let ((send-mail-function #'sendmail-query-once))
        (should (zerop (mu4e-send-later--flush))))
      (should (= (length msl-test--sent) 1)))))

(ert-deftest msl-test-unconfigured-send-mail-function-is-refused ()
  (msl-test--with-queue
    (dolist (setup '((message--default-send-mail-function . sendmail-query-once)
                     (message-use-send-mail-function . sendmail-query-once)
                     (sendmail-query-once . smtpmail-send-it)))
      (let ((send-mail-function (cdr setup))
            (buffer (msl-test--draft)))
        (unwind-protect
            (with-current-buffer buffer
              (setq-local message-send-mail-function (car setup))
              (should (string-match-p
                       "send-mail-function"
                       (cadr (should-error (mu4e-send-later (+ (floor (float-time)) 3600))
                                           :type 'user-error))))
              (should (buffer-live-p buffer)))
          (kill-buffer buffer))))
    (should-not (mu4e-send-later--ids))))

(ert-deftest msl-test-smtp-method-header-is-refused-before-sending ()
  (msl-test--with-queue
    (let ((buffer (msl-test--draft))
          (sent-now nil))
      (unwind-protect
          ;; The header makes message.el bypass `message-send-mail-function'.
          (cl-letf (((symbol-function 'message-send-mail-with-sendmail)
                     (lambda () (push 'sendmail sent-now))))
            (with-current-buffer buffer
              (goto-char (point-min))
              (insert "X-Message-SMTP-Method: sendmail\n")
              (should (string-match-p
                       "X-Message-SMTP-Method"
                       (cadr (should-error (mu4e-send-later (+ (floor (float-time)) 3600))
                                           :type 'user-error)))))
            (should (buffer-live-p buffer))
            (should-not sent-now)
            (should-not msl-test--sent)
            (should-not (mu4e-send-later--ids)))
        (kill-buffer buffer)))))

(ert-deftest msl-test-message-server-alist-is-not-applied ()
  (msl-test--with-queue
    (let ((message-server-alist '(("me@example.com" . "sendmail")))
          (sent-now nil))
      (cl-letf (((symbol-function 'message-send-mail-with-sendmail)
                 (lambda () (push 'sendmail sent-now))))
        (let ((id (car (msl-test--schedule 3600))))
          (should-not sent-now)
          (should (equal (mu4e-send-later--ids) (list id)))
          (should-not (string-match-p "X-Message-SMTP-Method" (msl-test--stored id))))))))

(ert-deftest msl-test-preflight-fails-on-an-unconfigured-send-function ()
  (msl-test--with-queue
    (dolist (send-function '("message--default-send-mail-function" "sendmail-query-once"))
      (should-error
       (mu4e-send-later--backend-run
        'emacs (mu4e-send-later--command 'mu4e-send-later-batch-preflight send-function ""))
       :type 'mu4e-send-later-backend-error))
    ;; The same function passes once told what `send-mail-function' is.
    (should (string-match-p
             "preflight ok"
             (mu4e-send-later--backend-run
              'emacs (mu4e-send-later--command 'mu4e-send-later-batch-preflight
                                               "message--default-send-mail-function" ""
                                               "smtpmail-send-it"))))))

;; As in a checkout that was updated but not recompiled.
(ert-deftest msl-test-background-emacs-loads-the-newer-source ()
  (let* ((dir (make-temp-file "msl-lib-" t))
         (source (expand-file-name "mu4e-send-later.el" dir))
         (real (with-temp-buffer
                 (insert-file-contents
                  (expand-file-name "mu4e-send-later.el" (mu4e-send-later--library-dir)))
                 (buffer-string))))
    (unwind-protect
        (progn
          ;; An old version, compiled, whose preflight says something else.
          (with-temp-file source
            (insert (string-replace "mu4e-send-later: preflight ok"
                                    "mu4e-send-later: preflight stale"
                                    real)))
          (require 'bytecomp)
          (let ((byte-compile-warnings nil))
            (should (byte-compile-file source)))
          (set-file-times (concat source "c") (time-subtract nil 60))
          (with-temp-file source (insert real))
          (cl-letf (((symbol-function 'mu4e-send-later--library-dir)
                     (lambda () (file-name-as-directory dir))))
            (let ((output (mu4e-send-later--backend-run
                           'emacs (mu4e-send-later--command
                                   'mu4e-send-later-batch-preflight
                                   "message-send-mail-with-sendmail" ""))))
              (should (string-match-p "preflight ok" output))
              (should-not (string-match-p "stale" output)))))
      (delete-directory dir t))))

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

(defun msl-test--fake-sendmail (dir script)
  "Write an executable sendmail to DIR running shell SCRIPT; return its path.
Each message it reads is appended to DIR/sent, followed by a line
\"DELIVERED\"."
  (let ((file (expand-file-name "sendmail" dir)))
    (with-temp-file file
      (insert "#!/bin/sh\n"
              (format "cat >> %s\necho DELIVERED >> %s\n"
                      (shell-quote-argument (expand-file-name "sent" dir))
                      (shell-quote-argument (expand-file-name "sent" dir)))
              script "\n"))
    (set-file-modes file #o755)
    file))

(defun msl-test--deliveries (dir)
  "How many messages the fake sendmail in DIR delivered."
  (let ((file (expand-file-name "sent" dir)))
    (if (file-exists-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (how-many "^DELIVERED$" (point-min) (point-max)))
      0)))

;; message.el and sendmail.el report any output from a sendmail that
;; exited 0 as "Sending...failed to"; the message went out all the same.
(ert-deftest msl-test-sendmail-warning-is-a-send-not-a-failure ()
  (msl-test--with-queue
    (let* ((dir (make-temp-file "msl-sendmail-" t))
           (mu4e-send-later-variables '(sendmail-program message-sendmail-f-is-evil))
           (sendmail-program (msl-test--fake-sendmail
                              dir "echo 'msmtp: TLS certificate expires soon' >&2\nexit 0"))
           (message-sendmail-f-is-evil t)
           (buffer (msl-test--draft "Warned")))
      (unwind-protect
          (let ((id (with-current-buffer buffer
                      (setq-local message-send-mail-function
                                  #'message-send-mail-with-sendmail)
                      (let ((message-interactive t))
                        (mu4e-send-later (+ (floor (float-time)) 3600))))))
            (msl-test--make-due id)
            (should (zerop (mu4e-send-later--flush)))
            ;; Nothing left to send again.
            (should-not (mu4e-send-later--ids))
            (dotimes (_ 2) (mu4e-send-later--flush))
            (should (= (msl-test--deliveries dir) 1))
            (should (= (length msl-test--notified) 1))
            (should (string-match-p "Warned: .*TLS certificate expires soon"
                                    (nth 1 (car msl-test--notified)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory dir t)))))

;; And a sendmail that fails is still retried.
(ert-deftest msl-test-sendmail-that-exits-non-zero-is-retried ()
  (msl-test--with-queue
    (let* ((dir (make-temp-file "msl-sendmail-" t))
           (mu4e-send-later-variables '(sendmail-program message-sendmail-f-is-evil))
           (sendmail-program (msl-test--fake-sendmail dir "echo 'no route' >&2\nexit 75"))
           (message-sendmail-f-is-evil t)
           (buffer (msl-test--draft "Refused")))
      (unwind-protect
          (let ((id (with-current-buffer buffer
                      (setq-local message-send-mail-function
                                  #'message-send-mail-with-sendmail)
                      (let ((message-interactive t))
                        (mu4e-send-later (+ (floor (float-time)) 3600))))))
            (msl-test--make-due id)
            (should (= 1 (mu4e-send-later--flush)))
            (let ((meta (mu4e-send-later--meta id)))
              (should (eq (plist-get meta :state) 'pending))
              (should (= (plist-get meta :attempts) 1))
              (should (string-match-p "exit value 75" (plist-get meta :last-error)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory dir t)))))

(ert-deftest msl-test-item-is-marked-sending-while-it-sends ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600)))
          (state nil))
      (msl-test--make-due id)
      (cl-letf* ((send (symbol-function 'mu4e-send-later--send))
                 ((symbol-function 'mu4e-send-later--send)
                  (lambda (id)
                    (setq state (plist-get (mu4e-send-later--meta id) :state))
                    (funcall send id))))
        (should (zerop (mu4e-send-later--flush))))
      (should (eq state 'sending)))))

(ert-deftest msl-test-item-left-sending-is-never-resent ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600 "Interrupted"))))
      (msl-test--make-due id)
      ;; As a sender that died mid-send leaves it.
      (mu4e-send-later--set-meta id (plist-put (mu4e-send-later--meta id) :state 'sending))
      (should (= 1 (mu4e-send-later--flush)))
      (should-not msl-test--sent)
      (let ((meta (mu4e-send-later--meta id)))
        (should (eq (plist-get meta :state) 'failed))
        (should (string-match-p "may have been sent" (plist-get meta :last-error))))
      (should (= (length msl-test--notified) 1))
      (should (string-match-p "may have been sent" (nth 1 (car msl-test--notified))))
      (should (nth 2 (car msl-test--notified)))
      ;; And stays put.
      (should (zerop (mu4e-send-later--flush)))
      (should-not msl-test--sent))))

(ert-deftest msl-test-failed-cleanup-is-not-a-failed-send ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600 "Sent once"))))
      (msl-test--make-due id)
      (cl-letf* ((delete (symbol-function 'delete-directory))
                 ((symbol-function 'delete-directory)
                  (lambda (dir &rest args)
                    (if (equal (directory-file-name dir)
                               (directory-file-name (mu4e-send-later--item-dir id)))
                        (signal 'file-error (list "Can't delete" dir))
                      (apply delete dir args)))))
        (should (zerop (mu4e-send-later--flush)))
        (should (= (length msl-test--sent) 1))
        (should (zerop (plist-get (mu4e-send-later--meta id) :attempts)))
        ;; Not sent a second time.
        (mu4e-send-later--flush)
        (should (= (length msl-test--sent) 1))
        (should (eq (plist-get (mu4e-send-later--meta id) :state) 'failed))))))

(ert-deftest msl-test-check-hands-an-interrupted-send-to-the-flush ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600)))
          (flushed nil))
      (mu4e-send-later--set-meta id (plist-put (mu4e-send-later--meta id) :state 'sending))
      (cl-letf (((symbol-function 'mu4e-send-later--flush-async)
                 (lambda (&rest _) (setq flushed t))))
        (mu4e-send-later-check))
      (should flushed))))

;; The background sender inherits no terminal and no pipe to read from:
;; a send function that asks for something fails rather than hangs.
(ert-deftest msl-test-background-send-that-prompts-fails-at-once ()
  (msl-test--with-queue
    (let* ((mu4e-send-later-variables '(send-mail-function))
           (send-mail-function '(lambda () (read-passwd "SMTP password: ")))
           ;; So the background Emacs can't pop up real notifications.
           (process-environment (cons "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent"
                                      process-environment))
           (buffer (msl-test--draft "Prompts"))
           (status nil))
      (unwind-protect
          (let ((id (with-current-buffer buffer
                      (setq-local message-send-mail-function
                                  #'message-use-send-mail-function)
                      (mu4e-send-later (+ (floor (float-time)) 3600)))))
            (msl-test--make-due id)
            ;; The background Emacs has no fake backend: it mustn't re-arm.
            (mu4e-send-later--write-config 'emacs)
            (mu4e-send-later--flush-async (lambda (s) (setq status s)))
            (with-timeout (30 (ert-fail "The background send hung"))
              (while (not status)
                (accept-process-output nil 0.1)))
            (should (= status 1))
            (let ((meta (mu4e-send-later--meta id)))
              (should (eq (plist-get meta :state) 'pending))
              (should (= (plist-get meta :attempts) 1))
              (should (string-match-p "stdin" (plist-get meta :last-error))))
            (should-not (file-exists-p (mu4e-send-later--lock-dir))))
        (dolist (process (process-list))
          (when (string-prefix-p "mu4e-send-later" (process-name process))
            (delete-process process)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;; Quitting Emacs while it sends in the background mustn't stop the send.
;; Emacs hangs up on its children as it exits, which kills a background
;; Emacs busy in Lisp, as smtpmail is.
(ert-deftest msl-test-background-send-outlives-its-emacs ()
  (msl-test--with-queue
    (let* ((dir (make-temp-file "msl-sendmail-" t))
           (mu4e-send-later-variables
            '(send-mail-function sendmail-program message-sendmail-f-is-evil))
           (send-mail-function '(lambda ()
                                  (sleep-for 2)
                                  (message-send-mail-with-sendmail)))
           (sendmail-program (msl-test--fake-sendmail dir ""))
           (message-sendmail-f-is-evil t)
           (process-environment (cons "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent"
                                      process-environment))
           (buffer (msl-test--draft "Outlives")))
      (unwind-protect
          (let ((id (with-current-buffer buffer
                      (setq-local message-send-mail-function
                                  #'message-use-send-mail-function)
                      (mu4e-send-later (+ (floor (float-time)) 3600)))))
            (msl-test--make-due id)
            (mu4e-send-later--write-config 'emacs)
            ;; An Emacs that starts a background send, then quits.
            (should (zerop (call-process
                            (expand-file-name invocation-name invocation-directory)
                            nil nil nil "-Q" "--batch"
                            "-L" (mu4e-send-later--library-dir) "-l" "mu4e-send-later"
                            "--eval"
                            (format "%S" `(progn
                                            (setq mu4e-send-later-directory
                                                  ,(mu4e-send-later--dir)
                                                  mu4e-send-later-backend 'emacs)
                                            (mu4e-send-later--flush-async)
                                            (sleep-for 1)
                                            (kill-emacs 0))))))
            (with-timeout (30 (ert-fail "The send didn't finish"))
              (while (member id (mu4e-send-later--ids))
                (sleep-for 0.2)))
            (should (= (msl-test--deliveries dir) 1))
            (should-not (file-exists-p (mu4e-send-later--lock-dir))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory dir t)))))

;; The output of a sender that outlived its Emacs is never read.
(ert-deftest msl-test-background-send-output-left-behind-is-cleaned-up ()
  (msl-test--with-queue
    (let ((old (mu4e-send-later--dir "flush-old.out"))
          (recent (mu4e-send-later--dir "flush-recent.out"))
          (status nil))
      (mu4e-send-later--make-queue-dir)
      (dolist (file (list old recent))
        (write-region "" nil file))
      (set-file-times old (time-subtract nil (* 2 86400)))
      (mu4e-send-later--write-config 'emacs)
      (mu4e-send-later--flush-async (lambda (s) (setq status s)))
      (with-timeout (30 (ert-fail "The background send hung"))
        (while (not status)
          (accept-process-output nil 0.1)))
      (should-not (file-exists-p old))
      ;; Its sender may still be running.
      (should (file-exists-p recent))
      ;; And ours was read and removed.
      (should (equal (directory-files (mu4e-send-later--dir) nil "\\`flush-")
                     '("flush-recent.out"))))))

(defun msl-test--corrupt (id &optional contents)
  "Replace the metadata of item ID with CONTENTS, a truncated plist by default."
  (with-temp-file (expand-file-name "meta.eld" (mu4e-send-later--item-dir id))
    (insert (or contents "(:format 1 :due 17"))))

(ert-deftest msl-test-corrupt-metadata-does-not-block-the-queue ()
  (msl-test--with-queue
    (let ((bad (car (msl-test--schedule 3600 "Bad")))
          (bad-too (car (msl-test--schedule 3600 "Also bad")))
          (good (car (msl-test--schedule 3600 "Good"))))
      (msl-test--make-due good)
      (msl-test--corrupt bad)
      (msl-test--corrupt bad-too "42")
      (should (= 2 (mu4e-send-later--flush)))
      (should (= (length msl-test--sent) 1))
      (should (string-match-p "Subject: Good" (plist-get (car msl-test--sent) :text)))
      ;; Kept for you to look at, and reported once each, loudly.
      (should (equal (mu4e-send-later--ids) (sort (list bad bad-too) #'string<)))
      (should (= (length msl-test--notified) 2))
      (dolist (id (list bad bad-too))
        (should (cl-some (lambda (n) (and (string-match-p id (nth 1 n)) (nth 2 n)))
                         msl-test--notified)))
      ;; The startup check and the list get past them too.
      (setq msl-test--notified nil)
      (cl-letf (((symbol-function 'mu4e-send-later--flush-async) #'ignore)
                ((symbol-function 'display-warning) #'ignore))
        (mu4e-send-later-check))
      (should msl-test--notified)
      (mu4e-send-later-list)
      (unwind-protect
          (with-current-buffer "*mu4e-send-later*"
            (goto-char (point-min))
            (should (search-forward "unreadable" nil t)))
        (kill-buffer "*mu4e-send-later*")))))

(ert-deftest msl-test-corrupt-metadata-does-not-stop-arming ()
  (msl-test--with-queue
    (let ((bad (car (msl-test--schedule 3600 "Bad")))
          (good (car (msl-test--schedule 7200 "Good"))))
      (msl-test--corrupt bad)
      (should (equal (mu4e-send-later--next-wake)
                     (plist-get (mu4e-send-later--meta good) :due))))))

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

(defconst msl-test--dead-pid 999999999
  "A PID no process has.")

(defun msl-test--hold-lock (pid host &optional age)
  "Make the queue lock look held by PID on HOST, taken AGE seconds ago."
  (let ((lock (mu4e-send-later--dir ".lock")))
    (make-directory lock t)
    (with-temp-file (expand-file-name "owner" lock)
      (insert (format "%d %s someone-else\n" pid host)))
    (when age
      (set-file-times lock (time-subtract nil age)))
    lock))

(defmacro msl-test--with-lock-deadline (&rest body)
  "Run BODY with the lock's wait deadline passing at once."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'float-time)
              (let ((calls 0)) (lambda (&rest _) (cl-incf calls 100)))))
     ,@body))

(ert-deftest msl-test-stale-lock-of-a-dead-owner-is-broken ()
  (msl-test--with-queue
    (let ((lock (msl-test--hold-lock msl-test--dead-pid (system-name) 3600)))
      (should (eq 'ran (mu4e-send-later--with-lock 'ran)))
      (should-not (file-exists-p lock)))))

;; Our own PID stands in for another live process on this host.
(defun msl-test--own-start ()
  "When this Emacs started."
  (alist-get 'start (process-attributes (emacs-pid))))

(ert-deftest msl-test-live-local-owners-lock-is-never-broken ()
  (msl-test--with-queue
    ;; Taken after we started, as by us: however old it looks, it stays.
    (let ((lock (msl-test--hold-lock (emacs-pid) (system-name)))
          (mu4e-send-later--lock-stale-after 0))
      (set-file-times lock (time-add (msl-test--own-start) 1))
      (sleep-for 0.01)
      (should-not (mu4e-send-later--lock-stale-p (mu4e-send-later--lock-owner)))
      (msl-test--with-lock-deadline
        (should-error (mu4e-send-later--with-lock t) :type 'mu4e-send-later-error))
      (should (file-exists-p (expand-file-name "owner" lock))))))

(ert-deftest msl-test-fresh-lock-of-a-dead-local-owner-is-broken ()
  (msl-test--with-queue
    (let ((lock (msl-test--hold-lock msl-test--dead-pid (system-name) 60)))
      (should (eq 'ran (mu4e-send-later--with-lock 'ran)))
      (should-not (file-exists-p lock)))))

;; The owner died, and a later process has its PID.
(ert-deftest msl-test-lock-from-before-its-owner-started-is-broken ()
  (msl-test--with-queue
    (let ((lock (msl-test--hold-lock (emacs-pid) (system-name))))
      (set-file-times lock (time-subtract (msl-test--own-start) 120))
      (should (mu4e-send-later--lock-stale-p (mu4e-send-later--lock-owner)))
      ;; But not for a small difference, which can be the clocks.
      (set-file-times lock (time-subtract (msl-test--own-start) 30))
      (should-not (mu4e-send-later--lock-stale-p (mu4e-send-later--lock-owner))))))

(ert-deftest msl-test-lock-of-an-owner-that-cant-be-asked-waits-to-be-old ()
  (msl-test--with-queue
    (dolist (host '("elsewhere" nil))
      (let ((lock (if host
                      (msl-test--hold-lock msl-test--dead-pid host 60)
                    ;; No owner written, as by 0.2.
                    (make-directory (mu4e-send-later--lock-dir) t)
                    (set-file-times (mu4e-send-later--lock-dir) (time-subtract nil 60))
                    (mu4e-send-later--lock-dir))))
        (should-not (mu4e-send-later--lock-stale-p (mu4e-send-later--lock-owner)))
        (set-file-times lock (time-subtract nil 3600))
        (should (mu4e-send-later--lock-stale-p (mu4e-send-later--lock-owner)))
        (delete-directory lock t)))))

(ert-deftest msl-test-lock-writes-its-owner-and-keeps-others-locks ()
  (msl-test--with-queue
    (let ((lock (mu4e-send-later--dir ".lock")))
      (mu4e-send-later--with-lock
        (with-temp-buffer
          (insert-file-contents (expand-file-name "owner" lock))
          (should (string-prefix-p (format "%d %s " (emacs-pid) (system-name))
                                   (buffer-string))))
        ;; Our lock was broken as stale and someone else took it.
        (delete-directory lock t)
        (msl-test--hold-lock msl-test--dead-pid (system-name)))
      (should (file-exists-p (expand-file-name "owner" lock))))))

(ert-deftest msl-test-interactive-lock-wait-is-short-and-says-why ()
  (msl-test--with-queue
    (msl-test--hold-lock (emacs-pid) (system-name))
    (let ((noninteractive nil)
          (start (float-time))
          (waited nil))
      (cl-letf (((symbol-function 'sleep-for) (lambda (&rest _) (setq waited t))))
        (let ((err (should-error
                    (cl-letf (((symbol-function 'float-time)
                               (lambda (&rest _) (cl-incf start 1))))
                      (mu4e-send-later--with-lock t))
                    :type 'user-error)))
          (should (string-match-p "in progress" (cadr err)))))
      (should waited)
      ;; Given up after about 5 seconds of the stubbed clock, not 60.
      (should (< (- start (float-time)) 10)))))

(ert-deftest msl-test-reschedule-after-sending-says-so ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600))))
      (delete-directory (mu4e-send-later--item-dir id) t)
      (should (string-match-p
               "already sent"
               (cadr (should-error (mu4e-send-later--update id #'identity)
                                   :type 'user-error)))))))

(defun msl-test--in-list (subject fn)
  "Call FN on the message with SUBJECT in the list."
  (mu4e-send-later-list)
  (unwind-protect
      (with-current-buffer "*mu4e-send-later*"
        (goto-char (point-min))
        (search-forward subject)
        (funcall fn))
    (kill-buffer "*mu4e-send-later*")))

;; A sender that died mid-send leaves the item `sending'; it may have
;; gone out, so neither sending nor rescheduling it is done unasked.
(ert-deftest msl-test-send-now-and-reschedule-refuse-an-interrupted-send ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600 "Interrupted")))
          (later (+ (floor (float-time)) 7200)))
      (cl-letf (((symbol-function 'mu4e-send-later--flush-async) #'ignore))
        (dolist (command (list #'mu4e-send-later-send-now
                               (lambda () (mu4e-send-later-reschedule later))))
          (mu4e-send-later--set-meta
           id (plist-put (mu4e-send-later--meta id) :state 'sending))
          (should (string-match-p
                   "may have been sent"
                   (cadr (should-error (msl-test--in-list "Interrupted" command)
                                       :type 'user-error))))
          (let ((meta (mu4e-send-later--meta id)))
            (should (eq (plist-get meta :state) 'failed))
            (should-not (eql (plist-get meta :due) later)))))
      ;; Marked failed, doing it again is a choice, and done.
      (msl-test--in-list "Interrupted" (lambda () (mu4e-send-later-reschedule later)))
      (should (eq (plist-get (mu4e-send-later--meta id) :state) 'pending))
      (should (eql (plist-get (mu4e-send-later--meta id) :due) later))
      (should-not msl-test--sent))))

;; While you type the time, the message can be sent in the background,
;; and the watch on the queue refreshes the list under you.
(ert-deftest msl-test-reschedule-moves-the-message-it-asked-about ()
  (msl-test--with-queue
    (let* ((first (car (msl-test--schedule 3600 "First")))
           (second (car (msl-test--schedule 7200 "Second")))
           (due (plist-get (mu4e-send-later--meta first) :due)))
      (msl-test--in-list
       "Second"
       (lambda ()
         (cl-letf (((symbol-function 'mu4e-send-later--read-time)
                    (lambda ()
                      (delete-directory (mu4e-send-later--item-dir second) t)
                      (mu4e-send-later--changed)
                      (+ (floor (float-time)) 86400))))
           (should (string-match-p
                    "already sent"
                    (cadr (should-error (call-interactively #'mu4e-send-later-reschedule)
                                        :type 'user-error)))))))
      (should (eql (plist-get (mu4e-send-later--meta first) :due) due)))))

(ert-deftest msl-test-flush-keeps-the-lock-fresh ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600)))
          (lock (mu4e-send-later--dir ".lock"))
          (age nil))
      (msl-test--make-due id)
      (cl-letf* ((ids (symbol-function 'mu4e-send-later--ids))
                 ;; As if the lock had been held a long time already.
                 ((symbol-function 'mu4e-send-later--ids)
                  (lambda ()
                    (set-file-times lock (time-subtract nil 3600))
                    (funcall ids)))
                 (send (symbol-function 'mu4e-send-later--send))
                 ((symbol-function 'mu4e-send-later--send)
                  (lambda (id)
                    (setq age (float-time (time-since (file-attribute-modification-time
                                                       (file-attributes lock)))))
                    (funcall send id))))
        (mu4e-send-later--flush))
      (should (< age 60)))))

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

(ert-deftest msl-test-list-sorts-by-when-due ()
  (msl-test--with-queue
    ;; The weekdays of four days in a row are never in alphabetical order.
    (dolist (day '(3 1 4 2))
      (msl-test--schedule (* 86400 day) (format "day%d" day)))
    (mu4e-send-later-list)
    (unwind-protect
        (with-current-buffer "*mu4e-send-later*"
          (let ((subjects (lambda ()
                            (mapcar (lambda (entry) (aref (cadr entry) 3))
                                    tabulated-list-entries))))
            (goto-char (point-min))
            (tabulated-list-sort 0)
            (should (equal (funcall subjects) '("day1" "day2" "day3" "day4")))
            (tabulated-list-sort 0)
            (should (equal (funcall subjects) '("day4" "day3" "day2" "day1")))))
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

(ert-deftest msl-test-wake-up-names-belong-to-their-queue ()
  (let* ((names (lambda (dir)
                  (let ((mu4e-send-later-directory dir))
                    (list (mu4e-send-later--systemd-unit 1790000000)
                          (mu4e-send-later--launchd-label 1790000000)))))
         (mine (funcall names "/tmp/msl-a/"))
         (theirs (funcall names "/tmp/msl-b/")))
    (should (equal mine (funcall names "/tmp/msl-a")))
    (should-not (equal (car mine) (car theirs)))
    (should-not (equal (cadr mine) (cadr theirs)))
    (should (string-match-p "\\`mu4e-send-later-[0-9a-f]+-1790000000\\'" (car mine)))))

(ert-deftest msl-test-systemd-disarm-stops-only-this-queues-timers ()
  (let ((mu4e-send-later-directory "/tmp/msl-a/")
        (calls nil))
    (cl-letf (((symbol-function 'mu4e-send-later--call)
               (lambda (&rest args) (push args calls) "")))
      (mu4e-send-later--backend-disarm 'systemd))
    (should (equal calls
                   (list (list "systemctl" "--user" "stop"
                               (concat "mu4e-send-later-" (mu4e-send-later--queue-tag)
                                       "-*.timer")))))
    ;; The pattern matches this queue's units and no other's.
    (let ((pattern (wildcard-to-regexp (car (last (car calls))))))
      (should (string-match-p pattern (concat (mu4e-send-later--systemd-unit 1790000000) ".timer")))
      (let ((mu4e-send-later-directory "/tmp/msl-b/"))
        (should-not (string-match-p
                     pattern (concat (mu4e-send-later--systemd-unit 1790000000) ".timer")))))))

(ert-deftest msl-test-launchd-disarm-removes-only-this-queues-jobs ()
  (let* ((agents (make-temp-file "msl-agents-" t))
         (mu4e-send-later-directory "/tmp/msl-a/")
         (mine (mu4e-send-later--launchd-label 1790000000))
         (theirs (let ((mu4e-send-later-directory "/tmp/msl-b/"))
                   (mu4e-send-later--launchd-label 1790000000)))
         (login (concat mu4e-send-later--launchd-prefix ".login"))
         (booted nil))
    (unwind-protect
        (cl-letf (((symbol-function 'mu4e-send-later--launchd-agents-dir)
                   (lambda () (file-name-as-directory agents)))
                  ((symbol-function 'mu4e-send-later--call)
                   (lambda (&rest args) (push (car (last args)) booted) "")))
          (dolist (label (list mine theirs login))
            (write-region "" nil (mu4e-send-later--launchd-plist-file label)))
          (mu4e-send-later--backend-disarm 'launchd)
          (should-not (file-exists-p (mu4e-send-later--launchd-plist-file mine)))
          (should (file-exists-p (mu4e-send-later--launchd-plist-file theirs)))
          (should (file-exists-p (mu4e-send-later--launchd-plist-file login)))
          (should (equal booted (list (concat (mu4e-send-later--launchd-domain) "/" mine)))))
      (delete-directory agents t))))

(defun msl-test--login-job-warnings (installed-from)
  "Warnings about login jobs installed while loaded from INSTALLED-FROM.
Both a systemd unit and a LaunchAgent are written, to temporary places."
  (let* ((config (make-temp-file "msl-config-" t))
         (agents (make-temp-file "msl-agents-" t))
         (process-environment (cons (concat "XDG_CONFIG_HOME=" config) process-environment))
         (library-dir (symbol-function 'mu4e-send-later--library-dir))
         (warnings nil))
    (unwind-protect
        (cl-letf (((symbol-function 'mu4e-send-later--launchd-agents-dir)
                   (lambda () (file-name-as-directory agents)))
                  ((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (cl-letf (((symbol-function 'mu4e-send-later--library-dir)
                     (lambda () installed-from)))
            (let ((file (mu4e-send-later--systemd-login-file))
                  (label (concat mu4e-send-later--launchd-prefix ".login")))
              (make-directory (file-name-directory file) t)
              (write-region (mu4e-send-later--systemd-login-unit-text) nil file)
              (write-region (mu4e-send-later--plist-xml label (mu4e-send-later--login-command))
                            nil (mu4e-send-later--launchd-plist-file label))))
          (should (equal (funcall library-dir) (mu4e-send-later--library-dir)))
          (mu4e-send-later--check-login-job)
          warnings)
      (delete-directory config t)
      (delete-directory agents t))))

(ert-deftest msl-test-login-job-from-an-old-library-dir-is-reported ()
  (let ((warnings (msl-test--login-job-warnings "/gone/mu4e-send-later-0.1/")))
    (should (= (length warnings) 2))
    (dolist (warning warnings)
      (should (string-match-p "/gone/mu4e-send-later-0.1/" warning))
      (should (string-match-p "mu4e-send-later-install-login-job" warning)))))

;; Pending wake-ups name the library directory; after an upgrade they
;; must be re-made, pointing at the new one.
(ert-deftest msl-test-check-always-rearms ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600))))
      (setq msl-test--armed nil)
      (cl-letf (((symbol-function 'mu4e-send-later--check-login-job) #'ignore))
        (mu4e-send-later-check))
      (should (equal msl-test--armed (list (plist-get (mu4e-send-later--meta id) :due)))))))

;; package.el upgrades a package by loading it again from a new
;; directory, and the old one goes; wake-ups naming it would then fail.
(ert-deftest msl-test-loading-again-rearms-from-the-new-directory ()
  (msl-test--with-queue
    (msl-test--schedule 3600 "Upgraded")
    (let* ((root (make-temp-file "msl-upgrade-" t))
           (old (expand-file-name "mu4e-send-later-0.3.0/" root))
           (new (expand-file-name "mu4e-send-later-0.3.1/" root))
           (source (expand-file-name "mu4e-send-later.el" (mu4e-send-later--library-dir))))
      (unwind-protect
          (progn
            (dolist (dir (list old new))
              (make-directory dir)
              (copy-file source dir))
            (with-temp-buffer
              ;; In a fresh Emacs, with this library loaded from OLD and the
              ;; mode on, NEW is loaded; a stand-in backend says what the
              ;; wake-up would run.
              (should
               (zerop
                (call-process
                 (expand-file-name invocation-name invocation-directory)
                 nil t nil "-Q" "--batch" "-L" old "-l" "mu4e-send-later"
                 "--eval"
                 (format "%S"
                         `(progn
                            (advice-add 'mu4e-send-later--backend :override
                                        (lambda () 'probe))
                            (cl-defmethod mu4e-send-later--backend-disarm ((_ (eql probe))))
                            (cl-defmethod mu4e-send-later--backend-arm ((_ (eql probe)) _time)
                              (princ (format "armed from %s\n"
                                             (mu4e-send-later--library-dir))))
                            (cl-defmethod mu4e-send-later--backend-armed-p ((_ (eql probe)) _time)
                              t)
                            (setq mu4e-send-later-directory ,(mu4e-send-later--dir)
                                  mu4e-send-later-mode t)
                            (load ,(expand-file-name "mu4e-send-later.el" new) nil t))))))
              (should (equal (buffer-string) (format "armed from %s\n" new)))))
        (delete-directory root t)))))

(ert-deftest msl-test-current-login-job-is-not-reported ()
  (should-not (msl-test--login-job-warnings (mu4e-send-later--library-dir))))

(defvar msl-test--launchd nil
  "Jobs the fake launchd has loaded: (LABEL . PRINTS-LEFT).
PRINTS-LEFT is nil, or once booted out, the number of times it still
shows in `launchctl print'.")
(defvar msl-test--launchctl nil "Calls to the fake launchctl, oldest first.")
(defvar msl-test--bootout-lag 0 "How long a booted-out job still shows, in prints.")

(defun msl-test--launchctl (args)
  "Run the fake launchctl with ARGS, as launchd would; return its exit status."
  (setq msl-test--launchctl (append msl-test--launchctl (list args)))
  (let* ((target (car (last args)))
         (label (if (equal (car args) "bootstrap")
                    (file-name-base target)
                  (car (last (split-string target "/")))))
         (job (assoc label msl-test--launchd)))
    (pcase (car args)
      ("print"
       (cond ((not job) 113)
             ((not (cdr job)) 0)
             ((zerop (cdr job))
              (setq msl-test--launchd (delq job msl-test--launchd))
              113)
             (t (setcdr job (1- (cdr job))) 0)))
      ;; As launchd does, refuse to load what is loaded.
      ("bootstrap" (cond (job 5)
                         ((not (file-exists-p target)) 2)
                         (t (push (list label) msl-test--launchd) 0)))
      ("bootout" (cond ((not job) 113)
                       ((zerop msl-test--bootout-lag)
                        (setq msl-test--launchd (delq job msl-test--launchd))
                        0)
                       (t (setcdr job msl-test--bootout-lag) 0))))))

(defmacro msl-test--with-fake-launchd (&rest body)
  "Run BODY with a fake launchctl, and LaunchAgents in a temporary directory.
Not in a launchd job, to begin with."
  (declare (indent 0) (debug t))
  `(let ((agents (make-temp-file "msl-agents-" t))
         (msl-test--launchd nil)
         (msl-test--launchctl nil)
         (msl-test--bootout-lag 0)
         (process-environment (append '("MU4E_SEND_LATER_JOB" "XPC_SERVICE_NAME")
                                      process-environment)))
     (cl-letf* ((call (symbol-function 'mu4e-send-later--call))
                (succeeds (symbol-function 'mu4e-send-later--succeeds-p))
                ((symbol-function 'mu4e-send-later--launchd-agents-dir)
                 (lambda () (file-name-as-directory agents)))
                ((symbol-function 'mu4e-send-later--call)
                 (lambda (program &rest args)
                   (if (not (equal program "launchctl"))
                       (apply call program args)
                     (let ((status (msl-test--launchctl args)))
                       (unless (zerop status)
                         (signal 'mu4e-send-later-backend-error
                                 (list (format "launchctl exited with %d" status))))
                       ""))))
                ((symbol-function 'mu4e-send-later--succeeds-p)
                 (lambda (program &rest args)
                   (if (equal program "launchctl")
                       (zerop (msl-test--launchctl args))
                     (apply succeeds program args)))))
       (unwind-protect (progn ,@body)
         (delete-directory agents t)))))

(defun msl-test--in-launchd-job (label)
  "An environment like that of the launchd job LABEL."
  (cons (concat "MU4E_SEND_LATER_JOB=" label) process-environment))

(ert-deftest msl-test-launchd-plist-gives-the-job-path-and-its-label ()
  (let* ((process-environment (cons "PATH=/opt/a&b/bin:/usr/bin" process-environment))
         (xml (mu4e-send-later--plist-xml "a.b" '("/x/emacs") 1790000000)))
    (should (string-match-p (concat "<key>EnvironmentVariables</key>\n  <dict>\n"
                                    "    <key>PATH</key><string>/opt/a&amp;b/bin:/usr/bin</string>\n"
                                    "    <key>MU4E_SEND_LATER_JOB</key><string>a.b</string>\n"
                                    "  </dict>\n")
                            xml))))

(ert-deftest msl-test-launchd-arming-twice-is-fine ()
  (msl-test--with-fake-launchd
    (let ((label (mu4e-send-later--launchd-label 1790000000)))
      (dolist (lag '(0 3))
        (setq msl-test--bootout-lag lag)
        (dotimes (_ 2)
          (mu4e-send-later--backend-arm 'launchd 1790000000)
          (should (mu4e-send-later--backend-armed-p 'launchd 1790000000))
          (should (equal (mapcar #'car msl-test--launchd) (list label))))))))

(ert-deftest msl-test-launchd-load-never-boots-out-the-running-job ()
  (msl-test--with-fake-launchd
    (let ((label (mu4e-send-later--launchd-label 1790000000)))
      (mu4e-send-later--backend-arm 'launchd 1790000000)
      (setq msl-test--launchctl nil)
      ;; Arming it again from inside it, as the login job might.
      (let ((process-environment (msl-test--in-launchd-job label)))
        (mu4e-send-later--backend-arm 'launchd 1790000000)
        (should-not msl-test--launchctl)
        ;; An older job only named itself in launchd's variable.
        (let ((process-environment (cons (concat "XPC_SERVICE_NAME=" label)
                                         process-environment)))
          (setenv "MU4E_SEND_LATER_JOB")
          (mu4e-send-later--backend-arm 'launchd 1790000000)
          (should-not msl-test--launchctl)))
      (should (equal (mapcar #'car msl-test--launchd) (list label))))))

(ert-deftest msl-test-launchd-rearming-keeps-one-job ()
  (msl-test--with-queue
    (msl-test--with-fake-launchd
      (let* ((first (car (msl-test--schedule 3600 "First")))
             (due (plist-get (mu4e-send-later--meta first) :due)))
        (msl-test--schedule 7200 "Second")
        (cl-letf (((symbol-function 'mu4e-send-later--backend) (lambda () 'launchd)))
          (dotimes (_ 2)
            (should (eql (mu4e-send-later--arm) due))
            (should (equal (mapcar #'car msl-test--launchd)
                           (list (mu4e-send-later--launchd-label due))))
            (should (equal (directory-files agents nil "\\.plist\\'")
                           (list (concat (mu4e-send-later--launchd-label due) ".plist"))))))))))

;; A calendar job has no year: loaded, it would fire again next year.
(ert-deftest msl-test-launchd-job-unloads-itself-once-it-has-run ()
  (msl-test--with-queue
    (msl-test--with-fake-launchd
      (let* ((label (mu4e-send-later--launchd-label 1790000000))
             (login (concat mu4e-send-later--launchd-prefix ".login"))
             (flush (lambda (job)
                      (let ((process-environment (msl-test--in-launchd-job job))
                            (command-line-args-left (list (mu4e-send-later--dir))))
                        (cl-letf (((symbol-function 'kill-emacs)
                                   (lambda (&optional status) (throw 'exit status))))
                          (catch 'exit (mu4e-send-later-batch-flush)))))))
        (dolist (job (list label login))
          (mu4e-send-later--launchd-load job (mu4e-send-later--plist-xml job '("/x/emacs"))))
        (setq msl-test--launchctl nil)
        (should (eql 0 (funcall flush label)))
        (should (equal msl-test--launchctl
                       (list (list "bootout" (concat (mu4e-send-later--launchd-domain) "/" label)))))
        (should-not (file-exists-p (mu4e-send-later--launchd-plist-file label)))
        ;; The login job is for every login.
        (setq msl-test--launchctl nil)
        (should (eql 0 (funcall flush login)))
        (should-not msl-test--launchctl)
        (should (file-exists-p (mu4e-send-later--launchd-plist-file login)))))))

(ert-deftest msl-test-systemd-quoting ()
  (should (equal (mu4e-send-later--systemd-quote "/a b/c\"d%e$f\\g")
                 "\"/a b/c\\\"d%%e$$f\\\\g\"")))

;;;; Integration

;;;; mu4e

(defvar msl-test--mu nil "Calls to the fake mu server, oldest first.")
(defvar mu4e-main-rendered-hook)
(defvar mu4e-index-updated-hook)

(defmacro msl-test--with-mu4e (&rest body)
  "Run BODY with a fake running mu4e over a temporary root maildir.
The fake server records adds and removes, and like mu deletes the
file it removes."
  (declare (indent 0) (debug t))
  `(let ((root (make-temp-file "msl-mail-" t))
         (msl-test--mu nil)
         (mu4e-send-later--mirrored (make-hash-table :test #'equal)))
     (cl-letf (((symbol-function 'mu4e-running-p) (lambda () t))
               ((symbol-function 'mu4e-root-maildir) (lambda () root))
               ((symbol-function 'mu4e--server-add)
                (lambda (path) (setq msl-test--mu (append msl-test--mu (list (list 'add path))))))
               ((symbol-function 'mu4e--server-remove)
                (lambda (path)
                  (setq msl-test--mu (append msl-test--mu (list (list 'remove path))))
                  (when (file-exists-p path) (delete-file path)))))
       (unwind-protect (progn ,@body)
         (delete-directory root t)))))

(defun msl-test--mirror (id)
  "Where ID's copy for mu4e goes."
  (expand-file-name (concat "scheduled/cur/" id ".send-later:2,S") (mu4e-root-maildir)))

(defun msl-test--in-mu4e-on (file fn)
  "Call FN as if in mu4e with point on the message at FILE."
  (cl-letf (((symbol-function 'mu4e-message-at-point)
             (lambda (&optional _noerror) (list :path file))))
    (with-temp-buffer (funcall fn))))

(ert-deftest msl-test-mu4e-shows-scheduled-mail-dated-when-due ()
  (msl-test--with-queue
    (msl-test--with-mu4e
      (let* ((result (msl-test--schedule 3600 "Mirrored"))
             (id (car result))
             (due (plist-get (mu4e-send-later--meta id) :due))
             (file (msl-test--mirror id)))
        (kill-buffer (cdr result))
        (should (equal msl-test--mu (list (list 'add file))))
        (dolist (sub '("cur" "new" "tmp"))
          (should (file-directory-p (expand-file-name (concat "scheduled/" sub) root))))
        (with-temp-buffer
          (insert-file-contents-literally file)
          (goto-char (point-min))
          (should (re-search-forward "^Subject: Mirrored$" nil t))
          ;; Dated when due, so mu4e shows and sorts by send time.
          (should (re-search-forward
                   (concat "^Date: " (regexp-quote (message-make-date due)) "$") nil t))
          ;; A real message: headers end at a blank line, not the separator.
          (goto-char (point-min))
          (should-not (search-forward mail-header-separator nil t))
          (should (re-search-forward "^$" nil t))
          (should (search-forward "Body with" nil t)))
        ;; Nothing changed, so nothing is re-sent to mu.
        (mu4e-send-later--mu4e-sync)
        (should (= (length msl-test--mu) 1))))))

(ert-deftest msl-test-mu4e-not-running-leaves-maildir-alone ()
  (msl-test--with-queue
    (let ((root (make-temp-file "msl-mail-" t)))
      (unwind-protect
          (cl-letf (((symbol-function 'mu4e-running-p) (lambda () nil))
                    ((symbol-function 'mu4e-root-maildir) (lambda () root)))
            (kill-buffer (cdr (msl-test--schedule 3600)))
            (should-not (directory-files root nil "\\`[^.]")))
        (delete-directory root t)))))

(ert-deftest msl-test-mu4e-reschedule-and-cancel-from-mu4e ()
  (msl-test--with-queue
    (msl-test--with-mu4e
      (let* ((result (msl-test--schedule 3600 "Moved"))
             (id (car result))
             (file (msl-test--mirror id))
             (later (+ (floor (float-time)) 7200)))
        (kill-buffer (cdr result))
        (setq msl-test--mu nil)
        (msl-test--in-mu4e-on file (lambda () (mu4e-send-later-reschedule later)))
        (should (equal (plist-get (mu4e-send-later--meta id) :due) later))
        (should (equal msl-test--armed (list later)))
        ;; Rewritten in place, so mu4e updates the line it shows.
        (should (equal msl-test--mu (list (list 'add file))))
        (with-temp-buffer
          (insert-file-contents-literally file)
          (should (search-forward (message-make-date later) nil t)))
        (setq msl-test--mu nil)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
          (msl-test--in-mu4e-on file #'mu4e-send-later-cancel))
        (should-not (mu4e-send-later--ids))
        (should (file-exists-p (mu4e-send-later--dir "cancelled" id "message")))
        (should (equal msl-test--mu (list (list 'remove file))))
        (should-not (file-exists-p file))
        ;; Acting on it again is refused rather than resurrecting it.
        (should-error (msl-test--in-mu4e-on file #'mu4e-send-later-send-now)
                      :type 'user-error)))))

(ert-deftest msl-test-mu4e-drops-mail-sent-in-the-background ()
  (msl-test--with-queue
    (msl-test--with-mu4e
      (let* ((sent (car (msl-test--schedule 3600 "Sent")))
             (kept (car (msl-test--schedule 7200 "Kept"))))
        (dolist (buffer (buffer-list))
          (when (string-prefix-p "*sent" (buffer-name buffer)) (kill-buffer buffer)))
        (msl-test--make-due sent)
        ;; As a background Emacs would, which knows nothing of mu4e.
        (cl-letf (((symbol-function 'mu4e-send-later--mu4e-sync) #'ignore))
          (mu4e-send-later--flush))
        (should (file-exists-p (msl-test--mirror sent)))
        (setq msl-test--mu nil)
        (mu4e-send-later--mu4e-sync)
        (should (equal msl-test--mu (list (list 'remove (msl-test--mirror sent)))))
        (should (file-exists-p (msl-test--mirror kept)))))))

(ert-deftest msl-test-mu4e-mirror-renamed-by-mu4e-is-not-duplicated ()
  (msl-test--with-queue
    (msl-test--with-mu4e
      (let* ((result (msl-test--schedule 3600 "Flagged"))
             (id (car result))
             (flagged (replace-regexp-in-string ":2,S\\'" ":2,FS" (msl-test--mirror id)))
             (later (+ (floor (float-time)) 7200)))
        (kill-buffer (cdr result))
        ;; Flagging it in mu4e renames the file.
        (rename-file (msl-test--mirror id) flagged)
        (setq msl-test--mu nil)
        (mu4e-send-later--mu4e-sync)
        (should-not msl-test--mu)
        (should (equal (directory-files (file-name-directory flagged) nil "send-later")
                       (list (file-name-nondirectory flagged))))
        ;; Rescheduled, the copy mu4e has is the one brought up to date.
        (mu4e-send-later--update id (lambda (meta) (plist-put meta :due later)))
        (should (equal msl-test--mu (list (list 'add flagged))))
        (should (equal (directory-files (file-name-directory flagged) nil "send-later")
                       (list (file-name-nondirectory flagged))))
        (with-temp-buffer
          (insert-file-contents-literally flagged)
          (should (search-forward (message-make-date later) nil t)))))))

(ert-deftest msl-test-queue-event-resyncs-only-for-items ()
  (let ((mu4e-send-later--sync-timer nil))
    (unwind-protect
        (progn
          (mu4e-send-later--queue-event (list 'd 'created "/q/.lock"))
          (mu4e-send-later--queue-event (list 'd 'changed "/q/log"))
          (should-not mu4e-send-later--sync-timer)
          (mu4e-send-later--queue-event (list 'd 'renamed "/q/.tmp-1-a" "/q/1790000000-abcdef"))
          (should (timerp mu4e-send-later--sync-timer))
          (should (eq (timer--function mu4e-send-later--sync-timer) #'mu4e-send-later--changed)))
      (when mu4e-send-later--sync-timer (cancel-timer mu4e-send-later--sync-timer)))))

;; The mode, not just the command, is what keeps mu4e current.
(ert-deftest msl-test-mode-hooks-into-mu4e-and-the-queue ()
  (msl-test--with-queue
    (let ((mu4e-main-rendered-hook nil)
          (mu4e-index-updated-hook nil)
          (mu4e-send-later--watch nil)
          (mu4e-send-later-mode nil))
      (cl-letf (((symbol-function 'mu4e-send-later-check) #'ignore))
        (unwind-protect
            (progn
              (mu4e-send-later-mode 1)
              (should (memq #'mu4e-send-later--mu4e-sync-safely mu4e-main-rendered-hook))
              (should (memq #'mu4e-send-later--mu4e-sync-safely mu4e-index-updated-hook))
              (should (file-notify-valid-p mu4e-send-later--watch))
              (mu4e-send-later-mode -1)
              (should-not mu4e-main-rendered-hook)
              (should-not mu4e-index-updated-hook)
              (should-not mu4e-send-later--watch))
          (mu4e-send-later-mode -1))))))

(ert-deftest msl-test-mode-off-undoes-startup-and-pending-sync ()
  (msl-test--with-queue
    (let ((after-init-time nil)
          (after-init-hook nil)
          (mu4e-main-rendered-hook nil)
          (mu4e-index-updated-hook nil)
          (mu4e-send-later--watch nil)
          (mu4e-send-later--sync-timer nil)
          (mu4e-send-later-mode nil))
      (unwind-protect
          (progn
            ;; Enabled from an init file, before startup finishes.
            (mu4e-send-later-mode 1)
            (should (memq #'mu4e-send-later-check after-init-hook))
            (mu4e-send-later--queue-event (list 'd 'created (mu4e-send-later--dir "1790000000-abcdef")))
            (let ((timer mu4e-send-later--sync-timer))
              (should (memq timer timer-list))
              (mu4e-send-later-mode -1)
              (should-not (memq #'mu4e-send-later-check after-init-hook))
              (should-not (memq timer timer-list))
              (should-not mu4e-send-later--sync-timer)))
        (mu4e-send-later-mode -1)
        (when mu4e-send-later--sync-timer (cancel-timer mu4e-send-later--sync-timer))))))

(ert-deftest msl-test-not-a-scheduled-message ()
  (msl-test--with-queue
    (msl-test--with-mu4e
      (should-error (msl-test--in-mu4e-on (expand-file-name "acct/Inbox/cur/1.2.host:2,S" root)
                                          #'mu4e-send-later-edit)
                    :type 'user-error)
      (should-error (with-temp-buffer (mu4e-send-later-cancel)) :type 'user-error))))

(ert-deftest msl-test-edit-reopens-the-draft-as-written ()
  (msl-test--with-queue
    (let* ((result (msl-test--schedule 3600 "Editable"))
           (id (car result)))
      (kill-buffer (cdr result))
      (mu4e-send-later-list)
      (unwind-protect
          (with-current-buffer "*mu4e-send-later*"
            (goto-char (point-min))
            (search-forward "Editable")
            (mu4e-send-later-edit)
            (should-not (mu4e-send-later--ids))
            (should (file-exists-p (mu4e-send-later--dir "cancelled" id "draft")))
            (should-not msl-test--armed)
            ;; The source, not the rendered message: unencoded, separator kept.
            (should (derived-mode-p 'message-mode))
            (should (string-prefix-p "*unsent mail*" (buffer-name)))
            (goto-char (point-min))
            (should (search-forward "Subject: Editable\n" nil t))
            (should (search-forward (concat mail-header-separator "\nBody with ünïcode.") nil t))
            (should-not (save-excursion (goto-char (point-min)) (search-forward "Message-ID" nil t)))
            (kill-buffer))
        (kill-buffer "*mu4e-send-later*")))))

(ert-deftest msl-test-edit-org-msg-draft-returns-to-its-drafts-folder ()
  (msl-test--with-queue
    (msl-test--with-mu4e
      (let* ((drafts (expand-file-name "acct/Drafts/cur/" root))
             (buffer (msl-test--org-msg-draft '(utf-8 html) "This is *bold*."))
             (mail-user-agent 'message-user-agent)
             (message-interactive t)
             opened id)
        (make-directory drafts t)
        (with-current-buffer buffer
          (setq buffer-file-name (expand-file-name "1.2.host:2,DS" drafts))
          (setq id (mu4e-send-later (+ (floor (float-time)) 3600))))
        (kill-buffer buffer)
        (setq msl-test--mu nil)
        (cl-letf (((symbol-function 'mu4e--draft)
                   (lambda (type fn &optional _parent)
                     (setq opened (list type (funcall fn)))
                     (cadr opened)))
                  ((symbol-function 'mu4e--delimit-headers) #'ignore))
          (msl-test--in-mu4e-on (msl-test--mirror id) #'mu4e-send-later-edit))
        (should-not (mu4e-send-later--ids))
        (should (eq (car opened) 'edit))
        ;; Back in org-msg, even where org-msg wouldn't take it over itself.
        (should (eq (buffer-local-value 'major-mode (cadr opened)) 'org-msg-edit-mode))
        (let ((path (buffer-file-name (cadr opened))))
          (kill-buffer (cadr opened))
          ;; A new draft in the Drafts maildir it came from, known to mu.
          (should (equal (file-name-directory path) drafts))
          (should (string-suffix-p ":2,DS" path))
          (should (member (list 'add path) msl-test--mu))
          (should (member (list 'remove (msl-test--mirror id)) msl-test--mu))
          (with-temp-buffer
            (insert-file-contents path)
            ;; Saved like mu4e saves a draft: a blank line, not the separator.
            (should-not (search-forward mail-header-separator nil t))
            (should (search-forward "Subject: Org plans\n\n:PROPERTIES:" nil t))
            (should (search-forward "This is *bold*." nil t))))))))

(defun msl-test--edit-in-list (subject)
  "Call `mu4e-send-later-edit' on SUBJECT in the list."
  (mu4e-send-later-list)
  (unwind-protect
      (with-current-buffer "*mu4e-send-later*"
        (goto-char (point-min))
        (search-forward subject)
        (mu4e-send-later-edit))
    (kill-buffer "*mu4e-send-later*")))

(ert-deftest msl-test-edit-that-cannot-open-the-draft-keeps-it-scheduled ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600 "Unopenable"))))
      (cl-letf (((symbol-function 'mu4e-send-later--open-draft)
                 (lambda (&rest _) (error "No room for a draft"))))
        (should-error (msl-test--edit-in-list "Unopenable")))
      (should (equal (mu4e-send-later--ids) (list id)))
      (should msl-test--armed))))

(ert-deftest msl-test-edit-that-cannot-unschedule-says-so ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600 "Stuck")))
          (opened nil))
      (cl-letf (((symbol-function 'mu4e-send-later--open-draft)
                 (lambda (&rest _) (setq opened t)))
                ((symbol-function 'mu4e-send-later--unschedule)
                 (lambda (_) (error "Disk full"))))
        (should (string-match-p
                 "still scheduled"
                 (error-message-string (should-error (msl-test--edit-in-list "Stuck"))))))
      (should opened)
      (should (equal (mu4e-send-later--ids) (list id))))))

(defun msl-test--send-in-background (id)
  "Send item ID, as a background sender would, from another process."
  (msl-test--make-due id)
  (mu4e-send-later--flush))

(ert-deftest msl-test-cancel-after-a-background-send-says-it-was-sent ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600 "Raced"))))
      (mu4e-send-later-list)
      (unwind-protect
          (with-current-buffer "*mu4e-send-later*"
            (goto-char (point-min))
            (search-forward "Raced")
            ;; Sent while you were asked to confirm.
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (_) (msl-test--send-in-background id) t)))
              (should (string-match-p
                       "already sent"
                       (cadr (should-error (mu4e-send-later-cancel) :type 'user-error)))))
            (should (= (length msl-test--sent) 1))
            (should-not (file-exists-p (mu4e-send-later--dir "cancelled" id)))
            ;; The lock was let go.
            (should-not (file-exists-p (mu4e-send-later--lock-dir))))
        (kill-buffer "*mu4e-send-later*")))))

(ert-deftest msl-test-edit-after-a-background-send-says-it-was-sent ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600 "Raced")))
          (opened nil))
      ;; Sent while the draft was being opened.
      (cl-letf (((symbol-function 'mu4e-send-later--open-draft)
                 (lambda (&rest _)
                   (setq opened t)
                   (msl-test--send-in-background id))))
        (let ((message (error-message-string
                        (should-error (msl-test--edit-in-list "Raced")))))
          (should (string-match-p "was sent" message))
          (should (string-match-p "send it again" message))
          (should-not (string-match-p "still scheduled" message))))
      (should opened)
      (should (= (length msl-test--sent) 1)))))

(ert-deftest msl-test-edit-says-where-the-original-went ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600 "Kept")))
          (said nil))
      (cl-letf (((symbol-function 'mu4e-send-later--open-draft) #'ignore)
                ((symbol-function 'message)
                 (lambda (format &rest args)
                   (when format (push (apply #'format-message format args) said)))))
        (msl-test--edit-in-list "Kept"))
      (should (string-match-p (regexp-quote (mu4e-send-later--dir "cancelled" id))
                              (car said))))))

(ert-deftest msl-test-edit-needs-a-kept-draft ()
  (msl-test--with-queue
    (let ((id (car (msl-test--schedule 3600))))
      (delete-file (expand-file-name "draft" (mu4e-send-later--item-dir id)))
      (mu4e-send-later-list)
      (unwind-protect
          (with-current-buffer "*mu4e-send-later*"
            (goto-char (point-min))
            (should-error (mu4e-send-later-edit) :type 'user-error)
            (should (equal (mu4e-send-later--ids) (list id))))
        (kill-buffer "*mu4e-send-later*")))))

(ert-deftest msl-test-integration-end-to-end ()
  "Schedule through a real systemd timer or launchd job and a fake sendmail."
  :tags '(:integration)
  (skip-unless (equal (getenv "MU4E_SEND_LATER_INTEGRATION") "1"))
  (let* ((backend (cond ((mu4e-send-later--systemd-available-p) 'systemd)
                        ((mu4e-send-later--launchd-available-p) 'launchd))))
    (skip-unless backend)
    (let* ((real-tag (mu4e-send-later--queue-tag))
           (dir (make-temp-file "msl-int-" t))
           (mu4e-send-later-directory (expand-file-name "queue/" dir))
           (mu4e-send-later-backend backend)
           (mu4e-send-later-mode t)
           (sink (expand-file-name "sent" dir))
           (sendmail (expand-file-name "fake-sendmail" dir))
           (sendmail-program sendmail)
           (message-sendmail-extra-arguments '("--read-envelope-from"))
           (message-send-mail-function #'message-send-mail-with-sendmail)
           (message-interactive t)
           (time (+ (floor (float-time)) 3))
           (wait (lambda (seconds test)
                   (let ((deadline (+ (float-time) seconds)))
                     (while (and (not (funcall test)) (< (float-time) deadline))
                       (sleep-for 0.5)))
                   (funcall test))))
      ;; Its own queue, so arming and disarming leave your real timers be.
      (should-not (equal (mu4e-send-later--queue-tag) real-tag))
      (unwind-protect
          (progn
            (with-temp-file sendmail
              (insert (format "#!/bin/sh\n{ echo \"ARGS: $*\"; cat; } > %s\n" sink)))
            (set-file-modes sendmail #o755)
            (let ((buffer (msl-test--draft "Integration")))
              (with-current-buffer buffer
                (setq-local message-send-mail-function #'message-send-mail-with-sendmail)
                (mu4e-send-later time)))
            (should (= 1 (length (mu4e-send-later--ids))))
            ;; launchd fires on the minute.
            (should (funcall wait (if (eq backend 'launchd) 150 30)
                             (lambda () (file-exists-p sink))))
            (should (funcall wait 30 (lambda () (not (mu4e-send-later--ids)))))
            (with-temp-buffer
              (insert-file-contents sink)
              (should (search-forward "--read-envelope-from" nil t))
              ;; -oem would have sendmail mail errors back instead of failing.
              (goto-char (point-min))
              (should-not (search-forward "-oem" nil t))
              (should (search-forward "Subject: Integration" nil t))
              (should-not (search-forward mail-header-separator nil t)))
            (when (eq backend 'launchd)
              ;; The job that sent it unloaded itself, and left no plist.
              (let ((label (mu4e-send-later--launchd-label time)))
                (should (funcall wait 30 (lambda ()
                                           (not (mu4e-send-later--launchd-loaded-p label)))))
                (should-not (file-exists-p (mu4e-send-later--launchd-plist-file label))))))
        (ignore-errors (mu4e-send-later--backend-disarm backend))
        (delete-directory dir t)))))

(provide 'mu4e-send-later-test)
;;; mu4e-send-later-test.el ends here
