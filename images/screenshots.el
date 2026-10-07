;;; screenshots.el --- Make the README's images -*- lexical-binding: t; -*-

;;; Commentary:

;; From the top of the repository, in a graphical session:
;;
;;     emacs -Q -l images/screenshots.el
;;
;; It schedules a draft in a fresh `message-mode' buffer, typing into it
;; as you would, has Emacs write its own frame to PNG (Emacs built with
;; Cairo), and puts images/demo.gif and images/list.png together with
;; ImageMagick's `magick'.  Emacs exits when it is done.  The frame shows
;; on screen while it works; to keep it off the screen, run it under a
;; headless Wayland compositor, such as
;;
;;     WLR_BACKENDS=headless sway -c config
;;
;; with WAYLAND_DISPLAY set to that compositor's socket.  sway tiles
;; windows, which overrides the frame sizes set here, so the config
;; must float them:
;;
;;     for_window [app_id=".*"] floating enable
;;
;; Nothing is sent and nothing is armed.  The queue is a temporary
;; directory, deleted at the end; the scheduler, the background sender,
;; notifications and every way of sending mail are replaced by stubs
;; before anything runs; and `mu4e-send-later-mode' stays off, so your
;; own queue, timers and mail are never touched.  mu4e isn't loaded.

;;; Code:

(require 'cl-lib)

(defconst screenshots-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "The images directory, where the images are written.")

(defvar screenshots-tmp (make-temp-file "mu4e-send-later-shots-" t)
  "Where the queue and the frames are kept until they are put together.")

;; Keep the default queue away from yours even before the option is set.
(setenv "XDG_STATE_HOME" (expand-file-name "state" screenshots-tmp))

(add-to-list 'load-path (expand-file-name ".." screenshots-dir))
(require 'mu4e-send-later)
(require 'sendmail)
(require 'smtpmail)

;;;; Making sure nothing escapes

(setq mu4e-send-later-directory (expand-file-name "queue/" screenshots-tmp)
      ;; As if armed by systemd, so the message reads as it would there,
      ;; but every scheduler function below is a stub.
      mu4e-send-later-backend 'systemd
      ;; Found, so it can be stored, and harmless if it were ever run.
      sendmail-program (executable-find "true")
      send-mail-function #'screenshots-refuse
      message-send-mail-function #'screenshots-refuse)

(defun screenshots-refuse (&rest _)
  "Refuse to send mail; nothing here may."
  (error "The screenshots must not send mail"))

(defvar screenshots-armed nil
  "The time the stub scheduler was last asked to wake up at.")

(dolist (fn '(smtpmail-send-it
              sendmail-send-it
              message-send-mail-with-sendmail
              message-smtpmail-send-it
              mu4e-send-later--send
              mu4e-send-later--call
              mu4e-send-later--backend-run
              mu4e-send-later-mode))
  (advice-add fn :override #'screenshots-refuse))
(advice-add 'mu4e-send-later--succeeds-p :override #'ignore)
(advice-add 'mu4e-send-later--backend :override (lambda () 'systemd))
(advice-add 'mu4e-send-later--backend-arm :override
            (lambda (_backend time) (setq screenshots-armed time)))
(advice-add 'mu4e-send-later--backend-disarm :override
            (lambda (_backend) (setq screenshots-armed nil)))
(advice-add 'mu4e-send-later--backend-armed-p :override
            (lambda (_backend time) (eql time screenshots-armed)))
(advice-add 'mu4e-send-later--preflight :override #'ignore)
(advice-add 'mu4e-send-later--flush-async :override #'ignore)
(advice-add 'mu4e-send-later--notify :override #'ignore)
(advice-add 'mu4e-send-later--mu4e-sync :override #'ignore)
(advice-add 'mu4e-send-later--watch :override #'ignore)
;; The warning that the mode is off: it is off on purpose.
(advice-add 'display-warning :before-until
            (lambda (type message &rest _)
              (and (eq type 'mu4e-send-later)
                   (string-match-p "mode' is off" message))))

;;;; The frame

(setq inhibit-startup-screen t
      ring-bell-function #'ignore
      frame-resize-pixelwise t
      user-full-name "Sam Okafor"
      user-mail-address "sam@example.com"
      message-kill-buffer-on-exit t
      suggest-key-bindings nil)
(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(blink-cursor-mode -1)
(load-theme 'modus-operandi t)
(set-face-attribute 'default nil :family "DejaVu Sans Mono" :height 140)

(defun screenshots-export (name)
  "Write the selected frame to NAME.png in a temporary directory.
Return the file name."
  (redisplay t)
  (sit-for 0.3)
  (redisplay t)
  (let ((file (expand-file-name (concat name ".png") screenshots-tmp))
        (coding-system-for-write 'binary))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert (x-export-frames nil 'png)))
    file))

(defun screenshots-magick (&rest args)
  "Run `magick' with ARGS, signalling if it fails."
  (unless (zerop (apply #'call-process "magick" nil nil nil args))
    (error "Magick failed: %S" args)))

(defun screenshots-framed (file)
  "Return FILE with a thin grey border, as a new file beside it."
  (let ((framed (concat (file-name-sans-extension file) "-framed.png")))
    (screenshots-magick file "-bordercolor" "#c8c8c8" "-border" "1" framed)
    framed))

(defun screenshots-type (keys)
  "Queue KEYS, a `kbd' string, as if typed."
  (setq unread-command-events
        (append unread-command-events (listify-key-sequence (kbd keys)))))

(defvar screenshots-steps nil
  "Steps still to run, each (DELAY . FUNCTION).")

(defun screenshots-run (&rest steps)
  "Run STEPS, each (DELAY . FUNCTION), DELAY seconds after the last.
They run from timers, so that a step can look at a prompt an earlier
step left waiting."
  (setq screenshots-steps steps)
  (screenshots--next))

(defun screenshots--next ()
  "Run the next of `screenshots-steps' after its delay."
  (when screenshots-steps
    (pcase-let ((`(,delay . ,fn) (pop screenshots-steps)))
      (run-at-time delay nil
                   (lambda ()
                     (condition-case err
                         (funcall fn)
                       (error (message "Screenshot step failed: %S" err)
                              (delete-directory screenshots-tmp t)
                              (kill-emacs 2)))
                     (screenshots--next))))))

;;;; The queue

(defun screenshots-at (days hour minute)
  "Unix time DAYS from today at HOUR:MINUTE."
  (let ((d (decode-time)))
    (floor (float-time (encode-time (list 0 minute hour
                                          (+ days (decoded-time-day d))
                                          (decoded-time-month d)
                                          (decoded-time-year d)
                                          nil -1 nil))))))

(defun screenshots-queue (due to subject &rest more)
  "Put a message to TO about SUBJECT in the queue, due at DUE.
MORE is metadata to add, as `:state' and `:last-error'.  The item is
written in the queue's own format, as `mu4e-send-later' writes it."
  (let* ((id (format "%d-%06x" due (random #xffffff)))
         (dir (mu4e-send-later--dir id)))
    (mu4e-send-later--make-queue-dir)
    (make-directory dir)
    (with-temp-file (expand-file-name "message" dir)
      (insert "From: Sam Okafor <sam@example.com>\nTo: " to
              "\nSubject: " subject "\n" mail-header-separator "\n\n"))
    (mu4e-send-later--write-data
     (expand-file-name "meta.eld" dir)
     (append more
             (list :format 1 :due due :created (floor (float-time))
                   :state 'pending :attempts 0
                   :send-function 'message-send-mail-with-sendmail
                   :separator mail-header-separator :variables nil
                   :from "Sam Okafor <sam@example.com>" :to to :subject subject
                   :draft-mode 'message-mode :draft-file nil :fcc nil
                   :fcc-handler nil)))))

(screenshots-queue (screenshots-at 1 8 30) "Ana Lima <ana@example.org>"
                   "Re: Draft agenda for Thursday")
(screenshots-queue (screenshots-at 2 17 0) "board@example.org"
                   "Minutes of the September meeting")

;;;; The draft

(defun screenshots-draft ()
  "Show a fresh draft, ready to schedule."
  (let ((buffer (generate-new-buffer "*unsent mail to Priya Rao*")))
    (switch-to-buffer buffer)
    (insert "From: Sam Okafor <sam@example.com>\n"
            "To: Priya Rao <pr@example.com>\n"
            "Subject: The revised contract terms\n"
            mail-header-separator "\n"
            "Hi Priya,\n\n"
            "Here are the revised terms we talked about on Friday. The only\n"
            "change of substance is in section 4: the notice period is now\n"
            "sixty days rather than thirty.\n\n"
            "Let me know if anything needs another look before we sign.\n\n"
            "Best,\nSam\n")
    (message-mode)
    ;; The key `mu4e-send-later-mode' binds in mu4e's drafts; the mode
    ;; itself stays off here.
    (keymap-local-set mu4e-send-later-key #'mu4e-send-later)
    (set-buffer-modified-p nil)
    ;; In the body, so the headers stay in view when the calendar pops up.
    (goto-char (point-min))
    (search-forward "Hi Priya,")))

(defun screenshots-list ()
  "Show the queue alone in the frame."
  (delete-other-windows)
  (mu4e-send-later-list)
  (delete-other-windows)
  (with-current-buffer "*mu4e-send-later*"
    (revert-buffer)
    (goto-char (point-min))))

;; The date prompt, with what it was read as, is long, and wraps in a
;; narrower frame.
(set-frame-size nil 120 22)
(mu4e-send-later-list)
(screenshots-draft)
(delete-other-windows)

(let (demo)
  (screenshots-run
   (cons 1 (lambda () (screenshots-type mu4e-send-later-key)))
   (cons 1 (lambda () (push (screenshots-export "demo-1") demo)))
   (cons 0.2 (lambda () (screenshots-type "tue SPC 9:00")))
   (cons 1 (lambda () (push (screenshots-export "demo-2") demo)))
   (cons 0.2 (lambda () (screenshots-type "RET")))
   (cons 1 (lambda () (push (screenshots-export "demo-3") demo)))
   (cons 0.2 (lambda () (screenshots-type "y")))
   (cons 1.5 (lambda ()
               (let ((echo (current-message)))
                 (screenshots-list)
                 (message "%s" echo))
               (push (screenshots-export "demo-4") demo)
               (message nil)))
   ;; Mail that has failed, or is being retried, adds its last error,
   ;; the widest column.
   (cons 0.5 (lambda ()
               (screenshots-queue
                (screenshots-at -1 16 0) "Wei Chen <wei@example.com>"
                "Invoice 2026-114"
                :state 'failed :attempts 5
                :last-error "Sending failed: 535 5.7.8 Authentication failed")
               (screenshots-queue
                (screenshots-at 0 7 45) "Jo Martin <jo@example.org>"
                "Re: Lunch on Friday?"
                :attempts 2 :next-attempt (+ (floor (float-time)) 300)
                :last-error "Sending failed: 451 4.7.1 Try again later")
               (set-frame-size nil 152 10)
               (screenshots-list)
               (message nil)))
   (cons 1 (lambda ()
             (screenshots-magick (screenshots-framed (screenshots-export "list"))
                                 "-strip" (expand-file-name "list.png" screenshots-dir))))
   (cons 0.5 (lambda ()
               (pcase-let ((`(,one ,two ,three ,four)
                            (mapcar #'screenshots-framed (reverse demo))))
                 (screenshots-magick "-delay" "120" one "-delay" "180" two
                                     "-delay" "180" three "-delay" "450" four
                                     "-loop" "0" "-layers" "Optimize"
                                     (expand-file-name "demo.gif" screenshots-dir)))
               (delete-directory screenshots-tmp t)
               (kill-emacs 0)))))

;;; screenshots.el ends here
