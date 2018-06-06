;;; mu4e-conversation.el --- Show a complete thread in a single buffer -*- lexical-binding: t -*-

;; Copyright (C) 2018 Pierre Neidhardt <ambrevar@gmail.com>

;; Author: Pierre Neidhardt <ambrevar@gmail.com>
;; Maintainer: Pierre Neidhardt <ambrevar@gmail.com>
;; URL: https://github.com/Ambrevar/mu4e-conversation
;; Version: 0.0.1
;; Package-Requires: ((emacs "25.1") (mu4e "1.0"))
;; Keywords: mail, convenience, mu4e

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; In this file we define mu4e-conversation-mode (+ helper functions), which is
;; used for viewing all e-mail messages of a thread in a single buffer.

;; TODO: Overrides are not commended.  Use unwind-protect to set handlers?  I don't think it would work.
;; TODO: Mark visible messages as read.
;; TODO: Indent user messages?
;; TODO: Detect subject changes.
;; TODO: Support fill-paragraph.  See `mu4e-view-fill-long-lines'.

;;; Code:
(require 'mu4e)
(require 'rx)

(defconst mu4e-conversation--buffer-name "*mu4e-conversation*"
  "Name of the conversation view buffer.")

(defvar mu4e-conversation-my-name "Me")

(defvar mu4e-conversation--thread-headers nil)
(defvar mu4e-conversation--thread nil)
(defvar mu4e-conversation--current-message nil)

(defvar mu4e-conversation-print-message-function 'mu4e-conversation-print-message
  "Function that takes a message and insert it's content in the current buffer.
The second argument is the message index in
`mu4e-conversation--thread', counting from 0.")

(defgroup mu4e-conversation nil
  "Settings for the mu4e conversation view."
  :group 'mu4e)

(defface mu4e-conversation-sender-me
  '((t :inherit default))
  "Face for conversation message sent by yourself."
  :group 'mu4e-conversation)

(defface mu4e-conversation-sender-1
  '((t :background "#335533"))
  "Face for conversation message from the 1st sender who is not yourself."
  :group 'mu4e-conversation)

(defface mu4e-conversation-sender-2
  '((t :background "#553333"))
  "Face for conversation message from the 2rd sender who is not yourself."
  :group 'mu4e-conversation)

(defface mu4e-conversation-sender-3
  '((t :background "#333355"))
  "Face for conversation message from the 3rd sender who is not yourself."
  :group 'mu4e-conversation)

(defface mu4e-conversation-sender-4
  '((t :background "#888833"))
  "Face for conversation message from the 4th sender who is not yourself."
  :group 'mu4e-conversation)

(defface mu4e-conversation-sender-5
  '((t :background "#4a708b"))
  "Face for conversation message from the 5th sender who is not yourself."
  :group 'mu4e-conversation)

(defface mu4e-conversation-sender-6
  '((t :background "#8b4500"))
  "Face for conversation message from the 6th sender who is not yourself."
  :group 'mu4e-conversation)

(defface mu4e-conversation-sender-7
  '((t :background "#551a8b"))
  "Face for conversation message from the 7th sender who is not yourself."
  :group 'mu4e-conversation)

(defface mu4e-conversation-sender-8
  '((t :background "#8b0a50"))
  "Face for conversation message from the 8th sender who is not yourself."
  :group 'mu4e-conversation)

(defface mu4e-conversation-sender-9
  '((t :background "#00008b"))
  "Face for conversation message from the 9th sender who is not yourself."
  :group 'mu4e-conversation)

(defface mu4e-conversation-header
  '((t :foreground "grey70" :background "grey25"))
  "Face for conversation message sent by someone else."
  :group 'mu4e-conversation)

(defcustom mu4e-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "[") 'mu4e-conversation-previous-message)
    (define-key map (kbd "]") 'mu4e-conversation-next-message)
    (define-key map (kbd "V") 'mu4e-conversation-toggle-view)
    ;; TODO: Kill window like 'mu4e-view-quit-buffer.
    ;; TODO: Bind "R" to "reply".
    ;; TODO: Should we reply to the selected message or to the last?  Make it an option: 'current, 'last, 'ask.
    ;; TODO: Binding to switch to regular view?
    ;; TODO: Bind "e" save-attachment.
    ;; TODO: Bind "#" to toggle-cite.
    ;; TODO: Bind "h" to show-html.
    map)
  "Map for `mu4e-conversation-mode'."
  :type 'key-sequence
  :group 'mu4e-conversation)

(define-minor-mode mu4e-conversation-mode
  "Minor mode for `mu4e-conversation' buffers."
  :keymap mu4e-conversation-mode-map)

(defun mu4e-conversation-previous-message ()
  "Go to previous message in linear view."
  (interactive)
  (mu4e-conversation-next-message -1))

(defun mu4e-conversation-next-message (&optional count)
  "Go to next message in linear view.
With numeric prefix argument or if COUNT is given, move that many
messages.  A negative COUNT goes backwards."
  (interactive "p")
  (when (eq major-mode 'org-mode)
    (user-error "Not in linear view."))
  (let ((move-function (if (< count 0)
                           'previous-char-property-change
                         'next-char-property-change)))
    (setq count (abs count))
    (dotimes (_ count)
      (while (and (goto-char (funcall move-function (point)))
                  (not (eq (get-text-property (point) 'face) 'mu4e-conversation-header))
                  (not (eobp)))))))

(defun mu4e-conversation-toggle-view ()
  "Switch between tree and linear view."
  (interactive)
  (mu4e-conversation-show
   (if (eq major-mode 'org-mode)
       'mu4e-conversation-print-message
     'mu4e-conversation-print-org-message)))

(defun mu4e-conversation-show (&optional print-function)
  "Display the thread in the `mu4e-conversation--buffer-name' buffer."
  ;; See the docstring of `mu4e-message-field-raw'.
  (switch-to-buffer (get-buffer-create mu4e-conversation--buffer-name))
  (view-mode 0)
  (erase-buffer)
  (setq header-line-format (mu4e-message-field (car mu4e-conversation--thread) :subject))
  (let ((current-message-pos 0)
        (index 0))
    (dolist (msg mu4e-conversation--thread)
      (when (= (mu4e-message-field msg :docid)
               (mu4e-message-field mu4e-conversation--current-message :docid))
        (setq current-message-pos (point)))
      (funcall (or print-function
                   mu4e-conversation-print-message-function)
               index)
      (mu4e~view-show-images-maybe msg)
      (setq index (1+ index))
      (goto-char (point-max)))
    (goto-char current-message-pos))
  (view-mode 1)
  (mu4e-conversation-mode))

(defun mu4e-conversation--get-message-face (index)
  "Map 'from' addresses to 'sender-N' faces in chronological
order and return corresponding face for e-mail at INDEX in
`mu4e-conversation--thread'.
E-mails whose sender is in `mu4e-user-mail-address-list' are skipped."
  (let* ((message (nth index mu4e-conversation--thread))
         (from (car (mu4e-message-field message :from)))
         (sender-faces (make-hash-table :test 'equal))
         (face-index 1))
    (dotimes (i (1+ index))
      (let* ((msg (nth i mu4e-conversation--thread))
             (from (car (mu4e-message-field msg :from)))
             (from-me-p (member (cdr from) mu4e-user-mail-address-list)))
        (unless (or from-me-p
                    (gethash (cdr from) sender-faces))
          (unless (facep (intern (format "mu4e-conversation-sender-%s" face-index)))
            (setq face-index 1))
          (puthash (cdr from)
                   (intern (format "mu4e-conversation-sender-%s" face-index))
                   sender-faces)
          (setq face-index (1+ face-index)))))
    (gethash (cdr from) sender-faces)))

;; TODO: Propertize URLs.
(defun mu4e-conversation-print-message (index)
  "Insert formatted message found at INDEX in `mu4e-conversation--thread'."
  ;; See the docstring of `mu4e-message-field-raw'.
  (unless (eq major-mode 'fundamental-mode)
    (fundamental-mode))
  (let* ((msg (nth index mu4e-conversation--thread))
         (from (car (mu4e-message-field msg :from)))
         (from-me-p (member (cdr from) mu4e-user-mail-address-list))
         (face (or (get-text-property (point) 'face)
                   (and from-me-p 'mu4e-conversation-sender-me)
                   (mu4e-conversation--get-message-face index))))
    (insert (propertize (format "%s, %s %s\n"
                                (if from-me-p
                                    mu4e-conversation-my-name
                                  (format "%s <%s>" (car from) (cdr from)))
                                (current-time-string (mu4e-message-field msg :date))
                                (mu4e-message-field msg :flags))
                        'face
                        'mu4e-conversation-header)
            ;; TODO: Add button to display trimmed quote.
            (propertize (mu4e-message-body-text msg) 'face face)
            "\n")))

(defun mu4e-conversation-print-org-message (index)
  "Insert formatted message found at INDEX in `mu4e-conversation--thread'."
  ;; See the docstring of `mu4e-message-field-raw'.
  (unless (eq major-mode 'org-mode)
    (org-mode))
  (let* ((msg (nth index mu4e-conversation--thread))
         (msg-header (nth index mu4e-conversation--thread-headers))
         (from (car (mu4e-message-field msg :from)))
         (from-me-p (member (cdr from) mu4e-user-mail-address-list))
         (level (plist-get (mu4e-message-field msg-header :thread) :level))
         (org-level (make-string (1+ level) ?*)))
    (insert (format "%s %s, %s %s\n"
                    org-level
                    (if from-me-p
                        mu4e-conversation-my-name
                      (format "%s <%s>" (car from) (cdr from)))
                    (current-time-string (mu4e-message-field msg :date))
                    (mu4e-message-field msg :flags))
            ;; TODO: Put quote in subsection / property?
            ;; Prefix "*" at the beginning of lines with a space to prevent them
            ;; from being interpreted as Org sections.
            (replace-regexp-in-string (rx line-start "*") " *"
                                      (mu4e-message-body-text msg))
            "\n")))

(defun mu4e-conversation-view-handler (msg)
  "Handler function for displaying a message."
  (push msg mu4e-conversation--thread)
  (when (= (length mu4e-conversation--thread)
           (length mu4e-conversation--thread-headers))
    (advice-remove mu4e-view-func 'mu4e-conversation-view-handler)
    ;; Headers are collected in reverse order, let's order them.
    (setq mu4e-conversation--thread-headers (nreverse mu4e-conversation--thread-headers))
    (let ((viewwin (mu4e~headers-redraw-get-view-window)))
      (unless (window-live-p viewwin)
        (mu4e-error "Cannot get a conversation window"))
      (select-window viewwin))
    (mu4e-conversation-show)))

(defun mu4e-conversation-header-handler (msg)
  "Store thread messages.
The header handler is run for all messages before the found-handler.
See `mu4e~proc-filter'"
  (push msg mu4e-conversation--thread-headers))

(defun mu4e-conversation-erase-handler ()
  "Don't clear the header buffer when viewing.")

(defun mu4e-conversation-found-handler (_count)
  (advice-remove mu4e-header-func 'mu4e-conversation-header-handler)
  (advice-remove mu4e-erase-func 'mu4e-conversation-erase-handler)
  (advice-remove mu4e-found-func 'mu4e-conversation-found-handler)
  ;; TODO: Check if current buffer is mu4e-headers?
  ;; TODO: Don't use mu4e-view?
  (if (= (length mu4e-conversation--thread-headers) 1)
      (mu4e-headers-view-message)
    (setq mu4e-conversation--thread nil)
    (advice-add mu4e-view-func :override 'mu4e-conversation-view-handler)
    (dolist (msg mu4e-conversation--thread-headers)
      (let ((docid (mu4e-message-field msg :docid))
            ;; decrypt (or not), based on `mu4e-decryption-policy'.
            (decrypt
             (and (member 'encrypted (mu4e-message-field msg :flags))
                  (if (eq mu4e-decryption-policy 'ask)
                      (yes-or-no-p (mu4e-format "Decrypt message?")) ; TODO: Never ask?
                    mu4e-decryption-policy))))
        (mu4e~proc-view docid mu4e-view-show-images decrypt)))))

;;;###autoload
(defun mu4e-conversation ()
  (interactive)
  (unless (eq major-mode 'mu4e-headers-mode)
    (mu4e-error "Must be in mu4e-headers-mode (%S)" major-mode))
  (setq mu4e-conversation--current-message (mu4e-message-at-point))
  (unless mu4e-conversation--current-message
    (mu4e-warn "No message at point"))
  (setq mu4e-conversation--thread-headers nil)
  (advice-add mu4e-header-func :override 'mu4e-conversation-header-handler)
  (advice-add mu4e-erase-func :override 'mu4e-conversation-erase-handler)
  (advice-add mu4e-found-func :override 'mu4e-conversation-found-handler)
  (mu4e~proc-find
   (funcall mu4e-query-rewrite-function
            (format "msgid:%s" (mu4e-message-field (mu4e-message-at-point) :message-id)))
   'show-threads
   :date
   'ascending
   (not 'limited)
   'skip-duplicates
   'include-related))

(provide 'mu4e-conversation)
;;; mu4e-conversation.el ends here
