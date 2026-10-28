;;; agent-sessions-tmux-test.el --- Tests for the tmux backend  -*- lexical-binding: t; -*-

;; tmux is faked: `rsr/agent-tmux--call' is replaced by a function that records
;; each argv and answers from a script, so nothing here touches a real server.

(require 'ert)
(require 'agent-sessions)

(defvar rsr/agent-tmux-test--calls nil
  "Recorded (ARGS . INPUT) pairs, oldest first.")

(defmacro rsr/agent-tmux-test--with-fake (responder &rest body)
  "Run BODY with tmux faked by RESPONDER, a function of ARGS returning OUTPUT.
OUTPUT nil means the call failed.  Uses a throwaway database and kills every
proxy BODY leaves behind."
  (declare (indent 1) (debug t))
  `(let* ((rsr/agent-tmux-test--calls nil)
          (db-file (make-temp-file "agent-sessions-tmux-test-"))
          (rsr/agent-sessions-db-file db-file)
          (rsr/agent-sessions--db nil)
          (rsr/agent-tmux--panes nil)
          (rsr/agent-tmux--active-cache nil)
          (responder ,responder))
     (cl-letf (((symbol-function 'rsr/agent-tmux--call)
                (lambda (args &optional input)
                  (setq rsr/agent-tmux-test--calls
                        (append rsr/agent-tmux-test--calls (list (cons args input))))
                  (let ((out (funcall responder args)))
                    (if out (cons 0 out) (cons 1 "")))))
               ((symbol-function 'rsr/agent-tmux-show) #'ignore)
               ((symbol-function 'rsr/agent-sessions--refresh-if-visible) #'ignore))
       (unwind-protect
           (progn ,@body)
         (dolist (b (rsr/agent-tmux-proxies))
           (with-current-buffer b (setq rsr/agent-tmux--window-gone t))
           (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
         (when (sqlitep rsr/agent-sessions--db) (sqlite-close rsr/agent-sessions--db))
         (dolist (f (list db-file (concat db-file "-wal") (concat db-file "-shm")))
           (when (file-exists-p f) (delete-file f)))))))

(defun rsr/agent-tmux-test--called (subcommand)
  "Recorded argv lists whose first element is SUBCOMMAND."
  (seq-filter (lambda (c) (equal (caar c) subcommand))
              (mapcar #'identity rsr/agent-tmux-test--calls)))

(defun rsr/agent-tmux-test--standard (args &optional panes)
  "A responder: session exists, new windows are @7, PANES is list-panes output."
  (pcase (car args)
    ("has-session" "")
    ("new-window" "@7\n")
    ("list-panes" (or panes "@7\t4242\tClaude Code\n"))
    (_ "")))

(defun rsr/agent-tmux-test--open-proxy ()
  "Open a tmux terminal through agent-sessions; return its proxy."
  (let ((dir (make-temp-file "tmux-test-repo-" t)))
    (make-directory (expand-file-name ".git" dir))
    (let ((rsr/agent-sessions-terminal 'tmux))
      (rsr/agent-sessions--create-terminal dir))))

;;; Naming and targets

(ert-deftest rsr/agent-tmux-session-name-is-safe ()
  (should (equal (rsr/agent-tmux-session-name "my repo.v2:x") "my-repo-v2-x")))

(ert-deftest rsr/agent-tmux-target-uses-repository-root ()
  (let* ((root (make-temp-file "tmux-test-repo-" t))
         (sub (expand-file-name "a/b" root)))
    (make-directory (expand-file-name ".git" root))
    (make-directory sub t)
    (should (equal (rsr/agent-tmux-target sub)
                   (cons (rsr/agent-tmux-session-name
                          (file-name-nondirectory root))
                         (file-name-as-directory root))))))

(ert-deftest rsr/agent-tmux-target-asks-outside-a-repository ()
  (let ((dir (make-temp-file "tmux-test-plain-" t)))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) " my sess ")))
      (should (equal (rsr/agent-tmux-target dir)
                     (cons "my-sess" (expand-file-name dir)))))))

(defun rsr/agent-tmux-test--worktree (main folder &optional name)
  "Make a fake linked worktree FOLDER of MAIN, registered as NAME."
  (let ((wt (expand-file-name folder (file-name-directory (directory-file-name main)))))
    (make-directory wt t)
    (with-temp-file (expand-file-name ".git" wt)
      (insert (format "gitdir: %s/.git/worktrees/%s\n"
                      (directory-file-name main) (or name folder))))
    wt))

(ert-deftest rsr/agent-tmux-target-names-worktrees-repo-slash-worktree ()
  (let* ((parent (make-temp-file "tmux-test-wt-" t))
         (main (expand-file-name "proj" parent)))
    (make-directory (expand-file-name ".git" main) t)
    (let ((prefixed (rsr/agent-tmux-test--worktree main "proj-feature" "feature"))
          (plain (rsr/agent-tmux-test--worktree main "scratch")))
      (should (equal (car (rsr/agent-tmux-target (expand-file-name "src" main))) "proj"))
      (should (equal (rsr/agent-tmux-target prefixed)
                     (cons "proj/feature" (file-name-as-directory prefixed))))
      (should (equal (car (rsr/agent-tmux-target plain)) "proj/scratch")))))

(ert-deftest rsr/agent-tmux-target-treats-other-git-files-as-own-checkout ()
  (let ((dir (make-temp-file "tmux-test-sub-" t)))
    (with-temp-file (expand-file-name ".git" dir)
      (insert "gitdir: ../.git/modules/lib\n"))
    (should (equal (car (rsr/agent-tmux-target dir))
                   (rsr/agent-tmux-session-name (file-name-nondirectory dir))))))

(ert-deftest rsr/agent-tmux-target-matches-real-git-worktree ()
  (skip-unless (executable-find "git"))
  (let* ((parent (make-temp-file "tmux-test-realwt-" t))
         (main (expand-file-name "app" parent))
         (wt (expand-file-name "app-hotfix" parent)))
    (make-directory main)
    (let ((default-directory (file-name-as-directory main)))
      (call-process "git" nil nil nil "init" "-q")
      (call-process "git" nil nil nil "-c" "user.email=t@t" "-c" "user.name=t"
                    "commit" "-q" "--allow-empty" "-m" "init")
      (call-process "git" nil nil nil "worktree" "add" "-q" "-b" "hotfix" wt))
    (should (equal (rsr/agent-tmux-target wt)
                   (cons "app/hotfix" (file-name-as-directory wt))))))

;;; Folders outside git

(ert-deftest rsr/agent-tmux-plain-folder-groups-by-session ()
  (rsr/agent-tmux-test--with-fake
      (lambda (args)
        (if (equal (car args) "display-message")
            "/Users/me/study-root"
          (rsr/agent-tmux-test--standard args)))
    (let* ((dir (make-temp-file "tmux-test-plain-" t))
           (rsr/agent-tmux--session-paths (make-hash-table :test 'equal))
           (rsr/agent-sessions--repo-info-cache nil)
           (proxy (let ((rsr/agent-tmux--target (cons "study" dir))
                        (rsr/agent-sessions-terminal 'tmux))
                    (rsr/agent-sessions--create-terminal dir)))
           (info (rsr/agent-sessions--buffer-repo-info proxy)))
      (should (equal (plist-get info :repo) "study"))
      (should (equal (plist-get info :worktree) "study"))
      (should (equal (plist-get info :repo-root) "/Users/me/study-root/"))
      (should (equal (plist-get info :worktree-path)
                     (rsr/agent-sessions--canonical-path dir)))
      ;; The log keeps the session name as the label, for resume.
      (should (equal (caar (sqlite-select (rsr/agent-sessions--db)
                                          "SELECT label FROM sessions"))
                     "study")))))

(ert-deftest rsr/agent-tmux-resume-in-plain-folder-reuses-session ()
  (let ((dir (make-temp-file "tmux-test-plain-" t))
        (repo (make-temp-file "tmux-test-repo-" t))
        seen)
    (make-directory (expand-file-name ".git" repo))
    (cl-letf (((symbol-function 'rsr/agent-sessions--buffer-for-agent-session) #'ignore)
              ((symbol-function 'rsr/agent-sessions--restore-title) #'ignore)
              ((symbol-function 'rsr/agent-session-start)
               (lambda (&rest _) (push rsr/agent-tmux--target seen) nil)))
      (rsr/agent-sessions--restore-row
       (list :worktree dir :agent-sid "s1" :agent-type "claude" :label "study"))
      (rsr/agent-sessions--restore-row
       (list :worktree repo :agent-sid "s2" :agent-type "claude" :label "main")))
    (should (equal (nreverse seen) (list (cons "study" dir) nil)))))

;;; Screen text

(ert-deftest rsr/agent-tmux-faint-text-marks-faint-runs ()
  (let ((text (rsr/agent-tmux-faint-text
               "\e[1mbold\e[0m \e[2mghost\e[22m typed \e[2mmore\e[m end\e[?25l")))
    (should (equal (substring-no-properties text) "bold ghost typed more end"))
    (should (eq (get-text-property (string-search "ghost" text) 'face text)
                'rsr/agent-tmux-faint))
    (should (eq (get-text-property (string-search "more" text) 'face text)
                'rsr/agent-tmux-faint))
    (should-not (get-text-property (string-search "typed" text) 'face text))
    (should-not (get-text-property (string-search "end" text) 'face text))))

(ert-deftest rsr/agent-tmux-faint-text-handles-multi-parameter-sgr ()
  "Real screens use 38;2;R;G;B and 38;5;N.  Once looped forever (match data
clobbered by `split-string'); the 2 of 38;2 must not read as faint."
  (let ((text (with-timeout (2 (ert-fail "faint-text did not terminate"))
                (rsr/agent-tmux-faint-text
                 (concat "\e[38;2;255;0;0mred\e[0m "
                         "\e[2;38;5;240mghost\e[22;39m "
                         "\e[48;2;1;2;3;1mbold\e[m "
                         "\e[38:2::9:9:9mcolon\e[0m")))))
    (should (equal (substring-no-properties text) "red ghost bold colon"))
    (should-not (get-text-property (string-search "red" text) 'face text))
    (should (eq (get-text-property (string-search "ghost" text) 'face text)
                'rsr/agent-tmux-faint))
    (should-not (get-text-property (string-search "bold" text) 'face text))
    (should-not (get-text-property (string-search "colon" text) 'face text))))

(ert-deftest rsr/agent-tmux-composer-keeps-inline-completion-distinct ()
  (dolist (case '(("❯ \e[2mrun the tests\e[0m\n────────\n\n\n" . t)
                  ("❯ run the \e[2mtests\e[0m\n────────\n" . nil)))
    (let ((screen (car case)))
      (rsr/agent-tmux-test--with-fake
          (lambda (args)
            (pcase (car args)
              ("capture-pane" screen)
              (_ (rsr/agent-tmux-test--standard args))))
        (let* ((proxy (rsr/agent-tmux-test--open-proxy))
               (session (list :buffer proxy :agent-type "claude")))
          (should (eq (and (rsr/agent-orchestration--claude-receptive-composer-p session) t)
                      (cdr case))))))))

(ert-deftest rsr/agent-tmux-unreadable-screen-is-not-receptive ()
  (rsr/agent-tmux-test--with-fake
      (lambda (args)
        (unless (equal (car args) "capture-pane")
          (rsr/agent-tmux-test--standard args)))
    (let ((proxy (rsr/agent-tmux-test--open-proxy)))
      (should-not (rsr/agent-orchestration--claude-receptive-composer-p
                   (list :buffer proxy :agent-type "claude"))))))

;;; Opening and I/O

(ert-deftest rsr/agent-tmux-open-registers-proxy-with-environment ()
  (rsr/agent-tmux-test--with-fake #'rsr/agent-tmux-test--standard
    (let* ((proxy (rsr/agent-tmux-test--open-proxy))
           (id (buffer-local-value 'rsr/agent-session-id proxy))
           (argv (caar (rsr/agent-tmux-test--called "new-window"))))
      (should (rsr/agent-tmux-proxy-p proxy))
      (should (equal (buffer-local-value 'rsr/agent-tmux-window proxy) "@7"))
      (should (eq (gethash id rsr/agent-session-id->buffer) proxy))
      (should (eq (rsr/agent-sessions--buffer-terminal-type proxy) 'tmux))
      (should (member (format "EMACS_AGENT_SESSION_ID=%s" id) argv))
      (should (seq-some (lambda (a) (string-prefix-p "PATH=" a)) argv))
      (should (member "CLAUDE_CODE_CHILD_SESSION" argv))
      (should (equal (nth (1+ (seq-position argv "-u")) argv) "CLAUDECODE")))))

(ert-deftest rsr/agent-tmux-send-paste-and-input-reach-the-window ()
  (rsr/agent-tmux-test--with-fake #'rsr/agent-tmux-test--standard
    (let ((proxy (rsr/agent-tmux-test--open-proxy)))
      (setq rsr/agent-tmux-test--calls nil)
      (rsr/agent-sessions--terminal-send proxy "claude")
      (rsr/agent-sessions--terminal-paste proxy "line one\nline two")
      (rsr/agent-orchestration--terminal-input proxy "\r")
      (should (equal (mapcar #'car rsr/agent-tmux-test--calls)
                     '(("send-keys" "-t" "@7" "-l" "--" "claude")
                       ("send-keys" "-t" "@7" "Enter")
                       ("load-buffer" "-b" "agent-sessions-paste" "-")
                       ("paste-buffer" "-p" "-d" "-b" "agent-sessions-paste" "-t" "@7")
                       ("send-keys" "-t" "@7" "-l" "--" "\r"))))
      (should (equal (cdr (nth 2 rsr/agent-tmux-test--calls)) "line one\nline two")))))

(ert-deftest rsr/agent-tmux-foreground-command-uses-pane-pid ()
  (rsr/agent-tmux-test--with-fake #'rsr/agent-tmux-test--standard
    (let ((proxy (rsr/agent-tmux-test--open-proxy)))
      (cl-letf (((symbol-function 'process-attributes)
                 (lambda (pid)
                   (pcase pid
                     (4242 '((tpgid . 5000) (pgrp . 4242)))
                     (5000 '((args . "/opt/homebrew/bin/claude --resume x")))))))
        (should (equal (rsr/agent-sessions--foreground-command proxy) "claude"))
        (should (rsr/agent-sessions--tpgid-readable-p proxy))))))

;;; Liveness, jumping, killing

(ert-deftest rsr/agent-tmux-closed-window-drops-row-and-reaps-proxy ()
  (let ((panes "@7\t4242\tClaude\n"))
    (rsr/agent-tmux-test--with-fake
        (lambda (args) (rsr/agent-tmux-test--standard args panes))
      (let* ((proxy (rsr/agent-tmux-test--open-proxy))
             (id (buffer-local-value 'rsr/agent-session-id proxy)))
        (should (seq-find (lambda (e) (equal (plist-get e :id) id))
                          (rsr/agent-sessions--live-entries)))
        (setq panes "@1\t99\tother\n"
              rsr/agent-tmux--panes nil)
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_time _repeat fn &rest args) (apply fn args))))
          (should-not (seq-find (lambda (e) (equal (plist-get e :id) id))
                                (rsr/agent-sessions--live-entries))))
        (should-not (buffer-live-p proxy))
        (should-not (gethash id rsr/agent-session-id->buffer))
        (should-not (rsr/agent-tmux-test--called "kill-window"))))))

(ert-deftest rsr/agent-tmux-title-follows-pane-title ()
  (rsr/agent-tmux-test--with-fake
      (lambda (args) (rsr/agent-tmux-test--standard args "@7\t4242\t✳ Fix the parser\n"))
    (let ((proxy (rsr/agent-tmux-test--open-proxy)))
      (rsr/agent-sessions--live-entries)
      (should (equal (buffer-local-value 'rsr/agent-session-title proxy)
                     "✳ Fix the parser")))))

(ert-deftest rsr/agent-tmux-jump-selects-window ()
  (rsr/agent-tmux-test--with-fake #'rsr/agent-tmux-test--standard
    (let ((proxy (rsr/agent-tmux-test--open-proxy)))
      (setq rsr/agent-tmux-test--calls nil)
      (rsr/agent-sessions--show-terminal proxy)
      (should (equal (caar (rsr/agent-tmux-test--called "select-window"))
                     '("select-window" "-t" "@7")))
      (should (buffer-local-value 'rsr/agent-session--viewed-at proxy)))))

(ert-deftest rsr/agent-tmux-killing-proxy-closes-its-window ()
  (rsr/agent-tmux-test--with-fake #'rsr/agent-tmux-test--standard
    (let ((proxy (rsr/agent-tmux-test--open-proxy)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (kill-buffer proxy))
      (should-not (buffer-live-p proxy))
      (should (equal (caar (rsr/agent-tmux-test--called "kill-window"))
                     '("kill-window" "-t" "@7"))))))

;;; Live, against a real tmux server on a private socket

(ert-deftest rsr/agent-tmux-live-window-gets-session-environment ()
  "Opens a real window, checks its environment and I/O, closes it.
Runs on its own server (empty config, private socket) and kills it after."
  (skip-unless (executable-find "tmux"))
  (let* ((rsr/agent-tmux-socket (format "agent-sessions-test-%d" (emacs-pid)))
         (rsr/agent-tmux--panes nil)
         (db-file (make-temp-file "agent-sessions-tmux-live-"))
         (rsr/agent-sessions-db-file db-file)
         (rsr/agent-sessions--db nil)
         (repo (make-temp-file "tmux-live-repo-" t))
         (out (expand-file-name "id.txt" repo))
         (rsr/agent-sessions-terminal 'tmux))
    (make-directory (expand-file-name ".git" repo))
    ;; Start the server with no config, so ~/.tmux.conf hooks never run here.
    (call-process "tmux" nil nil nil "-L" rsr/agent-tmux-socket "-f" "/dev/null"
                  "new-session" "-d" "-s" "bootstrap")
    (cl-letf (((symbol-function 'rsr/agent-tmux-show) #'ignore)
              ((symbol-function 'rsr/agent-sessions--refresh-if-visible) #'ignore))
      (unwind-protect
          (let* ((proxy (rsr/agent-sessions--create-terminal repo))
                 (id (buffer-local-value 'rsr/agent-session-id proxy))
                 (window (buffer-local-value 'rsr/agent-tmux-window proxy)))
            (should (gethash window (rsr/agent-tmux-panes)))
            (rsr/agent-sessions--terminal-send
             proxy (format "printf '%%s|%%s' \"$EMACS_AGENT_SESSION_ID\" \"$PATH\" > %s"
                           (shell-quote-argument out)))
            (let ((deadline (+ (float-time) 10)))
              (while (and (not (file-exists-p out)) (< (float-time) deadline))
                (sleep-for 0.1)))
            (pcase-let ((`(,got-id ,path)
                         (split-string (with-temp-buffer (insert-file-contents out)
                                                         (buffer-string))
                                       "|")))
              (should (equal got-id id))
              ;; emacs-share must be on the window's PATH (tmux drops -e PATH).
              (should (member rsr/agent-sessions--bin-dir (split-string path ":"))))
            (should (rsr/agent-tmux-refresh-screen proxy))
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
              (kill-buffer proxy))
            (rsr/agent-tmux-forget-panes)
            (should-not (gethash window (rsr/agent-tmux-panes))))
        (call-process "tmux" nil nil nil "-L" rsr/agent-tmux-socket "kill-server")
        (let ((socket (expand-file-name rsr/agent-tmux-socket
                                        (format "/tmp/tmux-%d" (user-uid)))))
          (when (file-exists-p socket) (delete-file socket)))
        (when (sqlitep rsr/agent-sessions--db) (sqlite-close rsr/agent-sessions--db))
        (dolist (f (list db-file (concat db-file "-wal") (concat db-file "-shm")))
          (when (file-exists-p f) (delete-file f)))))))

;;; agent-sessions-tmux-test.el ends here
