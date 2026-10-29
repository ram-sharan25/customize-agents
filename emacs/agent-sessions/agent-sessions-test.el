;;; agent-sessions-test.el --- Tests for agent-sessions  -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-sessions)

(defun rsr/agent-orchestration-test--message (type subject)
  (list :id (concat "test-" subject) :from "sender" :from-label "sender"
        :type type :subject subject :body "" :files "" :report "" :read nil))

(defmacro rsr/agent-sessions-test--with-temp-db (&rest body)
  "Run BODY with an isolated agent-sessions database."
  (declare (indent 0) (debug t))
  `(let* ((db-file (make-temp-file "agent-sessions-test-"))
          (snapshot-directory
           (make-temp-file "agent-sessions-snapshots-test-" t))
          (rsr/agent-sessions-db-file db-file)
          (rsr/agent-sessions-file-snapshot-directory snapshot-directory)
          (rsr/agent-sessions--db nil)
          (rsr/agent-sessions--shared-files nil)
          (rsr/agent-sessions--shared-paths nil)
          (rsr/agent-sessions--shared-links nil))
     (unwind-protect
         (progn ,@body)
       (when (sqlitep rsr/agent-sessions--db)
         (sqlite-close rsr/agent-sessions--db))
       (dolist (path (list db-file (concat db-file "-wal")
                           (concat db-file "-shm")))
         (when (file-exists-p path)
           (delete-file path)))
       (delete-directory snapshot-directory t))))

(ert-deftest rsr/agent-hook-routes-stale-daemon-id-to-unresolved-terminal ()
  (rsr/agent-sessions-test--with-temp-db
   (let* ((directory (make-temp-file "agent-hook-worktree-" t))
          (target (generate-new-buffer " *agent-hook-target*"))
          (other (generate-new-buffer " *agent-hook-other*"))
          (payload-file (make-temp-file "agent-hook-payload-"))
          (rsr/agent-session-id->buffer (make-hash-table :test 'equal))
          (rsr/agent-sessions (make-hash-table :test 'equal))
          (rsr/agent-session-notify-on-attention nil)
          logged)
     (unwind-protect
         (progn
           (with-current-buffer target
             (setq-local rsr/agent-session-id "actual-terminal")
             (setq default-directory (file-name-as-directory directory)))
           (with-current-buffer other
             (setq-local rsr/agent-session-id "other-terminal")
             (setq default-directory (file-name-as-directory directory)))
           (puthash "actual-terminal" target rsr/agent-session-id->buffer)
           (puthash "other-terminal" other rsr/agent-session-id->buffer)
           ;; A terminal in the same worktree already owned by another thread
           ;; must not make routing ambiguous.
           (puthash "other-terminal"
                    (list :buffer other :agent-type "codex"
                          :agent-session-id "other-thread")
                    rsr/agent-sessions)
           (with-temp-file payload-file
             (insert
              (json-serialize
               (let ((payload (make-hash-table :test 'equal)))
                 (puthash "hook_event_name" "Stop" payload)
                 (puthash "session_id" "actual-thread" payload)
                 (puthash "cwd" directory payload)
                 payload))))
           (cl-letf (((symbol-function 'rsr/agent-sessions--foreground-command)
                      (lambda (buf)
			(and (eq buf target) "codex")))
                     ((symbol-function 'rsr/agent-session--repo-info)
                      (lambda (_)
			(list :repo "repo" :repo-root directory
                              :worktree "worktree"
                              :worktree-path directory)))
                     ((symbol-function 'rsr/agent-sessions--log-update)
                      (lambda (buf type sid)
			(setq logged (list buf type sid))))
                     ((symbol-function 'rsr/agent-orchestration--hydrate) #'ignore)
                     ((symbol-function 'rsr/agent-orchestration-deliver) #'ignore)
                     ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                      #'ignore))
             ;; The inherited daemon id no longer names any live terminal.
             (rsr/agent-hook-notify "stale-terminal" "codex" payload-file))
           (let ((session (gethash "actual-terminal" rsr/agent-sessions)))
             (should (equal "actual-thread"
                            (plist-get session :agent-session-id)))
             (should (eq target (plist-get session :buffer)))
             (should (eq 'needs-attention (plist-get session :status))))
           (should-not (gethash "stale-terminal" rsr/agent-sessions))
           (should (equal (list target "codex" "actual-thread") logged)))
       (when (file-exists-p payload-file)
         (delete-file payload-file))
       (kill-buffer target)
       (kill-buffer other)
       (delete-directory directory t)))))

(ert-deftest rsr/agent-sessions-share-file-prefers-durable-agent-id ()
  (let* ((source (make-temp-file "agent-share-routing-"))
         (target-buffer (generate-new-buffer " *agent-share-target*"))
         (wrong-buffer (generate-new-buffer " *agent-share-wrong*"))
         (target-session (list :buffer target-buffer
                               :agent-session-id "target-thread"))
         (wrong-session (list :buffer wrong-buffer
                              :agent-session-id "wrong-thread"))
         (rsr/agent-sessions (make-hash-table :test 'equal))
         shared-with)
    (unwind-protect
        (progn
          ;; The daemon's inherited terminal id is live, but belongs to a
          ;; different session.  The durable agent id must win.
          (puthash "actual-terminal" target-session rsr/agent-sessions)
          (puthash "stale-terminal" wrong-session rsr/agent-sessions)
          (cl-letf (((symbol-function 'rsr/agent-sessions--share-file)
                     (lambda (session _path _label)
                       (setq shared-with session)))
                    ((symbol-function
                      'rsr/agent-sessions--revert-shared-file-buffer)
                     #'ignore)
                    ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should
             (string-prefix-p
              "Shared "
              (rsr/agent-sessions-share-file
               "stale-terminal" source "handoff" "target-thread")))
            (should (eq shared-with target-session))
            (setq shared-with nil)
            (should
             (equal
              "No Emacs agent session registered for agent id missing-thread"
              (rsr/agent-sessions-share-file
               "stale-terminal" source "handoff" "missing-thread")))
            (should-not shared-with)))
      (delete-file source)
      (kill-buffer target-buffer)
      (kill-buffer wrong-buffer))))

(ert-deftest rsr/agent-sessions-emacs-share-passes-codex-thread-id ()
  (let* ((directory (make-temp-file "agent-share-cli-" t))
         (source (expand-file-name "handoff.md" directory))
         (capture (expand-file-name "expression" directory))
         (fake-client (expand-file-name "emacsclient" directory))
         (script (expand-file-name "bin/emacs-share"
                                   (file-name-directory
                                    (locate-library "agent-sessions"))))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (with-temp-file source (insert "handoff\n"))
          (with-temp-file fake-client
            (insert "#!/bin/sh\n"
                    "printf '%s' \"$2\" > \"$EMACS_SHARE_TEST_CAPTURE\"\n"
                    "printf '\"Shared test\"\\n'\n"))
          (set-file-modes fake-client #o755)
          (setenv "PATH" (concat directory path-separator (getenv "PATH")))
          (setenv "EMACS_AGENT_SESSION_ID" "stale-terminal")
          (setenv "CODEX_SESSION_ID" "older-codex-id")
          (setenv "CODEX_THREAD_ID" "current-thread")
          (setenv "EMACS_SHARE_TEST_CAPTURE" capture)
          (should (= 0 (call-process script nil nil nil "file" source)))
          (let ((expression (with-temp-buffer
                              (insert-file-contents capture)
                              (buffer-string))))
            (should (string-match-p
                     (concat (regexp-quote
                              "handoff.md\" \"\" \"current-thread\")")
                             "\\'")
                     expression))
            (should-not (string-match-p "older-codex-id" expression))))
      (delete-directory directory t))))

(ert-deftest rsr/agent-sessions-session-row-omits-raw-hook-event ()
  (with-temp-buffer
    (rsr/agent-sessions-mode)
    (let ((inhibit-read-only t)
          (rsr/agent-sessions--row-status nil)
          (entry (list :id "terminal"
                       :title "Investigate the issue"
                       :session (list :agent-type "codex"
                                      :status 'running
                                      :last-event "PreToolUse"))))
      (cl-letf (((symbol-function 'rsr/agent-sessions--session-state)
                 (lambda (_) nil))
                ((symbol-function 'rsr/agent-orchestration--row-badge)
                 (lambda (_) ""))
                ((symbol-function 'rsr/agent-sessions--insert-note) #'ignore)
                ((symbol-function 'rsr/agent-sessions--insert-links) #'ignore)
                ((symbol-function 'rsr/agent-sessions--insert-files) #'ignore))
        (rsr/agent-sessions--insert-session entry)
        (should (string-match-p "running" (buffer-string)))
        (should (string-match-p "Investigate the issue" (buffer-string)))
        (should-not (string-match-p "PreToolUse" (buffer-string)))))))

(ert-deftest rsr/agent-orchestration-status-alone-does-not-steer-running-codex ()
  (let* ((id "terminal")
         (message (rsr/agent-orchestration-test--message "status" "progress"))
         (session (list :status 'running :agent-type "codex"
                        :agent-session-id "thread"))
         (rsr/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed)
    (puthash id (list message) rsr/agent-orchestration--mail)
    (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'rsr/agent-orchestration--codex-queue)
               (lambda (_ messages) (setq queued messages) t))
              ((symbol-function 'rsr/agent-orchestration--consume)
               (lambda (messages) (setq consumed messages))))
      (should-not (rsr/agent-orchestration-deliver id))
      (should-not queued)
      (should-not consumed)
      (should-not (plist-get message :read)))))

(ert-deftest rsr/agent-orchestration-actionable-mail-steers-with-earlier-status ()
  (let* ((id "terminal")
         (status (rsr/agent-orchestration-test--message "status" "progress"))
         (question (rsr/agent-orchestration-test--message "question" "decision"))
         (pending (list status question))
         (session (list :status 'running :agent-type 'codex
                        :agent-session-id "thread"))
         (rsr/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed refreshed)
    (puthash id pending rsr/agent-orchestration--mail)
    (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'rsr/agent-orchestration--codex-queue)
               (lambda (_ messages) (setq queued messages) t))
              ((symbol-function 'rsr/agent-orchestration--consume)
               (lambda (messages) (setq consumed messages)))
              ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
               (lambda () (setq refreshed t))))
      (should (eq 'queued (rsr/agent-orchestration-deliver id)))
      (should (equal pending queued))
      (should (equal pending consumed))
      (should refreshed))))

(ert-deftest rsr/agent-orchestration-failed-native-queue-leaves-mail-unread ()
  (let* ((id "terminal")
         (question (rsr/agent-orchestration-test--message "question" "decision"))
         (session (list :status 'running :agent-type "codex"
                        :agent-session-id "thread"))
         (rsr/agent-orchestration--mail (make-hash-table :test 'equal))
         consumed)
    (puthash id (list question) rsr/agent-orchestration--mail)
    (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'rsr/agent-orchestration--codex-queue)
               (lambda (&rest _) nil))
              ((symbol-function 'rsr/agent-orchestration--consume)
               (lambda (messages) (setq consumed messages))))
      (should-not (rsr/agent-orchestration-deliver id))
      (should-not consumed)
      (should-not (plist-get question :read)))))

(ert-deftest rsr/agent-orchestration-generic-idle-delivery-still-pastes-all-mail ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *agent-delivery-test*"))
         (message (rsr/agent-orchestration-test--message "status" "progress"))
         (session (list :status 'stopped :agent-type "other" :buffer buffer))
         (rsr/agent-orchestration--mail (make-hash-table :test 'equal))
         pasted consumed)
    (unwind-protect
        (progn
          (puthash id (list message) rsr/agent-orchestration--mail)
          (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'rsr/agent-orchestration--receptive-p)
                     (lambda (_) t))
                    ((symbol-function 'rsr/agent-orchestration--paste)
                     (lambda (_ text) (setq pasted text)))
                    ((symbol-function 'rsr/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'delivered (rsr/agent-orchestration-deliver id)))
            (should (equal (list message) consumed))
            (should (string-match-p "while you were idle" pasted))))
      (kill-buffer buffer))))

(ert-deftest rsr/agent-orchestration-status-mail-queues-at-empty-running-claude ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *claude-delivery-test*"))
         (message (rsr/agent-orchestration-test--message "status" "progress"))
         (session (list :status 'running :agent-type "claude" :buffer buffer))
         (rsr/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "────────────────\n❯\u00a0\n────────────────\n  Opus"))
          (puthash id (list message) rsr/agent-orchestration--mail)
          (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'rsr/agent-sessions--foreground-command)
                     (lambda (_) "claude"))
                    ((symbol-function 'rsr/agent-orchestration--claude-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'rsr/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'queued (rsr/agent-orchestration-deliver id)))
            (should (equal (list message) queued))
            (should (equal (list message) consumed))))
      (kill-buffer buffer))))

(ert-deftest rsr/agent-orchestration-actionable-mail-queues-after-retained-claude-prompt ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *claude-delivery-test*"))
         (message (rsr/agent-orchestration-test--message "answer" "decision"))
         (session (list :status 'running :agent-type 'claude :buffer buffer
                        :submitted-prompt "previous request"))
         (rsr/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "────────────────\n❯\u00a0previous request\n"
                    "────────────────\n  Opus"))
          (puthash id (list message) rsr/agent-orchestration--mail)
          (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'rsr/agent-sessions--foreground-command)
                     (lambda (_) "claude"))
                    ((symbol-function 'rsr/agent-orchestration--claude-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'rsr/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'queued (rsr/agent-orchestration-deliver id)))
            (should (equal (list message) queued))
            (should (equal (list message) consumed))))
      (kill-buffer buffer))))

(ert-deftest rsr/agent-orchestration-claude-draft-withholds-actionable-mail ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *claude-draft-delivery-test*"))
         (message (rsr/agent-orchestration-test--message "answer" "decision"))
         (session (list :status 'stopped :agent-type 'claude :buffer buffer))
         (rsr/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "────────────────\n❯\u00a0my unfinished message\n"
                    "────────────────\n  Opus"))
          (puthash id (list message) rsr/agent-orchestration--mail)
          (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'rsr/agent-sessions--foreground-command)
                     (lambda (_) "claude"))
                    ((symbol-function 'rsr/agent-orchestration--claude-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'rsr/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages))))
            (should-not (rsr/agent-orchestration-deliver id))
            (should-not queued)
            (should-not consumed)
            (should-not (plist-get message :read))))
      (kill-buffer buffer))))

(ert-deftest rsr/agent-orchestration-claude-submit-releases-withheld-mail ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *claude-submit-delivery-test*"))
         (message (rsr/agent-orchestration-test--message "status" "progress"))
         (session (list :status 'running :agent-type 'claude :buffer buffer))
         (rsr/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed)
    (unwind-protect
        (progn
          ;; Keep the old draft visible to prove the hook, rather than a
          ;; screen redraw race, is the authority that it was submitted.
          (with-current-buffer buffer
            (insert "────────────────\n❯\u00a0my submitted message\n"
                    "────────────────\n  Opus"))
          (puthash id (list message) rsr/agent-orchestration--mail)
          (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'rsr/agent-sessions--foreground-command)
                     (lambda (_) "claude"))
                    ((symbol-function 'rsr/agent-orchestration--claude-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'rsr/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'queued (rsr/agent-orchestration-deliver id t)))
            (should (equal (list message) queued))
            (should (equal (list message) consumed))))
      (kill-buffer buffer))))

(ert-deftest rsr/agent-orchestration-claude-composer-detection-is-conservative ()
  (let* ((buffer (generate-new-buffer " *claude-composer-test*"))
         (session (list :agent-type "claude" :buffer buffer)))
    (unwind-protect
        (with-current-buffer buffer
          (insert "────────────────\n❯\u00a0\n────────────────\n  Opus")
          (should (rsr/agent-orchestration--claude-receptive-composer-p session))
          (erase-buffer)
          (insert "────────────────\n❯\u00a0first line\n  wrapped line\n"
                  "────────────────\n  Opus")
          (should-not
           (rsr/agent-orchestration--claude-receptive-composer-p session))
          ;; Claude can retain the submitted prompt in the composer after the
          ;; hook fires.  Visual hard wrapping must not turn that into a draft.
          (setq session
                (plist-put session :submitted-prompt "first line wrapped line"))
          (should (rsr/agent-orchestration--claude-receptive-composer-p session))
          (erase-buffer)
          (insert "────────────────\n❯\u00a0a genuinely new draft\n"
                  "────────────────\n  Opus")
          (should-not
           (rsr/agent-orchestration--claude-receptive-composer-p session))
          (erase-buffer)
          (insert "────────────────\n❯\u00a0")
          (let ((start (point)))
            (insert "suggested completion")
            (add-text-properties
             start (point)
             '(font-lock-face (:inherit (eat-term-faint eat-term-font-0)))))
          (insert "\n────────────────\n  Opus")
          (should (rsr/agent-orchestration--claude-receptive-composer-p session))
          (erase-buffer)
          (insert "────────────────\n❯\u00a0typed prefix ")
          (let ((start (point)))
            (insert "suggested remainder")
            (add-text-properties
             start (point)
             '(font-lock-face (:inherit (eat-term-faint eat-term-font-0)))))
          (insert "\n────────────────\n  Opus")
          (should-not
           (rsr/agent-orchestration--claude-receptive-composer-p session))
          (erase-buffer)
          (insert "Claude output without a recognizable composer")
          (should-not
           (rsr/agent-orchestration--claude-receptive-composer-p session)))
      (kill-buffer buffer))))

(ert-deftest rsr/agent-orchestration-claude-queue-only-pastes-and-submits ()
  (let* ((buffer (generate-new-buffer " *claude-queue-test*"))
         (session (list :agent-type "claude" :buffer buffer))
         (message (rsr/agent-orchestration-test--message "answer" "result"))
         events)
    (unwind-protect
        (cl-letf (((symbol-function 'rsr/agent-orchestration--terminal-input)
                   (lambda (_ input) (push (list 'input input) events)))
                  ((symbol-function 'rsr/agent-sessions--terminal-paste)
                   (lambda (_ text) (push (list 'paste text) events)))
                  ((symbol-function 'run-at-time)
                   (lambda (_ _ function &rest args) (apply function args))))
          (should (rsr/agent-orchestration--claude-queue session (list message)))
          (setq events (nreverse events))
          (should (equal (mapcar #'car events) '(paste input)))
          (should (equal (cadr (nth 1 events))
                         rsr/agent-orchestration-claude-queue-submit-key))
          (should (string-match-p "Subject: result" (cadr (nth 0 events)))))
      (kill-buffer buffer))))

(ert-deftest rsr/agent-orchestration-idle-codex-uses-native-queue-not-composer ()
  (let* ((id "terminal")
         (message (rsr/agent-orchestration-test--message "status" "progress"))
         (session (list :status 'stopped :agent-type "codex"
                        :agent-session-id "thread"))
         (rsr/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed pasted)
    (puthash id (list message) rsr/agent-orchestration--mail)
    (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'rsr/agent-orchestration--codex-queue)
               (lambda (_ messages) (setq queued messages) t))
              ((symbol-function 'rsr/agent-orchestration--consume)
               (lambda (messages) (setq consumed messages)))
              ((symbol-function 'rsr/agent-orchestration--paste)
               (lambda (&rest _) (setq pasted t)))
              ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
               #'ignore))
      (should (eq 'queued (rsr/agent-orchestration-deliver id)))
      (should (equal (list message) queued))
      (should (equal (list message) consumed))
      (should-not pasted))))

(ert-deftest rsr/agent-orchestration-interrupted-codex-empty-prompt-delivers-directly ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *codex-interrupted-delivery-test*"))
         (message (rsr/agent-orchestration-test--message "answer" "decision"))
         ;; Codex does not fire Stop for an interrupted turn, so this stale
         ;; status is the live failure mode this regression covers.
         (session (list :status 'running :agent-type "codex"
                        :agent-session-id "thread" :buffer buffer))
         (rsr/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed pasted)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "■ Conversation interrupted - tell the model what to do differently.\n"
                    "\n› Ask Codex to do anything\n\n"
                    "  gpt-5.6-sol medium · Context 31% used"))
          (puthash id (list message) rsr/agent-orchestration--mail)
          (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'rsr/agent-orchestration--codex-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'rsr/agent-orchestration--paste)
                     (lambda (_ text) (setq pasted text)))
                    ((symbol-function 'rsr/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'delivered (rsr/agent-orchestration-deliver id)))
            (should (equal (list message) consumed))
            (should (string-match-p "Subject: decision" pasted))
            (should-not queued)))
      (kill-buffer buffer))))

(ert-deftest rsr/agent-orchestration-codex-draft-still-uses-native-queue ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *codex-draft-delivery-test*"))
         (message (rsr/agent-orchestration-test--message "answer" "decision"))
         (session (list :status 'stopped :agent-type "codex"
                        :agent-session-id "thread" :buffer buffer))
         (rsr/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed pasted)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "› Keep this human draft intact\n\n"
                    "  gpt-5.6-sol medium · Context 31% used"))
          (puthash id (list message) rsr/agent-orchestration--mail)
          (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'rsr/agent-orchestration--codex-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'rsr/agent-orchestration--paste)
                     (lambda (&rest _) (setq pasted t)))
                    ((symbol-function 'rsr/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'queued (rsr/agent-orchestration-deliver id)))
            (should (equal (list message) queued))
            (should (equal (list message) consumed))
            (should-not pasted)))
      (kill-buffer buffer))))

(ert-deftest rsr/agent-orchestration-native-codex-queue-uses-durable-thread-id ()
  (let ((session (list :agent-session-id "thread-uuid"))
        (message (rsr/agent-orchestration-test--message "answer" "result"))
        invocation)
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/bin/codex"))
              ((symbol-function 'rsr/agent-orchestration--call-with-timeout)
               (lambda (program args timeout)
                 (setq invocation (list program args timeout))
                 0)))
      (should (rsr/agent-orchestration--codex-queue session (list message)))
      (should (equal (car invocation) "/bin/codex"))
      (should (equal (seq-take (cadr invocation) 4)
                     '("queue" "--thread" "thread-uuid" "--message")))
      (should (string-match-p "Subject: result" (nth 4 (cadr invocation))))
      (should (= (nth 2 invocation)
                 rsr/agent-orchestration--native-queue-timeout)))))

(ert-deftest rsr/agent-sessions-show-file-diff-opens-latest-commit-then-reads ()
  (let ((path "/repo/docs/plan.md")
        events)
    (cl-letf (((symbol-function 'rsr/agent-sessions--file-at-point)
               (lambda () (list 'session path (list :path path))))
              ((symbol-function 'magit-toplevel)
               (lambda (_) "/repo/"))
              ((symbol-function 'magit-git-string)
               (lambda (&rest args)
                 (push (list 'git default-directory args) events)
                 "abc123"))
              ((symbol-function 'magit-show-commit--arguments)
               (lambda () '(("--stat") nil)))
              ((symbol-function 'magit-show-commit)
               (lambda (commit args files &optional _module)
                 (push (list 'show default-directory commit args files) events)))
              ((symbol-function 'rsr/agent-sessions--set-visited)
               (lambda (match-fn visitedp)
                 (push (list 'visited
                             (funcall match-fn (list :path path))
                             visitedp)
                       events)
                 t))
              ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
               (lambda () (push '(refresh) events))))
      (rsr/agent-sessions-show-file-diff)
      (should
       (equal (nreverse events)
              '((git "/repo/"
                     ("log" "-1" "--format=%H" "--follow" "--"
                      "docs/plan.md"))
                (show "/repo/" "abc123" ("--stat") ("docs/plan.md"))
                (visited t t)
                (refresh)))))))

(ert-deftest rsr/agent-sessions-show-file-diff-keeps-uncommitted-file-unread ()
  (let ((path "/repo/docs/plan.md")
        shown visited)
    (cl-letf (((symbol-function 'rsr/agent-sessions--file-at-point)
               (lambda () (list 'session path (list :path path))))
              ((symbol-function 'magit-toplevel)
               (lambda (_) "/repo/"))
              ((symbol-function 'magit-git-string)
               (lambda (&rest _) nil))
              ((symbol-function 'magit-show-commit)
               (lambda (&rest _) (setq shown t)))
              ((symbol-function 'rsr/agent-sessions--set-visited)
               (lambda (&rest _) (setq visited t))))
      (should-error (rsr/agent-sessions-show-file-diff) :type 'user-error)
      (should-not shown)
      (should-not visited))))

(defun rsr/agent-sessions-test--write-file (path contents)
  "Replace PATH with CONTENTS for a shared-file test."
  (with-temp-file path
    (insert contents)))

(ert-deftest rsr/agent-sessions-share-file-keeps-latest-two-submissions ()
  (rsr/agent-sessions-test--with-temp-db
    (let* ((source (make-temp-file "agent-shared-file-" nil ".md"))
           (session (list :agent-session-id "thread-1"))
           (key '("session" "thread-1")))
      (unwind-protect
          (progn
            (rsr/agent-sessions-test--write-file source "first\n")
            (let ((first (rsr/agent-sessions--share-file session source nil)))
              (should (equal source (plist-get first :path))))
            (let ((snapshot (rsr/agent-sessions--file-snapshot-row
                             (list key) source)))
              (should-not (plist-get snapshot :previous-path))
              (should (equal "first\n"
                             (with-temp-buffer
                               (insert-file-contents
                                (plist-get snapshot :current-path))
                               (buffer-string)))))
            (rsr/agent-sessions-test--write-file source "second\n")
            (rsr/agent-sessions--share-file session source nil)
            (rsr/agent-sessions-test--write-file source "third\n")
            (rsr/agent-sessions--share-file session source nil)
            (let ((snapshot (rsr/agent-sessions--file-snapshot-row
                             (list key) source)))
              (should (equal "second\n"
                             (with-temp-buffer
                               (insert-file-contents
                                (plist-get snapshot :previous-path))
                               (buffer-string))))
              (should (equal "third\n"
                             (with-temp-buffer
                               (insert-file-contents
                                (plist-get snapshot :current-path))
                               (buffer-string)))))
            (should
             (equal '((1))
                    (sqlite-select
                     (rsr/agent-sessions--db)
                     "SELECT COUNT(*) FROM shared_file_snapshots"))))
        (delete-file source)))))

(ert-deftest rsr/agent-sessions-file-snapshots-follow-durable-session-id ()
  (rsr/agent-sessions-test--with-temp-db
    (let ((source (make-temp-file "agent-shared-file-"))
          (buffer (generate-new-buffer "agent-snapshot-terminal")))
      (unwind-protect
          (let ((terminal-session (list :buffer buffer)))
            (rsr/agent-sessions-test--write-file source "before id\n")
            (rsr/agent-sessions--share-file terminal-session source nil)
            (rsr/agent-sessions-test--write-file source "after id\n")
            (let* ((durable-session
                    (list :buffer buffer :agent-session-id "thread-2"))
                   (durable-key '("session" "thread-2")))
              (rsr/agent-sessions--share-file durable-session source nil)
              (let ((snapshot (rsr/agent-sessions--file-snapshot-row
                               (list durable-key) source)))
                (should (equal "before id\n"
                               (with-temp-buffer
                                 (insert-file-contents
                                  (plist-get snapshot :previous-path))
                                 (buffer-string))))
                (should (equal "after id\n"
                               (with-temp-buffer
                                 (insert-file-contents
                                  (plist-get snapshot :current-path))
                                 (buffer-string)))))
              (should
               (equal '((0))
                      (sqlite-select
                       (rsr/agent-sessions--db)
                       "SELECT COUNT(*) FROM shared_file_snapshots
                         WHERE kind = 'session' AND key = ?"
                       (list (buffer-name buffer)))))))
        (kill-buffer buffer)
        (delete-file source)))))

(ert-deftest rsr/agent-sessions-show-submission-diff-compares-cache-then-reads ()
  (let* ((path "/outside-git/plan.md")
         (previous (make-temp-file "previous--plan-"))
         (current (make-temp-file "current--plan-"))
         (session (list :agent-session-id "thread-1"))
         (buffer (get-buffer-create "*Agent submission diff: plan.md*"))
         events)
    (unwind-protect
        (cl-letf (((symbol-function 'rsr/agent-sessions--file-at-point)
                   (lambda () (list session path (list :path path))))
                  ((symbol-function 'rsr/agent-sessions--file-snapshot-row)
                   (lambda (keys candidate)
                     (push (list 'snapshot keys candidate) events)
                     (list :previous-path previous :current-path current)))
                  ((symbol-function 'diff-no-select)
                   (lambda (old new switches no-async destination)
                     (push (list 'diff old new switches no-async destination)
                           events)
                     buffer))
                  ((symbol-function 'rsr/agent-sessions--set-visited)
                   (lambda (match-fn visitedp)
                     (push (list 'visited
                                 (funcall match-fn (list :path path))
                                 visitedp)
                           events)
                     t))
                  ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                   (lambda () (push '(refresh) events)))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (shown) (push (list 'pop shown) events))))
          (rsr/agent-sessions-show-file-submission-diff)
          (should
           (equal
            (nreverse events)
            `((snapshot (("session" "thread-1")) ,path)
              (diff ,previous ,current "-u" t ,buffer)
              (visited t t)
              (refresh)
              (pop ,buffer)))))
      (kill-buffer buffer)
      (delete-file previous)
      (delete-file current))))

(ert-deftest rsr/agent-sessions-show-submission-diff-needs-two-versions ()
  (let ((path "/outside-git/plan.md")
        visited)
    (cl-letf (((symbol-function 'rsr/agent-sessions--file-at-point)
               (lambda ()
                 (list (list :agent-session-id "thread-1") path
                       (list :path path))))
              ((symbol-function 'rsr/agent-sessions--file-snapshot-row)
               (lambda (&rest _)
                 (list :current-path "/cache/current--plan.md")))
              ((symbol-function 'rsr/agent-sessions--set-visited)
               (lambda (&rest _) (setq visited t))))
      (should-error (rsr/agent-sessions-show-file-submission-diff)
                    :type 'user-error)
      (should-not visited))))

(ert-deftest rsr/agent-sessions-capital-d-initializes-missing-snapshot ()
  (rsr/agent-sessions-test--with-temp-db
    (let* ((path (make-temp-file "agent-shared-file-"))
           (session (list :agent-session-id "thread-1"))
           (key '("session" "thread-1"))
           visited message-text)
      (unwind-protect
          (progn
            (rsr/agent-sessions-test--write-file path "current contents\n")
            (cl-letf (((symbol-function 'rsr/agent-sessions--file-at-point)
                       (lambda () (list session path (list :path path))))
                      ((symbol-function 'rsr/agent-sessions--set-visited)
                       (lambda (&rest _) (setq visited t)))
                      ((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (setq message-text
                               (apply #'format format-string args)))))
              (rsr/agent-sessions-show-file-submission-diff))
            (let ((snapshot (rsr/agent-sessions--file-snapshot-row
                             (list key) path)))
              (should snapshot)
              (should-not (plist-get snapshot :previous-path))
              (should
               (equal "current contents\n"
                      (with-temp-buffer
                        (insert-file-contents
                         (plist-get snapshot :current-path))
                        (buffer-string)))))
            (should (equal message-text
                           "Saved current file as its first submitted snapshot"))
            (should-not visited))
        (delete-file path)))))

(ert-deftest rsr/agent-sessions-capital-d-is-contextual ()
  (let (action file-at-point)
    (cl-letf (((symbol-function 'rsr/agent-sessions--file-at-point)
               (lambda () file-at-point))
              ((symbol-function 'rsr/agent-sessions-show-file-submission-diff)
               (lambda () (setq action 'diff)))
              ((symbol-function 'rsr/agent-sessions-detach-parent)
               (lambda () (setq action 'detach))))
      (setq file-at-point '(session path file))
      (rsr/agent-sessions-submission-diff-or-detach-parent)
      (should (eq action 'diff))
      (setq action nil file-at-point nil)
      (rsr/agent-sessions-submission-diff-or-detach-parent)
      (should (eq action 'detach)))))

(ert-deftest rsr/agent-sessions-shared-links-allow-multiple-per-kind ()
  (rsr/agent-sessions-test--with-temp-db
    (let* ((session (list :agent-session-id "thread-1"))
           (first (rsr/agent-sessions--share-link
                   session "linear" "https://linear.app/issue/PRO-1" "PRO-1"))
           (shared-at (plist-get first :shared-at)))
      (should-not (plist-get first :visited-at))
      (should (rsr/agent-sessions--set-link-visited
               (lambda (link) (equal (plist-get link :url)
                                     "https://linear.app/issue/PRO-1")) t))
      (let ((same (rsr/agent-sessions--share-link
                   session "linear" "https://linear.app/issue/PRO-1" "PRO-1")))
        (should (plist-get same :visited-at))
        (should (= shared-at (plist-get same :shared-at))))
      (let ((second (rsr/agent-sessions--share-link
                     session "linear" "https://linear.app/issue/PRO-2" "PRO-2")))
        (should-not (plist-get second :visited-at)))
      (rsr/agent-sessions--share-link
       session "pr" "https://github.com/org/repo/pull/1" "PR 1")
      (rsr/agent-sessions--share-link
       session "pr" "https://github.com/org/repo/pull/2" "PR 2")
      (should (= 4 (length (rsr/agent-sessions--session-links session))))
      (with-temp-buffer
        (rsr/agent-sessions-mode)
        (let ((inhibit-read-only t)
              (rsr/agent-sessions--row-status nil))
          (rsr/agent-sessions--insert-links session "  ")
          (dolist (label '("PRO-1" "PRO-2" "PR 1" "PR 2"))
            (should (string-match-p (regexp-quote label) (buffer-string))))))
      (should (equal '((2))
                     (sqlite-select
                      (rsr/agent-sessions--db)
                      "SELECT COUNT(*) FROM shared_links
                        WHERE owner_kind = 'session'
                          AND owner_key = 'thread-1'
                          AND link_kind = 'linear'")))
      (should (rsr/agent-sessions--detach-link
               session "https://linear.app/issue/PRO-2"))
      (should (= 3 (length (rsr/agent-sessions--session-links session))))
      (should (plist-get (car (rsr/agent-sessions--session-links session))
                         :visited-at)))))

(ert-deftest rsr/agent-sessions-shared-links-migrate-old-key ()
  (rsr/agent-sessions-test--with-temp-db
    (let ((db (rsr/agent-sessions--db)))
      (sqlite-execute db "DROP TABLE shared_links")
      (sqlite-execute db "CREATE TABLE shared_links (
        owner_kind TEXT NOT NULL, owner_key TEXT NOT NULL,
        link_kind TEXT NOT NULL, url TEXT NOT NULL, label TEXT,
        shared_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        visited_at INTEGER, PRIMARY KEY (owner_kind, owner_key, link_kind))")
      (sqlite-execute db "INSERT INTO shared_links VALUES
        ('session', 'thread-1', 'linear', 'https://linear.app/issue/PRO-1',
         'PRO-1', 100, 100, 101)")
      (sqlite-execute db "UPDATE meta SET value = '1' WHERE key = 'schema_version'")
      (rsr/agent-sessions--db-migrate db)
      (rsr/agent-sessions--share-link
       (list :agent-session-id "thread-1") "linear"
       "https://linear.app/issue/PRO-2" "PRO-2")
      (should (equal '((2))
                     (sqlite-select db "SELECT COUNT(*) FROM shared_links")))
      (should (equal '((101))
                     (sqlite-select db "SELECT visited_at FROM shared_links
                       WHERE url = 'https://linear.app/issue/PRO-1'"))))))

(ert-deftest rsr/agent-sessions-reap-spares-live-emacs ()
  (rsr/agent-sessions-test--with-temp-db
    (let ((db (rsr/agent-sessions--db))
          (live (format "%d-1" (emacs-pid)))
          ;; Above any pid the kernel hands out, so never a running process.
          (dead "999999999-1"))
      (dolist (sid (list live dead))
        (sqlite-execute db "INSERT INTO sessions (emacs_sid, worktree, opened_at)
                            VALUES (?, '/tmp', 100)"
                        (list sid)))
      (rsr/agent-sessions--meta-set db "last_seen" 200)
      ;; What a second Emacs opening the file does: the live one's row must
      ;; stay open, and only the dead one's is closed as a crash.
      (rsr/agent-sessions--db-reap db)
      (should (equal '((nil nil))
                     (sqlite-select db "SELECT closed_at, close_reason
                                          FROM sessions WHERE emacs_sid = ?"
                                    (list live))))
      (should (equal '((200 "crash"))
                     (sqlite-select db "SELECT closed_at, close_reason
                                          FROM sessions WHERE emacs_sid = ?"
                                    (list dead)))))))

(ert-deftest rsr/agent-sessions-mark-read-advances-within-session ()
  (with-temp-buffer
    (rsr/agent-sessions-mode)
    (let ((inhibit-read-only t)
          (file (list :path "/tmp/agent-file-1" :visited-at nil)))
      (magit-insert-section (rsr/agent-sessions-root)
        (magit-insert-section (rsr/agent-session-row "session-1")
          (magit-insert-heading "session 1\n")
          (magit-insert-section (rsr/agent-session-file "/tmp/agent-file-1")
            (magit-insert-heading "file 1\n"))
          (magit-insert-section (rsr/agent-session-file "/tmp/agent-file-2")
            (magit-insert-heading "file 2\n")))
        (magit-insert-section (rsr/agent-session-row "session-2")
          (magit-insert-heading "session 2\n")
          (magit-insert-section (rsr/agent-session-file "/tmp/agent-file-3")
            (magit-insert-heading "file 3\n"))))
      (goto-char (point-min))
      (search-forward "file 1")
      (cl-letf (((symbol-function 'rsr/agent-sessions--file-at-point)
                 (lambda () (list 'session "/tmp/agent-file-1" file)))
                ((symbol-function 'rsr/agent-sessions--set-visited)
                 (lambda (_match visited)
                   (plist-put file :visited-at (and visited 1))
                   t))
                ((symbol-function 'rsr/agent-sessions--refresh) #'ignore))
        (rsr/agent-sessions-mark-unread)
        (should (equal "/tmp/agent-file-2"
                       (oref (magit-current-section) value)))
        (should (plist-get file :visited-at))
        (should-not (rsr/agent-sessions--next-file-ident-at-point)))
      (should (eq (lookup-key rsr/agent-sessions-mode-map (kbd "m"))
                  (lookup-key rsr/agent-sessions-mode-map (kbd "u")))))))

(ert-deftest rsr/agent-sessions-share-link-validates-kind-and-url ()
  (let ((session (list :agent-session-id "thread-1"))
        refreshed)
    (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
               (lambda () (setq refreshed t))))
      (should (string-prefix-p
               "Unknown link kind"
               (rsr/agent-sessions-share-link
                "terminal" "ticket" "https://example.com/1")))
      (should (string-prefix-p
               "Invalid link URL"
               (rsr/agent-sessions-share-link
                "terminal" "linear" "file:///tmp/issue")))
      (should-not refreshed))))

(ert-deftest rsr/agent-sessions-open-link-marks-read-before-browsing ()
  (let* ((link (list :kind "pr" :url "https://github.com/org/repo/pull/1"))
         events)
    (cl-letf (((symbol-function 'rsr/agent-sessions--link-at-point)
               (lambda () (list 'session "pr" link)))
              ((symbol-function 'rsr/agent-sessions--set-link-visited)
               (lambda (match-fn visitedp)
                 (push (list 'visited (funcall match-fn link) visitedp) events)
                 t))
              ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
               (lambda () (push '(refresh) events)))
              ((symbol-function 'browse-url)
               (lambda (url) (push (list 'browse url) events))))
      (rsr/agent-sessions--open-link-at-point)
      (should
       (equal (nreverse events)
              '((visited t t)
                (refresh)
                (browse "https://github.com/org/repo/pull/1")))))))

(ert-deftest rsr/agent-sessions-linear-issue-id-reads-url ()
  (should (equal "STI-5" (rsr/agent-sessions--linear-issue-id
                          "https://linear.app/still-ness/issue/STI-5")))
  (should (equal "STI-5" (rsr/agent-sessions--linear-issue-id
                          "https://linear.app/issue/sti-5/some-title")))
  (should-not (rsr/agent-sessions--linear-issue-id
               "https://linear.app/still-ness/project/foo")))

(defmacro rsr/agent-sessions-test--with-linear-org (&rest body)
  "Run BODY with `rsr/agent-sessions-linear-org-file' holding STI-5 and STI-7."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "agent-linear" t))
          (rsr/agent-sessions-linear-org-file
           (expand-file-name "linear.org" dir)))
     (unwind-protect
         (progn
           (with-temp-file rsr/agent-sessions-linear-org-file
             (insert "#+title: Linear\n"
                     ;; linear-emacs's multi-line DESCRIPTION breaks the
                     ;; drawer for Org's property parser.
                     "* TODO First\n:PROPERTIES:\n:DESCRIPTION: |\n  line one\n"
                     "  line two\n:ID-LINEAR: STI-5\n:END:\n"
                     "* TODO Second\n:PROPERTIES:\n:ID-LINEAR: STI-7\n:END:\nbody\n"))
           ,@body)
       (let ((buf (find-buffer-visiting rsr/agent-sessions-linear-org-file)))
         (when buf (kill-buffer buf)))
       (delete-directory dir t))))

(ert-deftest rsr/agent-sessions-linear-heading-finds-issue-by-id ()
  (rsr/agent-sessions-test--with-linear-org
    (let ((marker (rsr/agent-sessions--linear-heading
                   "https://linear.app/still-ness/issue/STI-7")))
      (should marker)
      (with-current-buffer (marker-buffer marker)
        (goto-char marker)
        (should (equal "Second" (org-get-heading t t t t)))))
    (let ((marker (rsr/agent-sessions--linear-heading
                   "https://linear.app/still-ness/issue/STI-5")))
      (should marker)
      (with-current-buffer (marker-buffer marker)
        (goto-char marker)
        (should (equal "First" (org-get-heading t t t t)))))
    (should-not (rsr/agent-sessions--linear-heading
                 "https://linear.app/still-ness/issue/STI-9")))
  (let ((rsr/agent-sessions-linear-org-file "/nonexistent/linear.org"))
    (should-not (rsr/agent-sessions--linear-heading
                 "https://linear.app/still-ness/issue/STI-5"))))

(ert-deftest rsr/agent-sessions-linear-keys-route-links ()
  (rsr/agent-sessions-test--with-linear-org
    (let* ((link (list :kind "linear" :url ""))
           (pr (list :kind "pr" :url "https://github.com/org/repo/pull/1"))
           (current link)
           (rsr/agent-sessions-linear-app nil)
           events)
      (cl-letf (((symbol-function 'rsr/agent-sessions--link-at-point)
                 (lambda () (list 'session (plist-get current :url) current)))
                ((symbol-function 'rsr/agent-sessions--set-link-visited)
                 (lambda (&rest _) nil))
                ((symbol-function 'browse-url)
                 (lambda (url) (push (list 'browse url) events)))
                ((symbol-function 'call-process)
                 (lambda (&rest args) (push (cons 'process args) events))))
        (save-window-excursion
          ;; RET on a ticket in the file lands on its heading.
          (plist-put link :url "https://linear.app/still-ness/issue/STI-7")
          (rsr/agent-sessions-jump)
          (should (equal "Second" (org-get-heading t t t t)))
          (should-not events))
        ;; RET on a ticket not in the file: the app, or the browser without it.
        (plist-put link :url "https://linear.app/still-ness/issue/STI-9")
        (rsr/agent-sessions-jump)
        (should (equal (pop events)
                       '(browse "https://linear.app/still-ness/issue/STI-9")))
        (let ((rsr/agent-sessions-linear-app temporary-file-directory)
              (system-type 'darwin))
          (rsr/agent-sessions-jump)
          (should (equal (pop events)
                         (list 'process "open" nil 0 nil "-a"
                               temporary-file-directory
                               "https://linear.app/still-ness/issue/STI-9")))
          ;; V skips the Org file even when the ticket is in it.
          (plist-put link :url "https://linear.app/still-ness/issue/STI-5")
          (rsr/agent-sessions-display-or-browse)
          (should (equal (pop events)
                         (list 'process "open" nil 0 nil "-a"
                               temporary-file-directory
                               "https://linear.app/still-ness/issue/STI-5")))
          ;; Other link kinds still browse.
          (setq current pr)
          (rsr/agent-sessions-jump)
          (should (equal (pop events)
                         '(browse "https://github.com/org/repo/pull/1"))))))))

(ert-deftest rsr/agent-sessions-w-copies-attachment-value ()
  (let ((kill-ring nil)
        (link nil)
        (file nil))
    (cl-letf (((symbol-function 'rsr/agent-sessions--link-at-point)
               (lambda () link))
              ((symbol-function 'rsr/agent-sessions--file-at-point)
               (lambda () file)))
      (setq file '(session "/tmp/shared plan.md" nil))
      (rsr/agent-sessions-copy-attachment)
      (should (equal "/tmp/shared plan.md" (car kill-ring)))
      (setq file nil
            link '(session "https://example.com/pr/1"
                           (:url "https://example.com/pr/1")))
      (rsr/agent-sessions-copy-attachment)
      (should (equal "https://example.com/pr/1" (car kill-ring)))
      (setq link nil)
      (rsr/agent-sessions-copy-attachment)
      (should (equal "https://example.com/pr/1" (car kill-ring))))
    (should (eq (lookup-key rsr/agent-sessions-mode-map (kbd "w"))
                #'rsr/agent-sessions-copy-attachment))))

(ert-deftest rsr/agent-sessions-share-state-sets-and-clears ()
  (let ((session (list :agent-session-id "thread-1"))
        writes refreshes)
    (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'rsr/agent-sessions--state-set)
               (lambda (keys state) (push (list keys state) writes)))
              ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
               (lambda () (setq refreshes (1+ (or refreshes 0))))))
      (should (equal "State: PLAN-REVIEW"
                     (rsr/agent-sessions-share-state "terminal" "PLAN-REVIEW")))
      (should (equal "State cleared"
                     (rsr/agent-sessions-share-state "terminal" "")))
      (should (equal (nreverse writes)
                     (list (list (rsr/agent-sessions--session-note-keys session)
                                 "PLAN-REVIEW")
                           (list (rsr/agent-sessions--session-note-keys session)
                                 nil))))
      (should (= refreshes 2)))))

(ert-deftest rsr/agent-sessions-share-state-refuses-unknown-state ()
  (let ((session (list :agent-session-id "thread-1"))
        written)
    (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'rsr/agent-sessions--state-set)
               (lambda (&rest _) (setq written t)))
              ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
               #'ignore))
      (let ((reply (rsr/agent-sessions-share-state "terminal" "MERGED")))
        (should (string-prefix-p "Unknown state `MERGED'" reply))
        (should (string-match-p "PLAN-REVIEW" reply)))
      (should-not written))))

(ert-deftest rsr/agent-sessions-share-state-without-session ()
  (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-share)
             (lambda (&rest _) nil)))
    (should (string-prefix-p
             "No Emacs terminal registered"
             (rsr/agent-sessions-share-state "terminal" "DONE")))
    (should (string-prefix-p
             "No Emacs agent session registered for agent id thread-1"
             (rsr/agent-sessions-share-state "terminal" "DONE" "thread-1")))))

(ert-deftest rsr/agent-sessions-states-cycle-in-workflow-order ()
  (let ((seen nil) (state nil))
    (dotimes (_ (1+ (length rsr/agent-sessions-states)))
      (setq state (rsr/agent-sessions--next-state state))
      (push state seen))
    (should (equal (nreverse seen)
                   '("TODO" "PLANNING" "PLAN-REVIEW" "IMPLEMENTING"
                     "IMPL-REVIEW" "PR-OPEN" "AUTOFIX" "REVIEW" "DONE"
                     "BLOCKED" "LEARN" nil)))))

(ert-deftest rsr/agent-sessions--pi-session-start-is-not-running ()
  ;; Pi fires session_start when its TUI opens at an idle prompt, so a fresh
  ;; session must land on `stopped', not fall through to the `running' default
  ;; in `rsr/agent-hook-notify' — that is the frozen-running-at-nothing bug.
  (should (eq 'stopped (rsr/agent-session--status-for "pi" "SessionStart")))
  (should (eq 'stopped (rsr/agent-session--status-for "claude" "SessionStart")))
  ;; Codex fires its SessionStart lazily on the first prompt, the same instant
  ;; as UserPromptSubmit — an unordered SessionStart must be able to clobber
  ;; `running', so Codex gets no mapping at all.
  (should (null (rsr/agent-session--status-for "codex" "SessionStart"))))

(ert-deftest rsr/agent-sessions--reconcile-status-demotes-only-provably-idle ()
  (let* ((buffer (generate-new-buffer " *pi-reconcile-test*"))
       (session (list :status 'running :agent-type "pi" :buffer buffer)))
    (unwind-protect
        (cl-letf (((symbol-function 'rsr/agent-sessions--tpgid-readable-p)
                   (lambda (_) t)))
          ;; Nothing in the foreground: the shell owns the pty, so pi cannot be
          ;; mid-turn — the killed-mid-turn freeze must read as stopped.
          (cl-letf (((symbol-function 'rsr/agent-sessions--foreground-command)
                     (lambda (_) nil)))
            (let ((reconciled (rsr/agent-sessions--reconcile-status session buffer)))
              (should (eq 'stopped (plist-get reconciled :status)))
              ;; Display-time only: the registry plist must survive untouched,
              ;; the way `rsr/agent-sessions--unread-status' works.
              (should (eq 'running (plist-get session :status)))))
          ;; pi idling at its own prompt still holds the foreground with its
          ;; TUI — no demotion; the SessionStart mapping covers that case.
          (cl-letf (((symbol-function 'rsr/agent-sessions--foreground-command)
                     (lambda (_) "pi")))
            (should (eq 'running
                        (plist-get (rsr/agent-sessions--reconcile-status
                                    session buffer)
                                   :status)))))
      (kill-buffer buffer))))

(ert-deftest rsr/agent-sessions--reconcile-status-needs-tpgid-to-demote ()
  ;; On a platform whose process-attributes omits tpgid, a nil foreground says
  ;; "unknown", not "shell in front" — running must survive untouched.
  (let* ((buffer (generate-new-buffer " *pi-reconcile-tpgid-test*"))
       (session (list :status 'running :agent-type "pi" :buffer buffer)))
    (unwind-protect
        (cl-letf (((symbol-function 'rsr/agent-sessions--tpgid-readable-p)
                   (lambda (_) nil))
                  ((symbol-function 'rsr/agent-sessions--foreground-command)
                   (lambda (_) nil)))
          (should (eq 'running
                      (plist-get (rsr/agent-sessions--reconcile-status
                                  session buffer)
                                 :status))))
      (kill-buffer buffer))))

(ert-deftest rsr/agent-sessions-never-saved-claude-session-is-detected ()
  "A Claude session with no transcript cannot be resumed; one with one can."
  (let* ((dir (make-temp-file "claude-config-" t))
         (process-environment (cons (format "CLAUDE_CONFIG_DIR=%s" dir)
                                    process-environment)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "projects/-some-repo" dir) t)
          (write-region "" nil (expand-file-name "projects/-some-repo/used.jsonl" dir))
          (should (rsr/agent-sessions--never-saved-p
                   '(:agent-type "claude" :agent-sid "unused")))
          (should-not (rsr/agent-sessions--never-saved-p
                       '(:agent-type "claude" :agent-sid "used")))
          ;; Only Claude defers its transcript; other agents are left alone.
          (should-not (rsr/agent-sessions--never-saved-p
                       '(:agent-type "codex" :agent-sid "unused"))))
      (delete-directory dir t))))

(ert-deftest rsr/agent-sessions-switch-project-prompt-works-on-this-emacs ()
  "RET on a heading builds the project menu prompt without a void function.
Emacs 29 names the prompt builder `project--keymap-prompt'; 30 renamed it
`project--menu-prompt'."
  (let (prompt)
    (cl-letf (((symbol-function 'read-key-sequence)
               (lambda (p &rest _) (setq prompt p) "\C-g")))
      (should (eq (rsr/agent-sessions--switch-project-read-command) #'ignore)))
    (should (string-prefix-p "Choose: " prompt))))

(ert-deftest rsr/agent-sessions-dress-keeps-part-faces ()
  "A part's own face wins over the line face; a highlight's color wins over it."
  (let ((line (concat "a" (propertize "b" 'font-lock-face 'part))))
    (let ((plain (rsr/agent-sessions--dress line 'default)))
      (should (eq (get-text-property 0 'font-lock-face plain) 'default))
      (should (equal (get-text-property 1 'font-lock-face plain) '(part default))))
    (let ((hot (rsr/agent-sessions--dress line 'rsr/agent-session-needs-attention)))
      (should (equal (get-text-property 1 'font-lock-face hot)
                     '(rsr/agent-session-needs-attention part))))
    (should-not (get-text-property 1 'font-lock-face "b"))))

(ert-deftest rsr/agent-sessions-icon-off-or-unknown ()
  (let ((rsr/agent-sessions-icons nil))
    (should (equal (rsr/agent-sessions--icon 'repo) "")))
  (let ((rsr/agent-sessions-icons t))
    (when (require 'nerd-icons nil t)
      ;; An agent the table does not list falls back to the generic agent icon.
      (should (equal (rsr/agent-sessions--icon "someagent")
                     (rsr/agent-sessions--icon 'agent)))
      (should (plist-get (car (get-text-property 0 'font-lock-face
                                                 (rsr/agent-sessions--icon 'repo)))
                         :family)))))

(provide 'agent-sessions-test)
;;; agent-sessions-test.el ends here
