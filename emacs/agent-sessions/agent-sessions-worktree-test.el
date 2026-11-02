;;; agent-sessions-worktree-test.el --- Tests for `Z' and repo migration  -*- lexical-binding: t; -*-

;; Real git in throwaway directories; tmux, the terminal and the prompts are
;; faked, so nothing here touches a real repo, server or Emacs session.

(require 'ert)
(require 'agent-sessions)

(defconst rsr/agent-wt-test--report
  (symbol-function 'rsr/agent-sessions--migration-report)
  "The real migration report, which the test environment fakes.")

(defmacro rsr/agent-wt-test--with-env (&rest body)
  "Run BODY in a temp directory `tmp' with a throwaway database and fake tmux.
`panes' (initially empty) is what tmux reports as list-panes output, and
`tmux-calls' the argv of each tmux call, newest first.  Timers are queued
in `timers', run by `rsr/agent-wt-test--run-timers'."
  (declare (indent 0) (debug t))
  `(let* ((tmp (file-name-as-directory (file-truename (make-temp-file "agent-wt-" t))))
          (db-file (expand-file-name "test.db" tmp))
          (rsr/agent-sessions-db-file db-file)
          (rsr/agent-sessions--db nil)
          (rsr/agent-sessions--folders-loaded-p nil)
          (rsr/agent-sessions--folders nil)
          (rsr/agent-sessions--order nil)
          (rsr/agent-sessions (make-hash-table :test 'equal))
          (rsr/agent-sessions-symlink-directories nil)
          (rsr/agent-sessions-history-directories nil)
          (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                         "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t")
                                       process-environment))
          (panes "")
          (tmux-calls nil)
          (timers nil))
     (cl-letf (((symbol-function 'rsr/agent-tmux--call)
                (lambda (args &optional _input)
                  (push args tmux-calls)
                  (pcase (car args)
                    ("list-panes" (cons 0 panes))
                    ("kill-pane" (setq panes "") (cons 0 ""))
                    (_ (cons 1 "")))))
               ((symbol-function 'run-at-time)
                (lambda (_time _repeat fn &rest args)
                  (push (cons fn args) timers)))
               ((symbol-function 'rsr/agent-sessions--refresh-if-visible) #'ignore)
               ((symbol-function 'rsr/agent-sessions--migration-report) #'ignore))
       (unwind-protect (progn ,@body)
         (when (sqlitep rsr/agent-sessions--db) (sqlite-close rsr/agent-sessions--db))
         (delete-directory tmp t)))))

(defmacro rsr/agent-wt-test--run-timers ()
  "Run the timers queued in `timers', oldest first, outside their callers."
  '(dolist (timer (prog1 (reverse timers) (setq timers nil)))
     (apply (car timer) (cdr timer))))

(defun rsr/agent-wt-test--git (dir &rest args)
  "Run git ARGS in DIR, failing the test if it fails; return its output."
  (pcase-let ((`(,status . ,out) (apply #'rsr/agent-sessions--git dir args)))
    (should (eq status 0))
    out))

(defun rsr/agent-wt-test--repo (dir branch)
  "Make a git repo at DIR with one commit, on BRANCH; return DIR as a directory."
  (make-directory dir t)
  (rsr/agent-wt-test--git dir "init" "-q" "-b" branch)
  (write-region "x" nil (expand-file-name "file.txt" dir))
  (rsr/agent-wt-test--git dir "add" "file.txt")
  (rsr/agent-wt-test--git dir "commit" "-q" "-m" "init")
  (file-name-as-directory dir))

(ert-deftest rsr/agent-wt-recorded-repo-name-names-checkouts ()
  (rsr/agent-wt-test--with-env
    (let* ((main (rsr/agent-wt-test--repo (expand-file-name "proj/trunk" tmp) "trunk"))
           (side (expand-file-name "proj/feature" tmp)))
      (rsr/agent-wt-test--git main "worktree" "add" "-q" "-b" "feature" side)
      (should-not (rsr/agent-tmux-recorded-repo-name main))
      (should (equal (car (rsr/agent-tmux-checkout main)) "trunk"))
      (rsr/agent-wt-test--git main "config" "agent-sessions.repo-name" "proj")
      (should (equal (rsr/agent-tmux-recorded-repo-name main) "proj"))
      (should (equal (rsr/agent-tmux-checkout main) (list "proj" nil main main)))
      (should (equal (seq-take (rsr/agent-tmux-checkout side) 2) '("proj" "feature")))
      (should (equal (plist-get (rsr/agent-session--repo-info side) :repo) "proj")))))

(ert-deftest rsr/agent-wt-history-folder-names ()
  (should (equal (rsr/agent-sessions--history-folder-name 'claude "/a/b_c.d/")
                 "-a-b-c-d"))
  (should (equal (rsr/agent-sessions--history-folder-name 'pi "/a/b_c.d")
                 "--a-b_c.d--")))

(ert-deftest rsr/agent-wt-migrate-moves-checkout-and-everything-keyed-on-it ()
  (rsr/agent-wt-test--with-env
    (let* ((root (rsr/agent-wt-test--repo (expand-file-name "proj" tmp) "feat/x"))
           (main (expand-file-name "feat-x/" root))
           (side (expand-file-name "proj_side" tmp))
           (home (expand-file-name "home" tmp))
           (link (expand-file-name "conf" home))
           (store (expand-file-name "projects" tmp))
           (rsr/agent-sessions-symlink-directories (list (cons home 1)))
           (rsr/agent-sessions-history-directories (list (cons store 'claude)))
           (old-history (expand-file-name
                         (rsr/agent-sessions--history-folder-name 'claude (concat root "sub"))
                         store))
           ;; Shares the old root's name as a prefix; must be left alone.
           (other-history (expand-file-name
                           (rsr/agent-sessions--history-folder-name 'claude side)
                           store)))
      (rsr/agent-wt-test--git root "worktree" "add" "-q" "-b" "side" side)
      (make-directory home)
      (make-symbolic-link (expand-file-name "file.txt" root) link)
      (dolist (pair (list (cons old-history (concat root "sub"))
                          (cons other-history side)))
        (make-directory (car pair) t)
        (write-region (format "{\"cwd\":\"%s\"}\n" (cdr pair)) nil
                      (expand-file-name "s.jsonl" (car pair))))
      (rsr/agent-sessions--folder-create "keep" root)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (should (equal (let ((default-directory root))
                         (rsr/agent-sessions--migrate-repo root))
                       main)))
      (should (file-directory-p (expand-file-name ".git" main)))
      (should (file-exists-p (expand-file-name "file.txt" main)))
      (should (equal (rsr/agent-tmux-recorded-repo-name main) "proj"))
      ;; The linked worktree still finds its repo.
      (should (equal (rsr/agent-wt-test--git side "rev-parse" "--abbrev-ref" "HEAD")
                     "side"))
      (should (equal (file-symlink-p link) (expand-file-name "file.txt" main)))
      (should (file-directory-p
               (expand-file-name (rsr/agent-sessions--history-folder-name
                                  'claude (concat main "sub"))
                                 store)))
      (should-not (file-exists-p old-history))
      (should (file-directory-p other-history))
      (should (equal (mapcar (lambda (f) (plist-get f :repo))
                             (rsr/agent-sessions--folders-for-repo main))
                     (list main))))))

(ert-deftest rsr/agent-wt-migrate-stops-and-resumes-what-runs-in-repo ()
  (rsr/agent-wt-test--with-env
    (let* ((root (rsr/agent-wt-test--repo (expand-file-name "proj" tmp) "main"))
           (main (expand-file-name "main/" root))
           (agent (generate-new-buffer " agent"))
           (resumed nil))
      (puthash "t1" (list :buffer agent :agent-type "claude" :agent-session-id "abc"
                          :status 'running :worktree-path (concat root "sub/"))
               rsr/agent-sessions)
      (with-current-buffer agent
        (setq-local rsr/agent-session-title-override "mine")
        ;; As a tmux proxy's close prompt is: the migration has already asked.
        (add-hook 'kill-buffer-query-functions (lambda () (error "Asked again")) nil t))
      ;; A shell opened in tmux directly, which no terminal stands for.
      (setq panes (format "%%9\tproj\t@3\tzsh\t%s\n" root))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'rsr/agent-sessions--migration-report)
                 rsr/agent-wt-test--report)
                ((symbol-function 'rsr/agent-sessions--never-saved-p) #'ignore)
                ((symbol-function 'rsr/agent-session-start)
                 (lambda (dir type sid)
                   (push (list dir type sid rsr/agent-sessions-terminal) resumed)
                   (generate-new-buffer " resumed"))))
        (let ((default-directory root))
          (rsr/agent-sessions--migrate-repo root))
        (rsr/agent-wt-test--run-timers))
      ;; The report was shown for the questions, then its window went.
      (should (get-buffer "*agent-sessions migration*"))
      (should-not (get-buffer-window "*agent-sessions migration*" t))
      (should-not (buffer-live-p agent))
      (should (member '("kill-pane" "-t" "%9") tmux-calls))
      (should (file-exists-p (expand-file-name "file.txt" main)))
      (should (equal (car resumed) (list (concat main "sub/") 'claude "abc"
                                         rsr/agent-sessions-terminal)))
      (dolist (buf (buffer-list))
        (when (string-prefix-p " resumed" (buffer-name buf))
          (should (equal (buffer-local-value 'rsr/agent-session-title-override buf)
                         "mine"))
          (kill-buffer buf))))))

(ert-deftest rsr/agent-wt-migrate-refuses-with-unsaved-files ()
  (rsr/agent-wt-test--with-env
    (let* ((root (rsr/agent-wt-test--repo (expand-file-name "proj" tmp) "main"))
           (buf (find-file-noselect (expand-file-name "file.txt" root))))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "edit"))
            (should-error (let ((default-directory root))
                            (rsr/agent-sessions--migrate-repo root))
                          :type 'user-error)
            (should (file-exists-p (expand-file-name "file.txt" root))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest rsr/agent-wt-new-worktree-creates-folder-and-starts-agent ()
  (dolist (case '((claude nil nil "claude") (claude (4) nil "pi")
                  (pi nil nil "pi") (pi (4) nil "claude")
                  (pi nil "claude --verbose" "claude --verbose")
                  (pi (4) "pi --verbose" "claude")))
   (rsr/agent-wt-test--with-env
    (let* ((rsr/agent-sessions-default-agent (nth 0 case))
           (rsr/agent-sessions-worktree-agent (nth 2 case))
           (main (rsr/agent-wt-test--repo (expand-file-name "proj/main" tmp) "main"))
           (sent nil)
           (terminal (generate-new-buffer " fake-terminal"))
           (answers '("feat/new")))
      (rsr/agent-wt-test--git main "config" "agent-sessions.repo-name" "proj")
      (rsr/agent-wt-test--git main "branch" "old")
      (cl-letf (((symbol-function 'magit-completing-read)
                 (lambda (&rest _) (pop answers)))
                ((symbol-function 'magit-read-starting-point)
                 (lambda (&rest _) "main"))
                ((symbol-function 'rsr/agent-sessions--create-terminal)
                 (lambda (dir name)
                   (should (eq rsr/agent-sessions-terminal 'tmux))
                   (push (cons dir name) sent)
                   terminal))
                ((symbol-function 'rsr/agent-sessions--terminal-send)
                 (lambda (_buf string) (push string sent))))
        (unwind-protect
            (let ((default-directory main))
              (let ((current-prefix-arg (nth 1 case)))
                (call-interactively #'rsr/agent-sessions-new-worktree))
              (let ((path (expand-file-name "feat-new/" (expand-file-name "proj" tmp))))
                (should (equal (rsr/agent-wt-test--git path "rev-parse" "--abbrev-ref" "HEAD")
                               "feat/new"))
                (should (equal sent (list (nth 3 case) (cons path "feat-new"))))
                (should (equal (mapcar (lambda (f) (plist-get f :name))
                                       (rsr/agent-sessions--folders-for-repo main))
                               '("feat-new"))))
              ;; An existing branch is checked out rather than created.
              (setq answers '("old") sent nil)
              (rsr/agent-sessions-new-worktree)
              (should (equal (rsr/agent-wt-test--git
                              (expand-file-name "proj/old" tmp)
                              "rev-parse" "--abbrev-ref" "HEAD")
                             "old"))
              (setq answers '("old"))
              (should-error (rsr/agent-sessions-new-worktree) :type 'user-error))
          (kill-buffer terminal)))))))

;;; agent-sessions-worktree-test.el ends here
