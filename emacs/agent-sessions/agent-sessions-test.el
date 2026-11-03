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

(defun rsr/agent-hook-test--swap (old-event foreground)
  "Notify a claude event into a terminal whose pi last sent OLD-EVENT.
FOREGROUND is the program the terminal reports running.  Return the
terminal's registry entry afterwards."
  (rsr/agent-sessions-test--with-temp-db
    (let* ((directory (make-temp-file "agent-hook-swap-" t))
           (term (generate-new-buffer " *agent-hook-swap*"))
           (payload-file (make-temp-file "agent-hook-payload-"))
           (rsr/agent-session-id->buffer (make-hash-table :test 'equal))
           (rsr/agent-sessions (make-hash-table :test 'equal))
           (rsr/agent-session-notify-on-attention nil))
      (unwind-protect
          (progn
            (with-current-buffer term
              (setq-local rsr/agent-session-id "term")
              (setq default-directory (file-name-as-directory directory)))
            (puthash "term" term rsr/agent-session-id->buffer)
            (puthash "term" (list :buffer term :agent-type "pi"
                                  :agent-session-id "pi-sid"
                                  :last-event old-event :status 'stopped
                                  :branched-from '("parent-sid" . "parent")
                                  :submitted-prompt "old prompt")
                     rsr/agent-sessions)
            (with-temp-file payload-file
              (insert (json-serialize
                       (let ((payload (make-hash-table :test 'equal)))
                         (puthash "hook_event_name" "SessionStart" payload)
                         (puthash "session_id" "claude-sid" payload)
                         (puthash "cwd" directory payload)
                         payload))))
            (cl-letf (((symbol-function 'rsr/agent-sessions--foreground-command)
                       (lambda (_) foreground))
                      ((symbol-function 'rsr/agent-session--repo-info)
                       (lambda (_) (list :repo "repo" :repo-root directory
                                         :worktree-path directory)))
                      ((symbol-function 'rsr/agent-sessions--detect-parent) #'ignore)
                      ((symbol-function 'rsr/agent-sessions--log-update) #'ignore)
                      ((symbol-function 'rsr/agent-orchestration--hydrate) #'ignore)
                      ((symbol-function 'rsr/agent-orchestration-deliver) #'ignore)
                      ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                       #'ignore))
              (rsr/agent-hook-notify "term" "claude" payload-file))
            (gethash "term" rsr/agent-sessions))
        (when (file-exists-p payload-file) (delete-file payload-file))
        (kill-buffer term)
        (delete-directory directory t)))))

(ert-deftest rsr/agent-hook-new-agent-takes-over-after-exit ()
  "Claude started where pi exited replaces pi's row, carrying nothing over."
  (let ((session (rsr/agent-hook-test--swap "SessionEnd" "claude")))
    (should (equal (plist-get session :agent-type) "claude"))
    (should (equal (plist-get session :agent-session-id) "claude-sid"))
    (should-not (plist-get session :branched-from))
    (should-not (plist-get session :submitted-prompt))))

(ert-deftest rsr/agent-hook-new-agent-takes-over-after-hard-kill ()
  "No `SessionEnd' from pi, but claude is what the terminal now runs."
  (let ((session (rsr/agent-hook-test--swap "Stop" "claude")))
    (should (equal (plist-get session :agent-type) "claude"))
    (should (equal (plist-get session :agent-session-id) "claude-sid"))))

(ert-deftest rsr/agent-hook-stray-event-still-rejected ()
  "pi is alive and running: another session's event must not take its row."
  (let ((session (rsr/agent-hook-test--swap "Stop" "pi")))
    (should (equal (plist-get session :agent-type) "pi"))
    (should (equal (plist-get session :agent-session-id) "pi-sid"))))

(defun rsr/agent-hook-test--statuses (events &optional seen-after)
  "Feed claude EVENTS to one terminal; return the status after each.
After the event named SEEN-AFTER, the user looks at the terminal."
  (rsr/agent-sessions-test--with-temp-db
    (let* ((directory (make-temp-file "agent-hook-turn-" t))
           (term (generate-new-buffer " *agent-hook-turn*"))
           (rsr/agent-session-id->buffer (make-hash-table :test 'equal))
           (rsr/agent-sessions (make-hash-table :test 'equal))
           (rsr/agent-sessions--last-focused-buffer nil)
           (rsr/agent-session-notify-on-attention nil)
           statuses)
      (unwind-protect
          (progn
            (with-current-buffer term
              (setq-local rsr/agent-session-id "term")
              (setq default-directory (file-name-as-directory directory)))
            (puthash "term" term rsr/agent-session-id->buffer)
            (cl-letf (((symbol-function 'rsr/agent-sessions--foreground-command)
                       (lambda (_) "claude"))
                      ((symbol-function 'rsr/agent-session--repo-info)
                       (lambda (_) (list :repo "repo" :repo-root directory
                                         :worktree-path directory)))
                      ((symbol-function 'rsr/agent-sessions--detect-parent) #'ignore)
                      ((symbol-function 'rsr/agent-sessions--log-update) #'ignore)
                      ((symbol-function 'rsr/agent-orchestration--hydrate) #'ignore)
                      ((symbol-function 'rsr/agent-orchestration-deliver) #'ignore)
                      ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                       #'ignore))
              (dolist (event events)
                (let ((payload-file (make-temp-file "agent-hook-payload-")))
                  (with-temp-file payload-file
                    (insert (json-serialize
                             (let ((payload (make-hash-table :test 'equal)))
                               (puthash "hook_event_name" event payload)
                               (puthash "session_id" "claude-sid" payload)
                               (puthash "cwd" directory payload)
                               payload))))
                  (rsr/agent-hook-notify "term" "claude" payload-file))
                (when (equal event seen-after)
                  (rsr/agent-session--clear-attention term))
                (push (plist-get (gethash "term" rsr/agent-sessions) :status)
                      statuses)))
            (nreverse statuses))
        (kill-buffer term)
        (delete-directory directory t)))))

(ert-deftest rsr/agent-hook-answered-permission-resumes-running ()
  "A tool finishing after an answered permission puts the row back to running.
Looking at the waiting session turns it `stopped'; before this, the tool
events that followed left it there for the rest of the turn."
  (should (equal (rsr/agent-hook-test--statuses
                  '("UserPromptSubmit" "PreToolUse" "PermissionRequest"
                    "PostToolUse" "Stop")
                  "PermissionRequest")
                 '(running running stopped running needs-attention))))

(ert-deftest rsr/agent-hook-straggler-tool-event-keeps-turn-ended ()
  "A PostToolUse delivered after Stop must not bring back `running'."
  (should (equal (rsr/agent-hook-test--statuses
                  '("UserPromptSubmit" "Stop" "PostToolUse"))
                 '(running needs-attention needs-attention))))

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
        (should (string-match-p "●" (buffer-string)))
        (should (string-match-p "Investigate the issue" (buffer-string)))
        (should-not (string-match-p "running" (buffer-string)))
        (should-not (string-match-p "PreToolUse" (buffer-string)))))))

(ert-deftest rsr/agent-sessions-child-row-draws-connector ()
  (with-temp-buffer
    (rsr/agent-sessions-mode)
    (let ((inhibit-read-only t)
          (rsr/agent-sessions--row-status nil)
          (entry (list :id "child" :title "Explore"
                       :session (list :agent-type "claude" :status 'stopped))))
      (cl-letf (((symbol-function 'rsr/agent-sessions--session-state)
                 (lambda (_) nil))
                ((symbol-function 'rsr/agent-orchestration--row-badge)
                 (lambda (_) ""))
                ((symbol-function 'rsr/agent-sessions--insert-note) #'ignore)
                ((symbol-function 'rsr/agent-sessions--insert-links) #'ignore)
                ((symbol-function 'rsr/agent-sessions--insert-files) #'ignore))
        (rsr/agent-sessions--insert-session entry 1 t)
        (should (string-match-p "\\`    └ ○ " (buffer-string)))))))

(ert-deftest rsr/agent-sessions-state-follows-the-row ()
  "A stage goes last, so a row without one has no gap before its title."
  (should (equal (substring-no-properties
                  (rsr/agent-sessions--row-text "P Title claude" nil "\n" 'default))
                 "P Title claude\n"))
  (should (equal (substring-no-properties
                  (rsr/agent-sessions--row-text "P Title claude" "PLANNING" "\n"
                                                'default))
                 "P Title claude  PLANNING\n")))

(ert-deftest rsr/agent-sessions-row-title-drops-activity-glyph ()
  (should (equal (rsr/agent-sessions--row-title "✳ Fix the view") "Fix the view"))
  (should (equal (rsr/agent-sessions--row-title "⠐ Fix the view") "Fix the view"))
  (should (equal (rsr/agent-sessions--row-title "Fix * this") "Fix * this"))
  (should (equal (rsr/agent-sessions--row-title nil) "")))

(ert-deftest rsr/agent-sessions-attachment-column-fits-names ()
  (cl-letf (((symbol-function 'rsr/agent-sessions--session-links)
             (lambda (_) (list (list :kind "linear" :url "https://x"))))
            ((symbol-function 'rsr/agent-sessions--session-files)
             (lambda (_) (list (list :path "/tmp/brief.md")))))
    (should (= (rsr/agent-sessions--attachment-name-width nil)
               (max (length "brief.md")
                    (length (rsr/agent-sessions--link-kind-label
                             (list :kind "linear")))))))
  (cl-letf (((symbol-function 'rsr/agent-sessions--session-links) #'ignore)
            ((symbol-function 'rsr/agent-sessions--session-files) #'ignore))
    (should (= (rsr/agent-sessions--attachment-name-width nil) 1))))

(ert-deftest rsr/agent-sessions-status-glyph-per-status ()
  (should (equal (rsr/agent-sessions--status-glyph 'running) "●"))
  (should (equal (rsr/agent-sessions--status-glyph 'idle) "◐"))
  (should (equal (rsr/agent-sessions--status-glyph 'stopped) "○"))
  (should (equal (rsr/agent-sessions--status-glyph 'needs-attention) "●"))
  (should (equal (rsr/agent-sessions--status-glyph 'error) "✖")))

(ert-deftest rsr/agent-sessions-every-listed-state-has-a-face ()
  (dolist (state rsr/agent-sessions-states)
    (should (rsr/agent-sessions--state-face state)))
  ;; The agent-held states are told apart by color now, not all shadow.
  (should-not (equal (face-attribute 'rsr/agent-session-state-planning :foreground)
                     (face-attribute 'rsr/agent-session-state-implementing
                                     :foreground))))

(ert-deftest rsr/agent-sessions-attention-sort-can-be-turned-off ()
  "With attention sorting off, a waiting row keeps its place."
  (let* ((older (generate-new-buffer " *sort-a*"))
         (newer (generate-new-buffer " *sort-b*"))
         (entries (list (list :id "a" :session (list :buffer older :status 'stopped))
                        (list :id "b" :session (list :buffer newer
                                                     :status 'needs-attention))))
         (ids (lambda (es) (mapcar (lambda (e) (plist-get e :id)) es))))
    (unwind-protect
        (progn
          (with-current-buffer older
            (setq-local rsr/agent-session--created-at '(0 1)))
          (with-current-buffer newer
            (setq-local rsr/agent-session--created-at '(0 2)))
          (let ((rsr/agent-sessions-sort-by-attention t))
            (should (equal (funcall ids (rsr/agent-sessions--sort-entries entries))
                           '("b" "a"))))
          (let ((rsr/agent-sessions-sort-by-attention nil))
            (should (equal (funcall ids (rsr/agent-sessions--sort-entries entries))
                           '("a" "b")))))
      (kill-buffer older)
      (kill-buffer newer))))

(ert-deftest rsr/agent-sessions-tmux-agents-join-their-sessions-repo ()
  "A non-git tmux agent whose tmux session started in a repo joins that repo."
  (rsr/agent-sessions-test--with-temp-db
    (let* ((rsr/agent-sessions-sort-by-activity nil)
           (home (list :repo "my-app" :repo-root "/code/my-app/"
                       :worktree "my-app (main)" :worktree-name "my-app"
                       :branch "main" :worktree-path "/code/my-app/"))
           (planner (list :tmux "my-app" :repo "my-app" :repo-root "/plans/x/"
                          :worktree "my-app" :worktree-path "/plans/x/"))
           (entries
            (list (list :id "a" :session planner)
                  (list :id "b" :session (list :repo "my-app"
                                               :repo-root "/code/my-app/"
                                               :worktree "my-app (main)"
                                               :worktree-path "/code/my-app/")))))
      (cl-letf (((symbol-function 'rsr/agent-sessions--session-tmux-group)
                 (lambda (session) (plist-get session :tmux)))
                ((symbol-function 'rsr/agent-tmux-session-path)
                 (lambda (_) "/code/my-app/"))
                ((symbol-function 'rsr/agent-session--repo-info)
                 (lambda (_) home)))
        (clrhash rsr/agent-sessions--tmux-home-cache)
        (let ((repos (rsr/agent-sessions--build-tree entries)))
          (should (= (length repos) 1))
          (should (equal (plist-get (car repos) :name) "my-app"))
          (should (equal (sort (mapcar (lambda (e) (plist-get e :id))
                                       (plist-get (car repos) :entries))
                               #'string<)
                         '("a" "b")))
          ;; The registry's own record is untouched.
          (should (equal (plist-get planner :worktree-path) "/plans/x/")))))))

(ert-deftest rsr/agent-sessions-non-git-child-takes-its-parents-repo ()
  "A tmux child outside git is placed in its live parent's repo, not in the
repo its tmux session started in, so it can nest under the parent and share
the parent's folder.  Without a live parent it groups by its tmux session."
  (let* ((rsr/agent-sessions (make-hash-table :test 'equal))
         (plans (file-name-as-directory (make-temp-file "plans-" t)))
         (proxy (lambda ()
                  (let ((buf (generate-new-buffer " *proxy*")))
                    (with-current-buffer buf
                      (setq major-mode 'rsr/agent-tmux-mode)
                      (setq default-directory plans)
                      (setq-local rsr/agent-tmux-session "Brain"))
                    buf)))
         (parent-buf (generate-new-buffer " *parent*"))
         (child (funcall proxy))
         (alone (funcall proxy))
         (none (list :repo nil :repo-root nil :worktree nil :worktree-name nil
                     :branch nil :worktree-path nil)))
    (puthash "p" (list :buffer parent-buf :agent-session-id "parent-sid"
                       :repo ".emacs.d" :repo-root "/code/emacs/"
                       :worktree-name ".emacs.d" :branch "lean-fast"
                       :worktree-path "/code/emacs/")
             rsr/agent-sessions)
    (with-current-buffer child
      (setq-local rsr/agent-session--branched-from '("parent-sid" . "Plan")))
    (unwind-protect
        (cl-letf (((symbol-function 'rsr/agent-session--repo-info)
                   (lambda (_) none))
                  ((symbol-function 'rsr/agent-tmux-session-path)
                   (lambda (_) "/code/brain/")))
          (let ((info (rsr/agent-sessions--buffer-repo-info child)))
            (should (equal (plist-get info :repo-root) "/code/emacs/"))
            (should (equal (plist-get info :repo) ".emacs.d"))
            (should (equal (plist-get info :branch) "lean-fast"))
            ;; Resume still knows the tmux session and the child's own folder.
            (should (equal (plist-get info :worktree) "Brain"))
            (should (equal (plist-get info :worktree-path)
                           (rsr/agent-sessions--canonical-path plans)))
            ;; And the render does not move it back to the tmux session's repo.
            (should-not (rsr/agent-sessions--session-tmux-group
                         (list :buffer child))))
          (let ((info (rsr/agent-sessions--buffer-repo-info alone)))
            (should (equal (plist-get info :repo-root) "/code/brain/"))
            (should (equal (plist-get info :repo) "Brain"))
            (should (equal (rsr/agent-sessions--session-tmux-group
                            (list :buffer alone))
                           "Brain")))
          ;; A parent whose terminal is gone no longer places the child.
          (kill-buffer parent-buf)
          (should (equal (plist-get (rsr/agent-sessions--buffer-repo-info child)
                                    :repo-root)
                         "/code/brain/")))
      (dolist (b (list parent-buf child alone))
        (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest rsr/agent-sessions-repo-is-named-after-its-tmux-session ()
  "A repo's heading is the tmux session started inside it, so a checkout
folder called `main' does not name the project.  A session started in another
repo never names this one, however many of its agents run there, and a
session that is only the repo's name made tmux-safe is spelled as the repo."
  (rsr/agent-sessions-test--with-temp-db
    (let* ((rsr/agent-sessions-sort-by-activity nil)
           (proxy (lambda (tmux)
                    (let ((buf (generate-new-buffer " *proxy*")))
                      (with-current-buffer buf
                        (setq major-mode 'rsr/agent-tmux-mode)
                        (setq-local rsr/agent-tmux-session tmux))
                      buf)))
           (a (funcall proxy "tina"))
           (b (funcall proxy "elsewhere"))
           (c (funcall proxy "elsewhere"))
           (d (funcall proxy "-emacs-d"))
           (plain (generate-new-buffer " *plain*"))
           (paths '(("tina" . "/projects/tina/main/")
                    ("elsewhere" . "/projects/other/")
                    ("-emacs-d" . "/home/me/.emacs.d/")))
           (roots '(("/projects/tina/main/" . "/projects/tina/main/")
                    ("/projects/other/" . "/projects/other/")
                    ("/home/me/.emacs.d/" . "/home/me/.emacs.d/")))
           (session (lambda (buf &optional repo root)
                      (list :buffer buf :repo (or repo "main")
                            :repo-root (or root "/projects/tina/main/")
                            :worktree-path (or root "/projects/tina/main/"))))
           (name (lambda (&rest entries)
                   (plist-get (car (rsr/agent-sessions--build-tree entries)) :name)))
           (entry (lambda (buf &optional repo root)
                    (list :id (buffer-name buf)
                          :session (funcall session buf repo root)))))
      (unwind-protect
          (cl-letf (((symbol-function 'rsr/agent-sessions--tmux-home) #'ignore)
                    ((symbol-function 'rsr/agent-tmux-session-path)
                     (lambda (tmux) (cdr (assoc tmux paths))))
                    ((symbol-function 'rsr/agent-session--repo-info)
                     (lambda (dir)
                       (when-let ((root (cdr (assoc dir roots))))
                         (list :repo (file-name-nondirectory
                                      (directory-file-name root))
                               :repo-root root)))))
            (clrhash rsr/agent-sessions--tmux-home-cache)
            ;; Started in the repo, it names it even when outnumbered.
            (should (equal (funcall name (funcall entry a) (funcall entry b)
                                    (funcall entry c))
                           "tina"))
            ;; Started elsewhere, it does not; the repo's own name stands in.
            (should (equal (funcall name (funcall entry b) (funcall entry c))
                           "main"))
            ;; The tmux spelling of the repo's own name reads as the repo.
            (should (equal (funcall name (funcall entry d ".emacs.d"
                                                  "/home/me/.emacs.d/"))
                           ".emacs.d"))
            ;; With no agent in tmux, the checkout's own name stands in.
            (should (equal (funcall name (funcall entry plain)) "main"))
            ;; `+' on the heading still goes to the repo's own session.
            (should (equal (rsr/agent-sessions--entries-tmux-session
                            (list (funcall entry b) (funcall entry c)
                                  (funcall entry a)))
                           "tina")))
        (mapc #'kill-buffer (list a b c d plain))))))

(ert-deftest rsr/agent-sessions-folder-heading-names-the-shared-worktree ()
  "A row repeats its `@' label only when it differs from its folder's."
  (let* ((rsr/agent-sessions-worktree-label 'folder)
         (session (lambda (wt folder)
                    (list :worktree-name wt :folder folder
                          :worktree-path (concat "/nonexistent/" wt "/"))))
         (entries (list (list :id "a" :session (funcall session "card" 1))
                        (list :id "b" :session (funcall session "card" 1))
                        (list :id "c" :session (funcall session "option-a" 1))
                        (list :id "d" :session (funcall session "card" nil)))))
    (cl-letf (((symbol-function 'rsr/agent-sessions--folder-for-session)
               (lambda (session) (plist-get session :folder))))
      (should (equal (rsr/agent-sessions--shared-at-label (seq-take entries 3))
                     "@card"))
      (should (equal (mapcar (lambda (e) (plist-get e :at-label))
                             (rsr/agent-sessions--label-entries entries))
                     ;; A row in no folder is compared with its repo heading.
                     '(nil nil "@option-a" nil))))))

(defmacro rsr/agent-sessions-test--with-git-repo (var &rest body)
  "Run BODY with VAR bound to a fresh git repo on branch `main'."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "at-label-" t))))
     (unwind-protect
         (let ((default-directory ,var))
           (dolist (args '(("init" "-q" "-b" "main")
                           ("-c" "user.email=t@t" "-c" "user.name=t"
                            "commit" "-q" "--allow-empty" "-m" "init")))
             (apply #'call-process "git" nil nil nil args))
           ,@body)
       (delete-directory ,var t))))

(ert-deftest rsr/agent-sessions-head-branch-reads-every-head-kind ()
  (rsr/agent-sessions-test--with-git-repo repo
    (should (equal (rsr/agent-sessions--head-branch repo) "main"))
    ;; A linked worktree's .git is a file pointing at its gitdir.
    (let ((linked (concat (directory-file-name repo) "-linked/")))
      (unwind-protect
          (progn
            (call-process "git" nil nil nil "worktree" "add" "-q" "-b" "feature/x"
                          (directory-file-name linked))
            (should (equal (rsr/agent-sessions--head-branch linked) "feature/x")))
        (delete-directory linked t)))
    ;; A switched branch shows without re-registering anything.
    (call-process "git" nil nil nil "checkout" "-q" "-b" "other")
    (should (equal (rsr/agent-sessions--head-branch repo) "other"))
    (call-process "git" nil nil nil "checkout" "-q" "--detach")
    (should (eq (rsr/agent-sessions--head-branch repo) 'detached)))
  (should-not (rsr/agent-sessions--head-branch nil))
  (should-not (rsr/agent-sessions--head-branch "/nonexistent/path/")))

(ert-deftest rsr/agent-sessions-at-label-follows-setting-and-head ()
  (rsr/agent-sessions-test--with-git-repo repo
    (let ((rsr/agent-sessions-worktree-label 'branch))
      ;; Live HEAD beats a stale registered branch.
      (should (equal (rsr/agent-sessions--at-label repo "wt" "stale") "@main"))
      (call-process "git" nil nil nil "checkout" "-q" "--detach")
      ;; Detached: the folder name, not the stale branch.
      (should (equal (rsr/agent-sessions--at-label repo "wt" "stale") "@wt")))
    (let ((rsr/agent-sessions-worktree-label 'folder))
      (should (equal (rsr/agent-sessions--at-label repo "wt" "main") "@wt"))))
  ;; Unreadable HEAD: the registered branch stands in.
  (let ((rsr/agent-sessions-worktree-label 'branch))
    (should (equal (rsr/agent-sessions--at-label "/nonexistent/" "wt" "dev")
                   "@dev"))
    (should (equal (rsr/agent-sessions--at-label "/nonexistent/wt/" nil nil)
                   "@wt"))))

(ert-deftest rsr/agent-sessions-opening-from-side-window-does-not-split ()
  "Opening sessions from the side-window dashboard reuses the main window."
  (let ((rsr/agent-sessions-display-side 'left)
        (rsr/agent-sessions-buffer-name "*agent-sessions-split-test*")
        (one (get-buffer-create " *split-test-one*"))
        (two (get-buffer-create " *split-test-two*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (cl-letf (((symbol-function 'rsr/agent-sessions--refresh) #'ignore))
            (rsr/agent-sessions-list))
          (let ((count (length (window-list))))
            (rsr/agent-sessions--pop-to-other-window one)
            (select-window (get-buffer-window rsr/agent-sessions-buffer-name))
            (rsr/agent-sessions--pop-to-other-window two)
            (should (= (length (window-list)) count))
            (should (get-buffer-window rsr/agent-sessions-buffer-name))
            (should (eq (window-buffer (selected-window)) two))))
      (when-let ((win (get-buffer-window rsr/agent-sessions-buffer-name)))
        (delete-window win))
      (mapc #'kill-buffer (list one two))
      (kill-buffer rsr/agent-sessions-buffer-name))))

(ert-deftest rsr/agent-sessions-opening-from-a-lone-window-replaces-it ()
  "From the only ordinary window (a notification click): no split."
  (let ((buf (get-buffer-create " *lone-test*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (pop-to-buffer buf rsr/agent-tmux-other-window-action)
          (should (= (length (window-list)) 1))
          (should (eq (window-buffer (selected-window)) buf)))
      (kill-buffer buf))))

(ert-deftest rsr/agent-sessions-opening-a-buffer-shown-here-makes-no-copy ()
  "From a window already showing the buffer, with another beside it: stay."
  (let ((buf (get-buffer-create " *shown-test*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer buf)
          (set-window-buffer (split-window-right) (get-buffer-create "*scratch*"))
          (pop-to-buffer buf rsr/agent-tmux-other-window-action)
          (should (= (length (get-buffer-window-list buf)) 1))
          (should (eq (window-buffer (selected-window)) buf)))
      (kill-buffer buf))))

(ert-deftest rsr/agent-sessions-opening-from-a-window-with-another-uses-the-other ()
  "From an ordinary window with another beside it: the other, as before."
  (let ((buf (get-buffer-create " *other-test*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((here (selected-window))
                (other (split-window-right)))
            (pop-to-buffer buf rsr/agent-tmux-other-window-action)
            (should (= (length (window-list)) 2))
            (should (eq (window-buffer other) buf))
            (should-not (eq (window-buffer here) buf))))
      (kill-buffer buf))))

(defmacro rsr/agent-sessions-test--with-ace (pick &rest body)
  "Run BODY beside a side-window dashboard, with ace-window's picker faked.
PICK is called with the windows offered and returns the chosen one.  Batch
Emacs runs on the initial terminal, whose windows `aw-window-list' always
drops, so the list is rebuilt here from `aw-ignored-p' alone."
  (declare (indent 1))
  `(let ((rsr/agent-sessions-display-side 'left)
         (rsr/agent-sessions-buffer-name "*agent-sessions-ace-test*"))
     (require 'ace-window)
     (unwind-protect
         (progn
           (delete-other-windows)
           (cl-letf (((symbol-function 'rsr/agent-sessions--refresh) #'ignore))
             (rsr/agent-sessions-list))
           (cl-letf (((symbol-function 'aw-window-list)
                      (lambda () (seq-remove #'aw-ignored-p (window-list))))
                     ((symbol-function 'aw-select)
                      (lambda (_mode-line action)
                        (funcall action (funcall ,pick (aw-window-list))))))
             ,@body))
       (when-let ((win (get-buffer-window rsr/agent-sessions-buffer-name)))
         (delete-window win))
       (kill-buffer rsr/agent-sessions-buffer-name))))

(ert-deftest rsr/agent-sessions-o-is-bound-to-jump-other-window ()
  (should (eq (lookup-key rsr/agent-sessions-mode-map (kbd "o"))
              #'rsr/agent-sessions-jump-other-window)))

(ert-deftest rsr/agent-sessions-ace-display-uses-the-picked-window ()
  "The picked window shows the buffer; the dashboard is never offered."
  (let ((buf (get-buffer-create " *ace-test-buf*"))
        offered)
    (unwind-protect
        (rsr/agent-sessions-test--with-ace
            (lambda (windows) (setq offered windows) (cadr windows))
          (split-window (window-main-window) nil 'right)
          (let ((count (length (window-list))))
            (pop-to-buffer buf '(rsr/agent-sessions--display-buffer-in-ace-window))
            (should (= (length offered) 2))
            (should-not (memq (get-buffer-window rsr/agent-sessions-buffer-name)
                              offered))
            (should (eq (selected-window) (cadr offered)))
            (should (eq (window-buffer (selected-window)) buf))
            (should (= (length (window-list)) count))))
      (kill-buffer buf))))

(ert-deftest rsr/agent-sessions-ace-display-splits-a-lone-window ()
  "With one window beside the dashboard, it is split and the buffer goes in the new half."
  (let ((buf (get-buffer-create " *ace-test-buf*")))
    (unwind-protect
        (rsr/agent-sessions-test--with-ace
            (lambda (_) (error "Picker should not be shown"))
          (let ((count (length (window-list))))
            (pop-to-buffer buf '(rsr/agent-sessions--display-buffer-in-ace-window))
            (should (= (length (window-list)) (1+ count)))
            (should (eq (window-buffer (selected-window)) buf))
            (should (get-buffer-window rsr/agent-sessions-buffer-name))
            ;; A window made for the buffer is deleted again by `q'.
            (should (eq (car (window-parameter (selected-window) 'quit-restore))
                        'window))))
      (kill-buffer buf))))

(ert-deftest rsr/agent-sessions-o-on-a-shown-buffer-selects-it ()
  "`o' on a buffer already on screen selects it: no split, no second copy."
  (let ((buf (get-buffer-create " *ace-test-buf*")))
    (unwind-protect
        (rsr/agent-sessions-test--with-ace
            (lambda (_) (error "Picker should not be shown"))
          (set-window-buffer (window-main-window) buf)
          (let ((count (length (window-list)))
                (display-buffer-overriding-action
                 '(rsr/agent-sessions--display-buffer-in-ace-window)))
            (pop-to-buffer buf rsr/agent-tmux-other-window-action)
            (should (= (length (window-list)) count))
            (should (= (length (get-buffer-window-list buf)) 1))
            (should (eq (window-buffer (selected-window)) buf))))
      (kill-buffer buf))))

(ert-deftest rsr/agent-sessions-ace-display-quit-opens-nothing ()
  "Quitting the picker quits, rather than falling back to another window."
  (let ((buf (get-buffer-create " *ace-test-buf*")))
    (unwind-protect
        (rsr/agent-sessions-test--with-ace (lambda (_) nil)
          (split-window (window-main-window) nil 'right)
          ;; `should-error' only catches errors, and `quit' is not one.
          (should (eq (condition-case nil
                          (let ((display-buffer-overriding-action
                                 '(rsr/agent-sessions--display-buffer-in-ace-window)))
                            (pop-to-buffer buf rsr/agent-tmux-other-window-action)
                            'shown)
                        (quit 'quit))
                      'quit))
          (should-not (get-buffer-window buf)))
      (kill-buffer buf))))

(ert-deftest rsr/agent-sessions-ret-asks-only-with-several-windows ()
  "RET replaces a lone window silently, asks among several, and reuses a shown buffer."
  (let ((one (get-buffer-create " *ace-test-one*"))
        (two (get-buffer-create " *ace-test-two*"))
        asked)
    (unwind-protect
        (rsr/agent-sessions-test--with-ace
            (lambda (windows) (setq asked t) (cadr windows))
          (let ((display-buffer-overriding-action
                 '(rsr/agent-sessions--display-buffer-ace-if-several)))
            (let ((count (length (window-list))))
              (pop-to-buffer one rsr/agent-tmux-other-window-action)
              (should-not asked)
              (should (= (length (window-list)) count)))
            (split-window (window-main-window) nil 'right)
            (pop-to-buffer two rsr/agent-tmux-other-window-action)
            (should asked)
            (should (eq (window-buffer (selected-window)) two))
            (setq asked nil)
            (select-window (get-buffer-window rsr/agent-sessions-buffer-name))
            (pop-to-buffer two rsr/agent-tmux-other-window-action)
            (should-not asked)
            (should (eq (window-buffer (selected-window)) two))))
      (mapc #'kill-buffer (list one two)))))

(ert-deftest rsr/agent-sessions-list-opens-in-side-window ()
  (let ((rsr/agent-sessions-display-side 'left)
        (rsr/agent-sessions-window-width 45)
        (rsr/agent-sessions-buffer-name "*agent-sessions-side-test*"))
    (unwind-protect
        (cl-letf (((symbol-function 'rsr/agent-sessions--refresh) #'ignore))
          (rsr/agent-sessions-list)
          (let ((win (get-buffer-window rsr/agent-sessions-buffer-name)))
            (should win)
            (should (eq (window-parameter win 'window-side) 'left))
            (should (eq (selected-window) win))))
      (when-let ((win (get-buffer-window rsr/agent-sessions-buffer-name)))
        (delete-window win))
      (kill-buffer rsr/agent-sessions-buffer-name))))

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

;; Briefs piled up under a reused buffer name

(ert-deftest rsr/agent-sessions-files-stay-with-their-terminal-not-its-name ()
  "A file shared before the agent id is known belongs to that terminal only.
Two terminals that reuse one buffer name, as every child of one skill does,
must not see each other's files."
  (rsr/agent-sessions-test--with-temp-db
    (let ((source (make-temp-file "agent-brief-"))
          (first (generate-new-buffer "implement-plan-tmux")))
      (unwind-protect
          (progn
            (with-current-buffer first (setq-local rsr/agent-session-id "t-1"))
            (rsr/agent-sessions--share-file (list :buffer first) source "brief")
            (kill-buffer first)
            (let ((second (generate-new-buffer "implement-plan-tmux")))
              (unwind-protect
                  (progn
                    (with-current-buffer second
                      (setq-local rsr/agent-session-id "t-2"))
                    (should-not (rsr/agent-sessions--session-files
                                 (list :buffer second))))
                (kill-buffer second))))
        (when (buffer-live-p first) (kill-buffer first))
        (delete-file source)))))

(ert-deftest rsr/agent-sessions-adopt-agent-id-moves-terminal-keyed-data ()
  "Learning the agent id moves files, links, note and state onto it at once."
  (rsr/agent-sessions-test--with-temp-db
    (let ((source (make-temp-file "agent-brief-"))
          (buffer (generate-new-buffer "implement-plan-tmux"))
          (rsr/agent-sessions--notes nil)
          (rsr/agent-sessions--states nil))
      (unwind-protect
          (let ((bare (list :buffer buffer))
                (durable '("session" "uuid-1")))
            (with-current-buffer buffer (setq-local rsr/agent-session-id "t-1"))
            (rsr/agent-sessions--share-file bare source "brief")
            (rsr/agent-sessions--share-link bare "url" "https://example.com" "pr")
            (rsr/agent-sessions--note-set
             (rsr/agent-sessions--session-note-keys bare) "a note")
            (rsr/agent-sessions--state-set
             (rsr/agent-sessions--session-note-keys bare) "IMPLEMENTING")
            (rsr/agent-sessions--adopt-agent-id
             (list :buffer buffer :agent-session-id "uuid-1"))
            (should (equal (list source)
                           (mapcar (lambda (f) (plist-get f :path))
                                   (gethash durable
                                            (rsr/agent-sessions--shared-files-table)))))
            (should (gethash durable (rsr/agent-sessions--shared-links-table)))
            (should (equal "a note"
                           (gethash durable (rsr/agent-sessions--notes-table))))
            (should (equal "IMPLEMENTING"
                           (gethash durable (rsr/agent-sessions--states-table))))
            (should
             (equal 0
              (caar (sqlite-select
                    (rsr/agent-sessions--db)
                    "SELECT (SELECT COUNT(*) FROM shared_files WHERE key = 't-1')
                          + (SELECT COUNT(*) FROM notes WHERE key = 't-1')
                          + (SELECT COUNT(*) FROM session_states WHERE key = 't-1')
                          + (SELECT COUNT(*) FROM shared_links WHERE owner_key = 't-1')")))))
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
                   (lambda (shown &rest _) (push (list 'pop shown) events))))
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
          ;; Codex reports its id only once its rollout exists, so it is
          ;; left alone.
          (should-not (rsr/agent-sessions--never-saved-p
                       '(:agent-type "codex" :agent-sid "unused"))))
      (delete-directory dir t))))

(ert-deftest rsr/agent-sessions-never-saved-pi-session-is-detected ()
  "A pi session with no session file is never-used, but only when pi's
sessions directory exists to say so."
  (let* ((dir (make-temp-file "pi-agent-" t))
         (process-environment (cons (format "PI_CODING_AGENT_DIR=%s" dir)
                                    process-environment)))
    (unwind-protect
        (progn
          (should-not (rsr/agent-sessions--never-saved-p
                       '(:agent-type "pi" :agent-sid "unused")))
          (make-directory (expand-file-name "sessions/--some-repo--" dir) t)
          (write-region "" nil (expand-file-name
                                "sessions/--some-repo--/2026-10-29T00-00-00-000Z_used.jsonl"
                                dir))
          (should (rsr/agent-sessions--never-saved-p
                   '(:agent-type "pi" :agent-sid "unused")))
          (should-not (rsr/agent-sessions--never-saved-p
                       '(:agent-type "pi" :agent-sid "used"))))
      (delete-directory dir t))))

(defmacro rsr/agent-sessions-test--with-restore-log (rows &rest body)
  "Run BODY against a temp database whose session log holds closed ROWS.
Each row is (AGENT-SID TYPE LABEL TITLE REPO CLOSED-AT)."
  (declare (indent 1) (debug t))
  `(rsr/agent-sessions-test--with-temp-db
     (let ((rsr/agent-sessions--states nil)
           (rsr/agent-sessions--notes nil)
           (rsr/agent-sessions--registered-folders nil))
       (pcase-dolist (`(,sid ,type ,label ,title ,repo ,closed) ,rows)
         (sqlite-execute
          (rsr/agent-sessions--db)
          "INSERT INTO sessions (emacs_sid, agent_type, agent_sid, worktree, repo,
                                 label, title, opened_at, closed_at, close_reason)
           VALUES ('1-1', ?, ?, '/tmp', ?, ?, ?, 0, ?, 'agent-exit')"
          (list type sid repo label title closed)))
       (cl-letf (((symbol-function 'rsr/agent-sessions--never-saved-p)
                  (lambda (row) (equal (plist-get row :agent-sid) "unused-0"))))
         ,@body))))

(ert-deftest rsr/agent-sessions-title-edit-reaches-the-log-at-once ()
  "`t' writes the new title to the log row without waiting for a hook."
  (rsr/agent-sessions-test--with-temp-db
    (let ((buf (generate-new-buffer " *title-log-test*")))
      (unwind-protect
          (cl-letf (((symbol-function 'rsr/agent-sessions--buffer-repo-info)
                     (lambda (_) (list :worktree "repo" :worktree-path "/tmp/")))
                    ((symbol-function 'rsr/agent-sessions--session-at-point)
                     (lambda () (list :buffer buf)))
                    ((symbol-function 'read-string) (lambda (&rest _) "My name"))
                    ((symbol-function 'rsr/agent-sessions--refresh) #'ignore))
            (with-current-buffer buf
              (setq-local rsr/agent-session-id "1-1")
              (setq-local rsr/agent-session-title "✳ Claude Code"))
            (rsr/agent-sessions--log-update buf "claude" "sid-1")
            (rsr/agent-sessions-edit-title)
            (should (equal (caar (sqlite-select (rsr/agent-sessions--db)
                                                "SELECT title FROM sessions"))
                           "My name")))
        (kill-buffer buf)))))

(ert-deftest rsr/agent-sessions-restore-lines-tell-sessions-apart ()
  "Same label and title still give two picker lines, each showing its state."
  (rsr/agent-sessions-test--with-restore-log
      '(("aaaaaaaa-1" "claude" "study" "plan-implementation" "/r/study/" 20)
        ("bbbbbbbb-2" "claude" "study" "plan-implementation" "/r/study/" 10))
    (rsr/agent-sessions--state-set '(("session" "bbbbbbbb-2")) "PLAN-REVIEW")
    (let* ((rows (rsr/agent-sessions--log-rows "closed_at IS NOT NULL"))
           (lines (mapcar #'rsr/agent-sessions--log-describe rows)))
      (should (equal (mapcar (lambda (r) (plist-get r :agent-sid)) rows)
                     '("aaaaaaaa-1" "bbbbbbbb-2")))
      (should (= 2 (length (seq-uniq lines))))
      (should (string-match-p "aaaaaaaa" (nth 0 lines)))
      (should (string-match-p "PLAN-REVIEW +plan-implementation +bbbbbbbb"
                              (nth 1 lines))))))

(ert-deftest rsr/agent-sessions-restore-details-show-folders-and-note ()
  "The annotation names the Plans and code folders in their faces, and the note."
  (rsr/agent-sessions-test--with-restore-log
      '(("s1" "claude" "repo" "title" "/r/repo/" 10))
    (let ((session (list :agent-session-id "s1")))
      (rsr/agent-sessions--register-folder session "plans" "/p/Plans/my-task/")
      (rsr/agent-sessions--register-folder session "code" "/c/repo-a/")
      (rsr/agent-sessions--register-folder session "code" "/c/repo-b")
      (rsr/agent-sessions--note-set '(("session" "s1")) "first line\nsecond"))
    (let ((details (rsr/agent-sessions--log-details
                    (car (rsr/agent-sessions--log-rows "closed_at IS NOT NULL")))))
      (should (equal (substring-no-properties details)
                     "plans:my-task  code:repo-a,repo-b  first line"))
      (should (eq (get-text-property 0 'face details)
                  'rsr/agent-session-restore-plans))
      (should (eq (get-text-property (string-search "code:" details) 'face details)
                  'rsr/agent-session-restore-code)))
    (should (equal (rsr/agent-sessions--log-details
                    (list :agent-sid "nothing-attached"))
                   ""))))

(ert-deftest rsr/agent-sessions-restore-dims-never-used-and-filters-by-repo ()
  "Never-used rows are dimmed but listed; the filter key narrows to one repo
and pressing it again widens back to every repo."
  (rsr/agent-sessions-test--with-restore-log
      '(("used-1" "claude" "alpha" "a" "/r/alpha/" 30)
        ("unused-0" "claude" "alpha" nil "/r/alpha/" 20)
        ("used-2" "claude" "beta (wt)" "b" "/r/beta/" 10))
    (let ((rows (rsr/agent-sessions--log-rows "closed_at IS NOT NULL")))
      (should (eq 'shadow (get-text-property
                           0 'face (rsr/agent-sessions--restore-candidate
                                    (nth 1 rows)))))
      (should-not (eq 'shadow (get-text-property
                               0 'face (rsr/agent-sessions--restore-candidate
                                        (nth 0 rows))))))
    (let ((answers (list 'filter "beta" 'filter 'filter "alpha" "used-1"))
          seen restored)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt collection &rest _)
                   (let ((answer (pop answers)))
                     (if (eq answer 'filter)
                         (progn (setq rsr/agent-sessions--restore-filter-requested t) "")
                       (if (functionp collection)
                           (progn
                             (push (cons prompt (all-completions "" collection)) seen)
                             (seq-find (lambda (c) (string-match-p answer c))
                                       (all-completions "" collection)))
                         answer)))))
                ((symbol-function 'rsr/agent-sessions--restore-row)
                 (lambda (row) (setq restored row))))
        (rsr/agent-sessions-restore))
      (should (equal (plist-get restored :agent-sid) "used-1"))
      ;; The last picker shown was filtered to alpha: both alpha rows, no beta.
      (let ((last (car seen)))
        (should (string-match-p "in alpha" (car last)))
        (should (= 2 (length (cdr last))))))))

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

;;; Which agent is on screen beside the dashboard

(defmacro rsr/agent-sessions-test--with-on-screen (&rest body)
  "Run BODY with `dashboard' and terminals `a' and `b', each a row of one repo.
The dashboard is in the selected window with one window beside it, which
shows nothing of the dashboard's; BODY points it at a terminal itself."
  (declare (indent 0) (debug t))
  `(rsr/agent-sessions-test--with-temp-db
     (let* ((root (make-temp-file "on-screen-repo-" t))
            (a (generate-new-buffer " *on-screen-a*"))
            (b (generate-new-buffer " *on-screen-b*"))
            (other (generate-new-buffer " *on-screen-other*"))
            (dashboard (generate-new-buffer " *on-screen-dashboard*"))
            (rsr/agent-sessions-buffer-name (buffer-name dashboard))
            (rsr/agent-sessions--folders-loaded-p nil)
            (rsr/agent-sessions--folders-cache-version nil)
            (rsr/agent-sessions--folders nil)
            (rsr/agent-sessions--folder-assignments nil)
            (rsr/agent-sessions--order nil)
            (rsr/agent-sessions-icons nil)
            (rsr/agent-sessions--states nil)
            (rsr/agent-sessions--notes nil)
            (rsr/agent-sessions--on-screen-timer nil)
            (status-a 'stopped)
            (entry (lambda (id buf status)
                     (list :id id :title id
                           :session (list :buffer buf :agent-session-id id
                                          :agent-type "claude" :status status
                                          :repo "repo" :repo-root root
                                          :worktree "repo" :worktree-name "repo"
                                          :branch "main" :worktree-path root)))))
       (unwind-protect
           (save-window-excursion
             (delete-other-windows)
             (switch-to-buffer dashboard)
             (set-window-buffer (split-window-right) other)
             (with-current-buffer dashboard (rsr/agent-sessions-mode))
             (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                        (lambda () (list (funcall entry "alpha" a status-a)
                                         (funcall entry "beta" b 'stopped)))))
               ,@body))
         (dolist (buf (list a b other dashboard)) (kill-buffer buf))
         (delete-directory root t)))))

(defun rsr/agent-sessions-test--row-marks (dashboard title)
  "The on-screen overlays on the row titled TITLE in DASHBOARD."
  (with-current-buffer dashboard
    (goto-char (point-min))
    (re-search-forward (concat (regexp-quote title) "\\_>"))
    (seq-filter (lambda (o) (overlay-get o 'rsr/agent-sessions-on-screen))
                (overlays-in (line-beginning-position) (line-end-position)))))

(defun rsr/agent-sessions-test--marked-p (dashboard title)
  "Non-nil when the row titled TITLE carries the on-screen glyph."
  (seq-find (lambda (o) (equal (overlay-get o 'display)
                               rsr/agent-sessions-on-screen-glyph))
            (rsr/agent-sessions-test--row-marks dashboard title)))

(defun rsr/agent-sessions-test--shaded-p (dashboard title)
  "Non-nil when the row titled TITLE carries the on-screen background."
  (seq-find (lambda (o) (eq (overlay-get o 'face) 'rsr/agent-session-on-screen))
            (rsr/agent-sessions-test--row-marks dashboard title)))

(ert-deftest rsr/agent-sessions-on-screen-row-is-marked ()
  "The row whose terminal is in a window gets the glyph and the background."
  (rsr/agent-sessions-test--with-on-screen
    (set-window-buffer (next-window) a)
    (with-current-buffer dashboard (rsr/agent-sessions--refresh))
    (should (rsr/agent-sessions-test--marked-p dashboard "alpha"))
    (should (rsr/agent-sessions-test--shaded-p dashboard "alpha"))
    (should-not (rsr/agent-sessions-test--row-marks dashboard "beta"))))

(ert-deftest rsr/agent-sessions-on-screen-shades-the-sessions-attachments ()
  "The background covers what hangs under the row, not only its heading line.
The glyph stays on the heading alone."
  (rsr/agent-sessions-test--with-on-screen
    (setq rsr/agent-sessions--notes (make-hash-table :test 'equal))
    (puthash '("session" "alpha") "remember this" rsr/agent-sessions--notes)
    (puthash '("session" "beta") "and this" rsr/agent-sessions--notes)
    (set-window-buffer (next-window) a)
    (with-current-buffer dashboard (rsr/agent-sessions--refresh))
    (should (rsr/agent-sessions-test--shaded-p dashboard "remember this"))
    (should-not (rsr/agent-sessions-test--marked-p dashboard "remember this"))
    (should-not (rsr/agent-sessions-test--row-marks dashboard "and this"))))

(ert-deftest rsr/agent-sessions-on-screen-marks-every-split ()
  "Two terminals in splits beside the dashboard both mark their rows."
  (rsr/agent-sessions-test--with-on-screen
    (let ((beside (next-window)))
      (set-window-buffer beside a)
      (set-window-buffer (split-window beside nil 'below) b))
    (with-current-buffer dashboard (rsr/agent-sessions--refresh))
    (should (rsr/agent-sessions-test--marked-p dashboard "alpha"))
    (should (rsr/agent-sessions-test--marked-p dashboard "beta"))
    (should (rsr/agent-sessions-test--shaded-p dashboard "beta"))))

(ert-deftest rsr/agent-sessions-on-screen-mark-keeps-attention-background ()
  "A row that needs attention keeps its own background; only the glyph is added."
  (rsr/agent-sessions-test--with-on-screen
    (setq status-a 'needs-attention)
    (set-window-buffer (next-window) a)
    (with-current-buffer dashboard (rsr/agent-sessions--refresh))
    (should (rsr/agent-sessions-test--marked-p dashboard "alpha"))
    (should-not (rsr/agent-sessions-test--shaded-p dashboard "alpha"))))

(ert-deftest rsr/agent-sessions-on-screen-mark-moves-without-render ()
  "Showing another terminal moves the mark; the rows are not drawn again."
  (rsr/agent-sessions-test--with-on-screen
    (set-window-buffer (next-window) a)
    (with-current-buffer dashboard (rsr/agent-sessions--refresh))
    (set-window-buffer (next-window) b)
    (cl-letf (((symbol-function 'rsr/agent-sessions--refresh)
               (lambda () (error "Re-rendered"))))
      (rsr/agent-sessions--mark-on-screen dashboard))
    (should-not (rsr/agent-sessions-test--row-marks dashboard "alpha"))
    (should (rsr/agent-sessions-test--marked-p dashboard "beta"))
    ;; Nothing beside the dashboard: no row is marked.
    (set-window-buffer (next-window) other)
    (rsr/agent-sessions--mark-on-screen dashboard)
    (should-not (rsr/agent-sessions-test--row-marks dashboard "beta"))))

(ert-deftest rsr/agent-sessions-on-screen-update-is-debounced ()
  "A burst of window changes schedules one update, and none without a dashboard."
  (rsr/agent-sessions-test--with-on-screen
    (let ((scheduled 0))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest _) (cl-incf scheduled) (timer-create))))
        (dotimes (_ 3) (rsr/agent-sessions--mark-on-screen-soon))
        (should (= scheduled 1))
        (setq rsr/agent-sessions--on-screen-timer nil)
        (set-window-buffer (selected-window) other)
        (rsr/agent-sessions--mark-on-screen-soon)
        (should (= scheduled 1))))))

(ert-deftest rsr/agent-sessions-on-screen-update-runs-from-the-timer ()
  "The scheduled update still knows its dashboard when the timer fires.
agent-sessions.el is dynamically bound, so a lambda closing over a `let'
variable loses it once the scheduling function returns."
  (rsr/agent-sessions-test--with-on-screen
    (set-window-buffer (next-window) a)
    (with-current-buffer dashboard (rsr/agent-sessions--refresh))
    (set-window-buffer (next-window) b)
    (let (pending)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args)
                   (setq pending (cons fn args))
                   (timer-create))))
        (rsr/agent-sessions--mark-on-screen-soon))
      (apply (car pending) (cdr pending)))
    (should (rsr/agent-sessions-test--marked-p dashboard "beta"))
    (should-not rsr/agent-sessions--on-screen-timer)))

(ert-deftest rsr/agent-sessions-on-screen-update-reads-clients-afresh ()
  "A window change is when a client moves, so the update asks tmux again."
  (rsr/agent-sessions-test--with-on-screen
    (let ((forgot nil))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args) (apply fn args) (timer-create)))
                ((symbol-function 'rsr/agent-tmux-forget-clients)
                 (lambda () (setq forgot t))))
        (rsr/agent-sessions--mark-on-screen-soon)
        (should forgot)))))

;; C-c i l: back to the last agent

(ert-deftest rsr/agent-sessions-display-here-reuses-a-showing-window ()
  "A BUFFER already in the other window: that window, nothing replaced here."
  (let ((buf (get-buffer-create " *here-shown-test*"))
        (mine (get-buffer-create " *here-mine-test*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer mine)
          (let ((other (split-window-right)))
            (set-window-buffer other buf)
            (should (eq (rsr/agent-sessions--display-buffer-here buf nil) other))
            (should (eq (window-buffer (selected-window)) mine))))
      (mapc #'kill-buffer (list buf mine)))))

(ert-deftest rsr/agent-sessions-display-here-uses-the-selected-window ()
  "A BUFFER on no window replaces the selected window's buffer, like C-x <left>."
  (let ((buf (get-buffer-create " *here-new-test*"))
        (mine (get-buffer-create " *here-mine-test*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer mine)
          (set-window-buffer (split-window-right) (get-buffer-create "*scratch*"))
          (should (eq (rsr/agent-sessions--display-buffer-here buf nil)
                      (selected-window)))
          (should (eq (window-buffer (selected-window)) buf)))
      (mapc #'kill-buffer (list buf mine)))))

(ert-deftest rsr/agent-sessions-display-here-declines-a-side-window ()
  "From a side window (the dashboard) it declines, so the usual action applies."
  (let ((buf (get-buffer-create " *here-new-test*"))
        (side (get-buffer-create " *here-side-test*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (select-window (display-buffer-in-side-window side '((side . left))))
          (should-not (rsr/agent-sessions--display-buffer-here buf nil))
          (should (eq (window-buffer (selected-window)) side)))
      (mapc #'kill-buffer (list buf side)))))

(defmacro rsr/agent-sessions-test--with-last-agent (&rest body)
  "Run BODY with agents `x', `y', `z', a shell `s' and a *tmux: repo* `term'.
`--show-terminal' is stubbed: it pushes (BUFFER . OVERRIDING-ACTION) onto
`shown', stamps BUFFER and records it as focused, as the real path does.
Set `rsr/agent-sessions--last-focused-buffer' to what is in front.  `stamp' sets a viewed time
N seconds after the epoch, so every stamp is older than a press."
  (declare (indent 0) (debug t))
  `(let* ((rsr/agent-sessions (make-hash-table :test 'equal))
          (rsr/agent-sessions--last-focused-buffer nil)
          (rsr/agent-session-id->buffer (make-hash-table :test 'equal))
          (x (get-buffer-create " *last-x*"))
          (y (get-buffer-create " *last-y*"))
          (z (get-buffer-create " *last-z*"))
          (s (get-buffer-create " *last-s*"))
          (term (get-buffer-create " *last-term*"))
          (shown nil)
          (stamp (lambda (buf n)
                   (with-current-buffer buf
                     (setq-local rsr/agent-session--viewed-at (seconds-to-time n))))))
     (ignore stamp)
     (unwind-protect
         (save-window-excursion
           (dolist (pair (list (cons "x" x) (cons "y" y) (cons "z" z) (cons "s" s)))
             (with-current-buffer (cdr pair)
               (setq-local rsr/agent-session-id (car pair)))
             (puthash (car pair) (cdr pair) rsr/agent-session-id->buffer)
             (unless (equal (car pair) "s")
               (puthash (car pair) (list :buffer (cdr pair)) rsr/agent-sessions)))
           (with-current-buffer term
             (setq-local rsr/agent-tmux-session "repo"))
           (delete-other-windows)
           (switch-to-buffer term)
           (cl-letf (((symbol-function 'rsr/agent-sessions--show-terminal)
                      (lambda (buf &optional _display)
                        (push (cons buf display-buffer-overriding-action) shown)
                        (setq rsr/agent-sessions--last-focused-buffer buf)
                        (with-current-buffer buf
                          (setq-local rsr/agent-session--viewed-at (current-time))))))
             ,@body))
       (dolist (buf (list x y z s term))
         (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest rsr/agent-sessions-last-agent-goes-back-and-toggles ()
  "From Y's *tmux: S*, the last agent is X; pressing again returns to Y."
  (rsr/agent-sessions-test--with-last-agent
    (funcall stamp x 1)
    (funcall stamp y 2)
    (setq rsr/agent-sessions--last-focused-buffer y)
    (rsr/agent-sessions-visit-last-agent)
    (should (eq (car (car shown)) x))
    (rsr/agent-sessions-visit-last-agent)
    (should (eq (car (car shown)) y))))

(ert-deftest rsr/agent-sessions-last-agent-from-a-non-terminal ()
  "From an ordinary buffer, the last agent is the newest one."
  (rsr/agent-sessions-test--with-last-agent
    (funcall stamp x 1)
    (funcall stamp y 2)
    (switch-to-buffer (get-buffer-create "*scratch*"))
    (setq rsr/agent-sessions--last-focused-buffer (current-buffer))
    (rsr/agent-sessions-visit-last-agent)
    (should (eq (car (car shown)) y))))

(ert-deftest rsr/agent-sessions-last-agent-from-a-shell ()
  "A plain shell is not an agent in front: the newest agent is the last one."
  (rsr/agent-sessions-test--with-last-agent
    (funcall stamp x 1)
    (funcall stamp y 2)
    (funcall stamp s 3)
    (switch-to-buffer s)
    (setq rsr/agent-sessions--last-focused-buffer s)
    (rsr/agent-sessions-visit-last-agent)
    (should (eq (car (car shown)) y))))

(ert-deftest rsr/agent-sessions-last-agent-skips-closed ()
  "A closed agent drops out for the next most recent live one."
  (rsr/agent-sessions-test--with-last-agent
    (funcall stamp x 1)
    (funcall stamp z 2)
    (funcall stamp y 3)
    (setq rsr/agent-sessions--last-focused-buffer y)
    (kill-buffer z)
    (rsr/agent-sessions-visit-last-agent)
    (should (eq (car (car shown)) x))))

(ert-deftest rsr/agent-sessions-last-agent-none ()
  "With no other agent viewed, it says so and shows nothing."
  (rsr/agent-sessions-test--with-last-agent
    (funcall stamp y 1)
    (setq rsr/agent-sessions--last-focused-buffer y)
    (let ((said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (rsr/agent-sessions-visit-last-agent))
      (should-not shown)
      (should (equal said "No previous agent session")))))

(ert-deftest rsr/agent-sessions-last-agent-ignores-shells ()
  "A stamped plain shell is never chosen, even as the newest."
  (rsr/agent-sessions-test--with-last-agent
    (funcall stamp x 1)
    (funcall stamp y 2)
    (funcall stamp s 3)
    (setq rsr/agent-sessions--last-focused-buffer y)
    (rsr/agent-sessions-visit-last-agent)
    (should (eq (car (car shown)) x))))

(ert-deftest rsr/agent-sessions-last-agent-from-a-tmux-shell ()
  "A *tmux: S* on a window that is no agent: the newest agent is the last one."
  (rsr/agent-sessions-test--with-last-agent
    (funcall stamp x 1)
    (funcall stamp y 2)
    (setq rsr/agent-sessions--last-focused-buffer term)
    (rsr/agent-sessions-visit-last-agent)
    (should (eq (car (car shown)) y))))

(ert-deftest rsr/agent-sessions-last-agent-uses-display-here ()
  "It shows the agent through `rsr/agent-sessions--display-buffer-here'."
  (rsr/agent-sessions-test--with-last-agent
    (funcall stamp x 1)
    (funcall stamp y 2)
    (setq rsr/agent-sessions--last-focused-buffer y)
    (rsr/agent-sessions-visit-last-agent)
    (should (equal (cdr (car shown)) '(rsr/agent-sessions--display-buffer-here)))))

;;; agy

(defun rsr/agent-hook-test--agy-events (events)
  "Feed agy EVENTS through the real hook script; return the row after each.
Each payload is camelCase with no event name, as agy sends it."
  (rsr/agent-sessions-test--with-temp-db
    (let* ((directory (make-temp-file "agent-hook-agy-" t))
           (term (generate-new-buffer " *agent-hook-agy*"))
           (script (expand-file-name rsr/agent-sessions--agy-hook-script
                                     rsr/agent-sessions--dir))
           (bin (make-temp-file "agent-hook-agy-bin-" t))
           (rsr/agent-session-id->buffer (make-hash-table :test 'equal))
           (rsr/agent-sessions (make-hash-table :test 'equal))
           (rsr/agent-sessions--last-focused-buffer nil)
           (rsr/agent-session-notify-on-attention nil)
           rows)
      (unwind-protect
          (progn
            (with-current-buffer term
              (setq-local rsr/agent-session-id "term")
              (setq default-directory (file-name-as-directory directory)))
            (puthash "term" term rsr/agent-session-id->buffer)
            ;; A stand-in emacsclient that keeps the form it was given.
            (with-temp-file (expand-file-name "emacsclient" bin)
              (insert (format "#!/bin/sh\nprintf '%%s' \"$3\" > %s\n"
                              (expand-file-name "form" bin))))
            (set-file-modes (expand-file-name "emacsclient" bin) #o755)
            (cl-letf (((symbol-function 'rsr/agent-sessions--foreground-command)
                       (lambda (_) "agy"))
                      ((symbol-function 'rsr/agent-session--repo-info)
                       (lambda (_) (list :repo "repo" :repo-root directory
                                         :worktree-path directory)))
                      ((symbol-function 'rsr/agent-sessions--detect-parent) #'ignore)
                      ((symbol-function 'rsr/agent-sessions--log-update) #'ignore)
                      ((symbol-function 'rsr/agent-orchestration--hydrate) #'ignore)
                      ((symbol-function 'rsr/agent-orchestration-deliver) #'ignore)
                      ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                       #'ignore))
              (dolist (event events)
                (let* ((process-environment
                        (append (list "EMACS_AGENT_SESSION_ID=term"
                                      (format "PATH=%s:%s" bin (getenv "PATH")))
                                process-environment))
                       (form (progn
                               (with-temp-buffer
                                 (insert (format "{\"conversationId\": \"agy-cid\", \"workspacePaths\": [%S]}"
                                                 directory))
                                 (call-process-region (point-min) (point-max)
                                                      "sh" t t nil script event))
                               (with-temp-buffer
                                 (insert-file-contents (expand-file-name "form" bin))
                                 (buffer-string)))))
                  (eval (car (read-from-string form)) t)
                  (push (gethash "term" rsr/agent-sessions) rows))))
            (nreverse rows))
        (kill-buffer term)
        (delete-directory directory t)
        (delete-directory bin t)))))

(ert-deftest rsr/agent-hook-agy-events-drive-the-row ()
  "agy's own event names move its row like Claude's, keyed by conversationId."
  (let ((rows (rsr/agent-hook-test--agy-events
               '("SessionStart" "PreInvocation" "PostToolUse" "PreInvocation" "Stop"))))
    (should (equal (mapcar (lambda (row) (plist-get row :status)) rows)
                   '(stopped running running running needs-attention)))
    (should (equal (plist-get (car (last rows)) :agent-type) "agy"))
    (should (equal (plist-get (car (last rows)) :agent-session-id) "agy-cid"))
    (should-not (plist-get (car (last rows)) :turn-open))))

(ert-deftest rsr/agent-sessions-wire-agy-keeps-other-tools-hooks ()
  (let* ((file (make-temp-file "agy-hooks-" nil ".json"))
         (rsr/agent-sessions-agy-hooks-file file))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"orca-status\": {\"Stop\": [{\"command\": \"orca\"}]}}"))
          (rsr/agent-sessions--wire-agy "/pkg/agent-sessions-agy-hook.sh")
          (rsr/agent-sessions--wire-agy "/pkg/agent-sessions-agy-hook.sh")
          (let* ((root (rsr/agent-sessions--read-json file))
                 (ours (gethash "agent-sessions" root)))
            (should (gethash "orca-status" root))
            (should (equal (gethash "command" (aref (gethash "Stop" ours) 0))
                           "/pkg/agent-sessions-agy-hook.sh Stop"))
            (should (equal (gethash "matcher" (aref (gethash "PostToolUse" ours) 0))
                           "*"))
            (should (= (length (gethash "PreInvocation" ours)) 1)))
          (should (rsr/agent-sessions--unwire-agy))
          (let ((root (rsr/agent-sessions--read-json file)))
            (should-not (gethash "agent-sessions" root))
            (should (gethash "orca-status" root)))
          (should-not (rsr/agent-sessions--unwire-agy)))
      (delete-file file)
      (dolist (backup (file-expand-wildcards (concat file "*")))
        (delete-file backup)))))

(ert-deftest rsr/agent-orchestration-agy-is-a-worker-type ()
  (should (equal (rsr/agent-orchestration--launch-command
                  (alist-get 'agy rsr/agent-orchestration-launch-commands)
                  "/b/brief.md"
                  (rsr/agent-orchestration--model-flag 'agy "gemini-x"))
                 "agy --model gemini-x -i \"$(cat /b/brief.md)\"")))

(provide 'agent-sessions-test)
;;; agent-sessions-test.el ends here
