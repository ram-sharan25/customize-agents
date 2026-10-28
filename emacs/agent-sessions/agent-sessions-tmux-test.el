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
