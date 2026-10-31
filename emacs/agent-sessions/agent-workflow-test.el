;;; agent-workflow-test.el --- Tests for workflow v2 pieces  -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-sessions)
(require 'agent-workflow)

(defvar projectile-known-projects)
(defvar magit-repository-directories)

(defmacro rsr/agent-workflow-test--with-db (&rest body)
  "Run BODY with an isolated database and empty folder registrations."
  (declare (indent 0) (debug t))
  `(let* ((db-file (make-temp-file "agent-workflow-test-"))
          (rsr/agent-sessions-db-file db-file)
          (rsr/agent-sessions--db nil)
          (rsr/agent-sessions--registered-folders nil))
     (unwind-protect
         (progn ,@body)
       (when (sqlitep rsr/agent-sessions--db)
         (sqlite-close rsr/agent-sessions--db))
       (dolist (path (list db-file (concat db-file "-wal") (concat db-file "-shm")))
         (when (file-exists-p path) (delete-file path))))))

(defmacro rsr/agent-workflow-test--with-session (session &rest body)
  "Run BODY with every share lookup resolving to SESSION."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
              (lambda (_) ,session))
             ((symbol-function 'rsr/agent-sessions--refresh-if-visible) #'ignore))
     ,@body))

;;;; Folder registration

(ert-deftest rsr/agent-workflow-share-folder-stores-plans-and-code ()
  (rsr/agent-workflow-test--with-db
    (let ((session (list :agent-session-id "thread-1"))
          (plans (file-name-as-directory (make-temp-file "plans-" t)))
          (code (file-name-as-directory (make-temp-file "code-" t))))
      (rsr/agent-workflow-test--with-session session
        (should (string-prefix-p "Folder plans"
                                 (rsr/agent-sessions-share-folder "t1" "plans" plans)))
        (should (string-prefix-p "Folder code"
                                 (rsr/agent-sessions-share-folder "t1" "code" code))))
      (should (equal (rsr/agent-sessions--session-folder-paths session "plans")
                     (list plans)))
      (should (equal (rsr/agent-sessions--session-folder-paths session "code")
                     (list code)))
      ;; Survives a reload from the database.
      (setq rsr/agent-sessions--registered-folders nil)
      (should (equal (rsr/agent-sessions--session-folder-paths session "code")
                     (list code))))))

(ert-deftest rsr/agent-workflow-share-folder-keeps-every-code-folder-once ()
  (rsr/agent-workflow-test--with-db
    (let ((session (list :agent-session-id "thread-2"))
          (a (file-name-as-directory (make-temp-file "code-a-" t)))
          (b (file-name-as-directory (make-temp-file "code-b-" t))))
      (rsr/agent-workflow-test--with-session session
        (rsr/agent-sessions-share-folder "t2" "code" a)
        (rsr/agent-sessions-share-folder "t2" "code" b)
        (rsr/agent-sessions-share-folder "t2" "code" a))
      (should (equal (rsr/agent-sessions--session-folder-paths session "code")
                     (list a b))))))

(ert-deftest rsr/agent-workflow-share-folder-plans-replaces ()
  "A session works on one task, so a new Plans folder replaces the old one."
  (rsr/agent-workflow-test--with-db
    (let ((session (list :agent-session-id "thread-3"))
          (a (file-name-as-directory (make-temp-file "plans-a-" t)))
          (b (file-name-as-directory (make-temp-file "plans-b-" t))))
      (rsr/agent-workflow-test--with-session session
        (rsr/agent-sessions-share-folder "t3" "plans" a)
        (rsr/agent-sessions-share-folder "t3" "plans" b))
      (should (equal (rsr/agent-sessions--session-folder-paths session "plans")
                     (list b))))))

(ert-deftest rsr/agent-workflow-share-folder-refuses-bad-input ()
  (rsr/agent-workflow-test--with-db
    (let ((session (list :agent-session-id "thread-4")))
      (rsr/agent-workflow-test--with-session session
        (should (string-prefix-p "Unknown folder kind"
                                 (rsr/agent-sessions-share-folder "t4" "bogus" "/tmp")))
        (should (string-prefix-p "No such directory"
                                 (rsr/agent-sessions-share-folder
                                  "t4" "code" "/no/such/dir/anywhere"))))
      (should-not (rsr/agent-sessions--session-folder-paths session "code")))))

;;;; The `O' menu

(defmacro rsr/agent-workflow-test--at-section (type value &rest body)
  "Run BODY with point on a dashboard section of TYPE holding VALUE."
  (declare (indent 2) (debug t))
  `(let ((section (magit-section)))
     (oset section type ,type)
     (oset section value ,value)
     (cl-letf (((symbol-function 'magit-current-section) (lambda () section)))
       ,@body)))

(defmacro rsr/agent-workflow-test--recording-openers (&rest body)
  "Run BODY with `magit-status', `dired' and `message' recorded in `opened'."
  (declare (indent 0) (debug t))
  `(let (opened)
     (cl-letf (((symbol-function 'magit-status)
                (lambda (dir &rest _) (push (list 'magit dir) opened)))
               ((symbol-function 'dired)
                (lambda (dir &rest _) (push (list 'dired dir) opened)))
               ((symbol-function 'message)
                (lambda (fmt &rest args)
                  (push (list 'message (apply #'format fmt args)) opened))))
       ,@body)))

(ert-deftest rsr/agent-workflow-open-menu-on-session-row ()
  (rsr/agent-workflow-test--with-db
    (let ((session (list :agent-session-id "thread-o1"))
          (plans (file-name-as-directory (make-temp-file "plans-" t)))
          (code (file-name-as-directory (make-temp-file "code-" t))))
      (rsr/agent-sessions--register-folder session "plans" plans)
      (rsr/agent-sessions--register-folder session "code" code)
      (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                 (lambda (_) session)))
        (rsr/agent-workflow-test--at-section 'rsr/agent-session-row "t-o1"
          (rsr/agent-workflow-test--recording-openers
            (rsr/agent-workflow-open-folder "code")
            (rsr/agent-workflow-open-folder "plans")
            (should (equal (reverse opened)
                           (list (list 'magit code) (list 'dired plans))))))))))

(ert-deftest rsr/agent-workflow-open-folder-leaves-side-window ()
  "From a side-window dashboard, the folder opens in the window beside it."
  (rsr/agent-workflow-test--with-db
    (let ((session (list :agent-session-id "thread-o2"))
          (code (file-name-as-directory (make-temp-file "code-" t)))
          (main (selected-window))
          side opened-in)
      (save-window-excursion
        (setq side (display-buffer-in-side-window
                    (get-buffer-create " *agent-workflow-side-test*")
                    '((side . left) (slot . 0))))
        (select-window side)
        (rsr/agent-sessions--register-folder session "code" code)
        (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                   (lambda (_) session))
                  ((symbol-function 'magit-status)
                   (lambda (&rest _) (setq opened-in (selected-window)))))
          (rsr/agent-workflow-test--at-section 'rsr/agent-session-row "t-o2"
            (rsr/agent-workflow-open-folder "code"))))
      (should (eq opened-in main))
      (should-not (eq opened-in side)))))

(ert-deftest rsr/agent-workflow-open-menu-reads-one-key ()
  (let (asked)
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (_prompt chars) (should (memq ?c chars)) ?c))
              ((symbol-function 'rsr/agent-workflow-open-folder)
               (lambda (kind) (setq asked kind))))
      (rsr/agent-workflow-open-menu)
      (should (equal asked "code")))))

(ert-deftest rsr/agent-workflow-open-menu-on-headings-uses-their-directory ()
  (let ((dir (file-name-as-directory (make-temp-file "worktree-" t))))
    (let ((default-directory dir)) (call-process "git" nil nil nil "init" "-q"))
    (rsr/agent-workflow-test--at-section 'rsr/agent-session-repo (list :root dir)
      (rsr/agent-workflow-test--recording-openers
        (rsr/agent-workflow-open-folder "code")
        (should (equal opened (list (list 'magit dir))))))))

(ert-deftest rsr/agent-workflow-open-menu-on-headings-uses-sessions-folders ()
  "A heading whose directory is a Plans folder, not a repo, opens what the
sessions under it registered, and asks when there are several."
  (rsr/agent-workflow-test--with-db
    (let* ((heading-dir (file-name-as-directory (make-temp-file "plans-cwd-" t)))
           (a (list :agent-session-id "thread-h1"))
           (b (list :agent-session-id "thread-h2"))
           (plans-a (file-name-as-directory (make-temp-file "plans-a-" t)))
           (plans-b (file-name-as-directory (make-temp-file "plans-b-" t)))
           (code (file-name-as-directory (make-temp-file "code-" t)))
           (sessions `(("t-h1" . ,a) ("t-h2" . ,b)))
           offered)
      (rsr/agent-sessions--register-folder a "plans" plans-a)
      (rsr/agent-sessions--register-folder a "code" code)
      (rsr/agent-sessions--register-folder b "plans" plans-b)
      (rsr/agent-sessions--register-folder b "code" code)
      (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                 (lambda (id) (cdr (assoc id sessions))))
                ((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (all-completions "" collection))
                   plans-b)))
        (rsr/agent-workflow-test--at-section 'rsr/agent-session-repo
            (list :root heading-dir)
          (dolist (id '("t-h1" "t-h2"))
            (let ((row (magit-section)))
              (oset row type 'rsr/agent-session-row)
              (oset row value id)
              (oset section children (append (oref section children) (list row)))))
          (rsr/agent-workflow-test--recording-openers
            (rsr/agent-workflow-open-folder "code")
            (rsr/agent-workflow-open-folder "plans")
            (should (equal (sort offered #'string<)
                           (sort (list plans-a plans-b) #'string<)))
            (should (equal (reverse opened)
                           (list (list 'magit code) (list 'dired plans-b))))))))))

(ert-deftest rsr/agent-workflow-open-menu-unknown-folder-on-heading-only-messages ()
  "A heading that is not a repo, with no session folders, opens nothing."
  (let ((dir (file-name-as-directory (make-temp-file "plans-cwd-" t))))
    (rsr/agent-workflow-test--with-db
      (rsr/agent-workflow-test--at-section 'rsr/agent-session-worktree (list :path dir)
        (rsr/agent-workflow-test--recording-openers
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (error "Should not ask"))))
            (rsr/agent-workflow-open-folder "code")
            (rsr/agent-workflow-open-folder "plans"))
          (should (= (length opened) 2))
          (should (seq-every-p (lambda (e) (eq (car e) 'message)) opened)))))))

(ert-deftest rsr/agent-workflow-open-menu-unknown-folder-assigns-then-opens ()
  "A session with nothing registered asks for a folder, keeps it, opens it."
  (rsr/agent-workflow-test--with-db
    (let* ((session (list :agent-session-id "thread-o2" :dir "/tmp/"))
           (root (file-name-as-directory (make-temp-file "plans-root-" t)))
           (task (expand-file-name "proj/task/" root))
           (code (file-name-as-directory (make-temp-file "code-" t)))
           (rsr/agent-workflow-plans-directory root)
           (projectile-known-projects (list (abbreviate-file-name code)))
           (magit-repository-directories nil)
           (rsr/agent-sessions (make-hash-table :test 'equal))
           offered)
      (make-directory task t)
      (write-region "" nil (expand-file-name "plan.org" task))
      (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                 (lambda (_) session))
                ((symbol-function 'rsr/agent-sessions--refresh-if-visible) #'ignore)
                ((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (let ((names (all-completions "" collection)))
                     (push names offered)
                     (car names)))))
        (rsr/agent-workflow-test--at-section 'rsr/agent-session-row "t-o2"
          (rsr/agent-workflow-test--recording-openers
            (rsr/agent-workflow-open-folder "code")
            (rsr/agent-workflow-open-folder "plans")
            (should (equal (reverse offered)
                           (list (list (abbreviate-file-name code)
                                       rsr/agent-workflow-type-path-choice)
                                 (list "proj/task"
                                       rsr/agent-workflow-type-path-choice))))
            (should (equal (reverse opened)
                           (list (list 'magit code) (list 'dired task))))
            (should (equal (rsr/agent-sessions--session-folder-paths session "code")
                           (list code)))
            (should (equal (rsr/agent-sessions--session-folder-paths session "plans")
                           (list task)))))))))

(ert-deftest rsr/agent-workflow-open-menu-capital-assigns-even-when-known ()
  "`C' adds another code folder; `P' replaces the Plans folder."
  (rsr/agent-workflow-test--with-db
    (let* ((session (list :agent-session-id "thread-o4"))
           (a (file-name-as-directory (make-temp-file "code-a-" t)))
           (b (file-name-as-directory (make-temp-file "code-b-" t)))
           (old (file-name-as-directory (make-temp-file "plans-old-" t)))
           (new (file-name-as-directory (make-temp-file "plans-new-" t)))
           (keys (list ?C ?P))
           (dirs (list b new)))
      (rsr/agent-sessions--register-folder session "code" a)
      (rsr/agent-sessions--register-folder session "plans" old)
      (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                 (lambda (_) session))
                ((symbol-function 'rsr/agent-sessions--refresh-if-visible) #'ignore)
                ((symbol-function 'read-char-choice) (lambda (&rest _) (pop keys)))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) rsr/agent-workflow-type-path-choice))
                ((symbol-function 'read-directory-name) (lambda (&rest _) (pop dirs))))
        (rsr/agent-workflow-test--at-section 'rsr/agent-session-row "t-o4"
          (rsr/agent-workflow-test--recording-openers
            (rsr/agent-workflow-open-menu)
            (rsr/agent-workflow-open-menu)
            (should (equal (reverse opened)
                           (list (list 'magit b) (list 'dired new))))
            (should (equal (rsr/agent-sessions--session-folder-paths session "code")
                           (list a b)))
            (should (equal (rsr/agent-sessions--session-folder-paths session "plans")
                           (list new)))))))))

(ert-deftest rsr/agent-workflow-assign-folder-refuses-a-heading ()
  (rsr/agent-workflow-test--with-db
    (rsr/agent-workflow-test--at-section 'rsr/agent-session-repo (list :root "/tmp/")
      (rsr/agent-workflow-test--recording-openers
        (should-not (rsr/agent-workflow-assign-folder "code"))
        (should (eq (car (car opened)) 'message))))))

(ert-deftest rsr/agent-workflow-open-menu-asks-between-code-folders ()
  "Two registered repositories: ask, open only the one chosen (Review focus 2)."
  (rsr/agent-workflow-test--with-db
    (let ((session (list :agent-session-id "thread-o3"))
          (a (file-name-as-directory (make-temp-file "code-a-" t)))
          (b (file-name-as-directory (make-temp-file "code-b-" t)))
          offered)
      (rsr/agent-sessions--register-folder session "code" a)
      (rsr/agent-sessions--register-folder session "code" b)
      (cl-letf (((symbol-function 'rsr/agent-sessions--session-for-id)
                 (lambda (_) session))
                ((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (all-completions "" collection))
                   b)))
        (rsr/agent-workflow-test--at-section 'rsr/agent-session-row "t-o3"
          (rsr/agent-workflow-test--recording-openers
            (rsr/agent-workflow-open-folder "code")
            (should (equal (sort offered #'string<) (sort (list a b) #'string<)))
            (should (equal opened (list (list 'magit b))))))))))

(ert-deftest rsr/agent-workflow-O-is-bound-on-the-dashboard ()
  (should (eq (lookup-key rsr/agent-sessions-mode-map (kbd "O"))
              #'rsr/agent-workflow-open-menu)))

;;;; Launch keys (`C-c i w', dashboard `c' and `y')

(defconst rsr/agent-workflow-test--key-table
  '(("r" . "clarify-requirements") ("R" . "review-requirements")
    ("p" . "plan-implementation") ("P" . "review-plan")
    ("i" . "implement-plan") ("I" . "review-implementation")
    ("w" . "issue-workflow") ("e" . "explore-session") ("x" . "fix-bug"))
  "The confirmed key table (decisions.org, \"Key bindings are designed deliberately\").")

(defmacro rsr/agent-workflow-test--capturing-launch (&rest body)
  "Run BODY with launches recorded in `launched' (newest first) instead of run."
  (declare (indent 0) (debug t))
  `(let (launched)
     (cl-letf (((symbol-function 'rsr/agent-workflow--launch)
                (lambda (&rest args) (push args launched) "opened")))
       ,@body)))

(defun rsr/agent-workflow-test--plans-root ()
  "A temporary Plans root with tasks `proj/task-a' and `task-b'."
  (let ((root (file-name-as-directory (make-temp-file "plans-root-" t))))
    (dolist (task '("proj/task-a" "task-b"))
      (make-directory (expand-file-name task root) t)
      (with-temp-file (expand-file-name (concat task "/requirements.org") root)
        (insert "#+status: DRAFT\n")))
    (make-directory (expand-file-name "templates" root))
    (with-temp-file (expand-file-name "templates/requirements.org" root) (insert ""))
    root))

(ert-deftest rsr/agent-workflow-each-top-level-key-launches-its-skill ()
  (let* ((root (rsr/agent-workflow-test--plans-root))
         (rsr/agent-workflow-plans-directory root))
    (dolist (pair rsr/agent-workflow-test--key-table)
      (rsr/agent-workflow-test--capturing-launch
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) "task-b")))
          (call-interactively (lookup-key rsr/agent-workflow-map (kbd (car pair)))))
        (should (equal (plist-get (car launched) :skill) (cdr pair)))
        (should (equal (plist-get (car launched) :agent) "claude"))
        (should (equal (plist-get (car launched) :task)
                       (file-name-as-directory (expand-file-name "task-b" root))))
        (should-not (plist-get (car launched) :parent))))))

(ert-deftest rsr/agent-workflow-prefix-argument-selects-pi ()
  (let ((rsr/agent-workflow-plans-directory (rsr/agent-workflow-test--plans-root)))
    (rsr/agent-workflow-test--capturing-launch
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "task-b")))
        (let ((current-prefix-arg '(4)))
          (call-interactively #'rsr/agent-workflow-plan-implementation)))
      (should (equal (plist-get (car launched) :agent) "pi")))))

(ert-deftest rsr/agent-workflow-top-level-asks-for-the-task-with-no-prefill ()
  (let ((rsr/agent-workflow-plans-directory (rsr/agent-workflow-test--plans-root))
        calls)
    (rsr/agent-workflow-test--capturing-launch
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection _pred _require initial _hist default &rest _)
                   (push (list (all-completions "" collection) initial default) calls)
                   (car (all-completions "" collection)))))
        (call-interactively #'rsr/agent-workflow-plan-implementation)
        (call-interactively #'rsr/agent-workflow-clarify-requirements)))
    (pcase-let ((`((,clarify-choices ,i2 ,d2) (,plan-choices ,i1 ,d1)) calls))
      (should-not (or i1 d1 i2 d2))
      (should (equal (sort (copy-sequence plan-choices) #'string<)
                     '("proj/task-a" "task-b")))
      (should-not (member "templates" plan-choices))
      (should (member rsr/agent-workflow-new-task-choice clarify-choices))
      (should-not (member rsr/agent-workflow-new-task-choice plan-choices)))))

(ert-deftest rsr/agent-workflow-new-task-launches-without-a-task ()
  (let ((rsr/agent-workflow-plans-directory (rsr/agent-workflow-test--plans-root)))
    (rsr/agent-workflow-test--capturing-launch
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) rsr/agent-workflow-new-task-choice)))
        (call-interactively #'rsr/agent-workflow-clarify-requirements))
      (should (equal (plist-get (car launched) :skill) "clarify-requirements"))
      (should-not (plist-get (car launched) :task)))))

(ert-deftest rsr/agent-workflow-child-inherits-the-parent-task-folder ()
  (rsr/agent-workflow-test--with-db
    (let* ((task (file-name-as-directory (make-temp-file "task-" t)))
           (parent (list :agent-session-id "thread-p" :buffer nil))
           asked)
      (rsr/agent-sessions--register-folder parent "plans" task)
      (rsr/agent-workflow-test--capturing-launch
        (cl-letf (((symbol-function 'rsr/agent-workflow--parent-session)
                   (lambda () (cons "term-p" parent)))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) (setq asked t) "x")))
          (call-interactively (lookup-key rsr/agent-workflow-map (kbd "c P"))))
        (should-not asked)
        (let ((args (car launched)))
          (should (equal (plist-get args :skill) "review-plan"))
          (should (equal (plist-get args :task) task))
          (should (equal (plist-get args :parent) "term-p"))
          (should (string-prefix-p (expand-file-name "artifacts/" task)
                                   (plist-get args :dir)))
          (should (file-exists-p (plist-get args :brief))))))))

(ert-deftest rsr/agent-workflow-dashboard-c-and-y-are-bound ()
  (should (keymapp (lookup-key rsr/agent-sessions-mode-map (kbd "c"))))
  (should (eq (lookup-key rsr/agent-sessions-mode-map (kbd "c P"))
              (lookup-key rsr/agent-workflow-map (kbd "c P"))))
  (should (eq (lookup-key rsr/agent-sessions-mode-map (kbd "y"))
              #'rsr/agent-workflow-bring-in))
  (should (eq (lookup-key rsr/agent-workflow-map (kbd "y"))
              #'rsr/agent-workflow-bring-in)))

(ert-deftest rsr/agent-workflow-bring-in-lists-only-finished-children ()
  (let* ((session (list :agent-session-id "thread-y" :buffer 'buf))
         (files (list (list :path "/t/artifacts/a/summary.md"
                            :label "review-plan a: ready to bring in")
                      (list :path "/t/artifacts/a/brief.md" :label "brief")
                      (list :path "/t/artifacts/b/summary.md"
                            :label "exploration b: ready to bring in")))
         offered sent)
    (cl-letf (((symbol-function 'rsr/agent-workflow--parent-session)
               (lambda () (cons "term-y" session)))
              ((symbol-function 'rsr/agent-sessions--session-files)
               (lambda (s) (and (eq s session) files)))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (setq offered (all-completions "" collection))
                 (car offered)))
              ((symbol-function 'rsr/agent-sessions--terminal-send)
               (lambda (buf text) (setq sent (list buf text)))))
      (call-interactively #'rsr/agent-workflow-bring-in))
    (should (= (length offered) 2))
    (should-not (seq-find (lambda (c) (string-match-p "brief" c)) offered))
    (should (eq (car sent) 'buf))
    (should (string-match-p "bring in" (cadr sent)))
    (should (string-match-p "summary\\.md" (cadr sent)))))

(ert-deftest rsr/agent-workflow-launch-argv ()
  (should (equal (rsr/agent-workflow--launch-argv
                  (list :skill "review-plan" :task "/t/" :agent "pi" :parent "p1"
                        :slug "review-plan" :dir "/t/artifacts/r/" :brief "/t/artifacts/r/brief.md"))
                 '("--skill" "review-plan" "--agent" "pi" "--task" "/t/"
                   "--child" "--parent" "p1" "--slug" "review-plan"
                   "--dir" "/t/artifacts/r/" "--brief" "/t/artifacts/r/brief.md"
                   "--title" "review-plan")))
  (should (equal (rsr/agent-workflow--launch-argv
                  (list :skill "plan-implementation" :task "/t/" :agent "claude"))
                 '("--skill" "plan-implementation" "--agent" "claude" "--task" "/t/"
                   "--top" "--cwd" "/t/" "--title" "plan-implementation"))))

(ert-deftest rsr/agent-workflow-launch-does-not-block-emacs ()
  "The launcher calls back into Emacs, so launching must return before it exits.
The fake launcher waits for a file only this Emacs writes after `--launch'
returns, standing in for the `emacsclient' call a blocked Emacs never answers."
  (let* ((dir (make-temp-file "agent-launch-test-" t))
         (go (expand-file-name "go" dir))
         (rsr/agent-workflow-launcher (expand-file-name "agent-launch" dir))
         messages)
    (unwind-protect
        (progn
          (with-temp-file rsr/agent-workflow-launcher
            (insert "#!/bin/sh\n"
                    "i=0; while [ ! -e " (shell-quote-argument go) " ]; do\n"
                    "  i=$((i + 1)); [ $i -lt 50 ] || { echo blocked; exit 1; }; sleep 0.1\n"
                    "done\necho \"Opened $*\"\n"))
          (set-file-modes rsr/agent-workflow-launcher #o755)
          (cl-letf (((symbol-function 'message)
                     (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
            (let ((proc (rsr/agent-workflow--launch :skill "plan-implementation"
                                                    :agent "claude" :task "/t/")))
              (should (process-live-p proc))
              (write-region "" nil go nil 'silent)
              (while (process-live-p proc) (accept-process-output proc 0.1))
              (accept-process-output nil 0.1)))
          (should (equal messages '("Opened --skill plan-implementation --agent claude --task /t/ --top --cwd /t/ --title plan-implementation"))))
      (delete-directory dir t))))

(ert-deftest rsr/agent-workflow-launch-reports-failure ()
  (let* ((dir (make-temp-file "agent-launch-test-" t))
         (rsr/agent-workflow-launcher (expand-file-name "agent-launch" dir))
         messages)
    (unwind-protect
        (progn
          (with-temp-file rsr/agent-workflow-launcher
            (insert "#!/bin/sh\necho 'agent-launch: tmux session not found' >&2\nexit 2\n"))
          (set-file-modes rsr/agent-workflow-launcher #o755)
          (cl-letf (((symbol-function 'message)
                     (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
            (let ((proc (rsr/agent-workflow--launch :skill "review-plan" :agent "pi")))
              (while (process-live-p proc) (accept-process-output proc 0.1))
              (accept-process-output nil 0.1)))
          (should (equal messages
                         '("agent-launch failed: agent-launch: tmux session not found"))))
      (delete-directory dir t))))

;;;; `a': the user's review in Plannotator

(defmacro rsr/agent-workflow-test--with-plannotator (script &rest body)
  "Run BODY with a fake Plannotator whose shell body is SCRIPT.
The fake gets the real arguments, so `$6' is the result file.  BODY sees
`task' (a task folder holding plan.org), `session', `shared' (the
`--share-file' calls) and `messages'; `run' calls the command and waits."
  (declare (indent 1) (debug t))
  `(rsr/agent-workflow-test--with-db
     (let* ((bin (make-temp-file "plannotator-test-" t))
            (task (file-name-as-directory (make-temp-file "task-" t)))
            (rsr/agent-workflow-plannotator (expand-file-name "plannotator" bin))
            (session (list :agent-session-id "thread-a"))
            shared messages)
       (unwind-protect
           (progn
             (with-temp-file rsr/agent-workflow-plannotator
               (insert "#!/bin/sh\n" ,script "\n"))
             (set-file-modes rsr/agent-workflow-plannotator #o755)
             (with-temp-file (expand-file-name "plan.org" task)
               (insert "#+title: Plan\n#+status: DRAFT\n"))
             (rsr/agent-sessions--register-folder session "plans" task)
             (cl-letf (((symbol-function 'rsr/agent-workflow--parent-session)
                        (lambda () (cons "term-a" session)))
                       ((symbol-function 'completing-read)
                        (lambda (_prompt collection &rest _) (car (all-completions "" collection))))
                       ((symbol-function 'rsr/agent-sessions--share-file)
                        (lambda (s path label) (push (list s path label) shared)))
                       ((symbol-function 'rsr/agent-sessions--refresh-if-visible) #'ignore)
                       ((symbol-function 'message)
                        (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
               (cl-flet ((run ()
                           (let ((before (process-list)))
                             (rsr/agent-workflow-annotate)
                             (dolist (proc (seq-difference (process-list) before))
                               (while (process-live-p proc)
                                 (accept-process-output proc 0.1)))
                             (accept-process-output nil 0.1))))
                 ,@body)))
         (delete-directory bin t)
         (delete-directory task t)))))

(defun rsr/agent-workflow-test--review-dirs (task)
  "The human-review folders under TASK's artifacts."
  (let ((artifacts (expand-file-name "artifacts" task)))
    (and (file-directory-p artifacts)
         (directory-files artifacts t "human-review"))))

(ert-deftest rsr/agent-workflow-annotate-argv ()
  (should (equal (rsr/agent-workflow--annotate-argv "/t/plan.org" "/t/r.json")
                 '("annotate" "/t/plan.org" "--gate" "--json"
                   "--result-file" "/t/r.json"))))

(ert-deftest rsr/agent-workflow-annotate-feedback-is-ready-to-bring-in ()
  (rsr/agent-workflow-test--with-plannotator
      "printf '{\"decision\":\"annotated\",\"feedback\":\"Step 2 misses the timeout.\"}' > \"$6\""
    (run)
    (let* ((dir (car (rsr/agent-workflow-test--review-dirs task)))
           (findings (with-temp-buffer
                       (insert-file-contents (expand-file-name "findings.md" dir))
                       (buffer-string))))
      (should (string-match-p "Decision: annotated" findings))
      (should (string-match-p "#\\+status: DRAFT" findings))
      (should (string-match-p "Step 2 misses the timeout\\." findings))
      (should (equal (length shared) 1))
      (pcase-let ((`(,s ,path ,label) (car shared)))
        (should (eq s session))
        (should (equal path (expand-file-name "summary.md" dir)))
        (should (equal label "human-review plan.org: ready to bring in")))
      ;; `y' lists it like a finished child.
      (cl-letf (((symbol-function 'rsr/agent-sessions--session-files)
                 (lambda (_) (list (list :path (nth 1 (car shared))
                                         :label (nth 2 (car shared)))))))
        (should (rsr/agent-workflow--finished-children session))))))

(ert-deftest rsr/agent-workflow-annotate-approval-is-recorded ()
  (rsr/agent-workflow-test--with-plannotator
      "printf '{\"decision\":\"approved\",\"feedback\":\"\"}' > \"$6\""
    (run)
    (let ((dir (car (rsr/agent-workflow-test--review-dirs task))))
      (should (string-match-p "approved, no feedback"
                              (with-temp-buffer
                                (insert-file-contents (expand-file-name "summary.md" dir))
                                (buffer-string))))
      (should (equal (length shared) 1)))))

(ert-deftest rsr/agent-workflow-annotate-dismissal-leaves-nothing ()
  (dolist (script '("printf '{\"decision\":\"dismissed\",\"feedback\":\"\"}' > \"$6\""
                    "exit 0"))
    (rsr/agent-workflow-test--with-plannotator script
      (run)
      (should-not (rsr/agent-workflow-test--review-dirs task))
      (should-not shared)
      (should (string-match-p "nothing saved" (car messages))))))

(ert-deftest rsr/agent-workflow-annotate-failure-is-reported ()
  (rsr/agent-workflow-test--with-plannotator
      "echo 'File not found' >&2; exit 2"
    (run)
    (should-not (rsr/agent-workflow-test--review-dirs task))
    (should-not shared)
    (should (equal (car messages) "Plannotator failed: File not found"))))

(ert-deftest rsr/agent-workflow-annotate-does-not-block-emacs ()
  "The review waits on the user, so the command must return while it runs."
  (rsr/agent-workflow-test--with-plannotator
      "while [ ! -e \"$6.go\" ]; do sleep 0.1; done; printf '{\"decision\":\"dismissed\"}' > \"$6\""
    (let ((before (process-list)))
      (rsr/agent-workflow-annotate)
      (let ((proc (car (seq-difference (process-list) before)))
            (dir (car (rsr/agent-workflow-test--review-dirs task))))
        (should (process-live-p proc))
        (write-region "" nil (expand-file-name "decision.json.go" dir) nil 'silent)
        (while (process-live-p proc) (accept-process-output proc 0.1))
        (accept-process-output nil 0.1)))))

(ert-deftest rsr/agent-workflow-annotate-asks-for-a-task-when-none-is-registered ()
  (rsr/agent-workflow-test--with-plannotator "exit 0"
    (setq session (list :agent-session-id "thread-unregistered"))
    (cl-letf (((symbol-function 'rsr/agent-workflow--read-task) (lambda (&rest _) task)))
      (run))
    (should (equal (rsr/agent-sessions--session-folder-paths session "plans")
                   (list task)))))

(ert-deftest rsr/agent-workflow-a-is-bound ()
  (should (eq (lookup-key rsr/agent-sessions-mode-map (kbd "a"))
              #'rsr/agent-workflow-annotate))
  (should (eq (lookup-key rsr/agent-workflow-map (kbd "a"))
              #'rsr/agent-workflow-annotate)))

(provide 'agent-workflow-test)
;;; agent-workflow-test.el ends here
