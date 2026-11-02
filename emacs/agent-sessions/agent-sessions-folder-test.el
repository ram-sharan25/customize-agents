;;; agent-sessions-folder-test.el --- Folder tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-sessions)

(defmacro rsr/folder-test-with-db (&rest body)
  "Run BODY with an isolated database."
  (declare (indent 0))
  `(let* ((rsr/agent-sessions-db-file (make-temp-file "agent-folders-"))
          (rsr/agent-sessions--db nil)
          (rsr/agent-sessions--folders-loaded-p nil)
          (rsr/agent-sessions--folders-cache-version nil)
          (rsr/agent-sessions--folders nil)
          (rsr/agent-sessions--folder-assignments nil)
          (rsr/agent-sessions--order nil))
     (unwind-protect (progn ,@body)
       (when (sqlitep rsr/agent-sessions--db)
         (sqlite-close rsr/agent-sessions--db))
       (dolist (path (list rsr/agent-sessions-db-file
                          (concat rsr/agent-sessions-db-file "-wal")
                          (concat rsr/agent-sessions-db-file "-shm")))
         (when (file-exists-p path) (delete-file path))))))

(ert-deftest rsr/folders-repo-scoping-and-persistence ()
  (rsr/folder-test-with-db
    (let* ((a-root (make-temp-file "repo-a-" t))
           (b-root (make-temp-file "repo-b-" t))
           (a-buf (generate-new-buffer " *a*"))
           (b-buf (generate-new-buffer " *b*")))
      (unwind-protect
          (let* ((a-repo (rsr/agent-sessions--canonical-path a-root))
                 (b-repo (rsr/agent-sessions--canonical-path b-root))
                 (a-folder (rsr/agent-sessions--folder-create "Work" a-repo))
                 (b-folder (rsr/agent-sessions--folder-create "Work" b-repo))
                 (a (list :buffer a-buf :agent-session-id "a" :repo-root a-root))
                 (b (list :buffer b-buf :agent-session-id "b" :repo-root b-root)))
            (should-not (equal (plist-get a-folder :id) (plist-get b-folder :id)))
            (rsr/agent-sessions--folder-set a (plist-get a-folder :id))
            (rsr/agent-sessions--folder-set b (plist-get b-folder :id))
            (should-error (rsr/agent-sessions--folder-set a (plist-get b-folder :id)))
            (rsr/agent-sessions--folder-rename a-folder "Renamed")
            (sqlite-close rsr/agent-sessions--db)
            (setq rsr/agent-sessions--db nil
                  rsr/agent-sessions--folders-loaded-p nil)
            (should (equal "Renamed" (plist-get
                                       (rsr/agent-sessions--folder
                                        (plist-get a-folder :id)) :name)))
            (should (equal (plist-get b-folder :id)
                           (rsr/agent-sessions--folder-for-session b)))
            (rsr/agent-sessions--folder-delete
             (rsr/agent-sessions--folder (plist-get a-folder :id)))
            (should-not (rsr/agent-sessions--folder-for-session a))
            (should (rsr/agent-sessions--folder-for-session b)))
        (mapc #'kill-buffer (list a-buf b-buf))
        (delete-directory a-root t)
        (delete-directory b-root t)))))

(ert-deftest rsr/folders-create-recovers-stale-cache ()
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-stale-cache-" t))
           (repo (rsr/agent-sessions--canonical-path root)))
      (unwind-protect
          (let* ((existing (rsr/agent-sessions--folder-create "Work" repo))
                 (id (plist-get existing :id)))
            ;; A module reload can leave the old global-folder cache in Emacs.
            (setq rsr/agent-sessions--folders (list (list :id id :name "Work"))
                  rsr/agent-sessions--folders-loaded-p t)
            (should (equal id (plist-get
                               (rsr/agent-sessions--folder-create "work" repo)
                               :id)))
            (should (equal repo (plist-get (car rsr/agent-sessions--folders)
                                           :repo)))
            ;; A second Emacs may create a folder after this cache was loaded.
            (sqlite-execute (rsr/agent-sessions--db)
                            "INSERT INTO folders (repo, name) VALUES (?, ?)"
                            (list repo "Other"))
            (let ((other (rsr/agent-sessions--folder-create "other" repo)))
              (should (equal "Other" (plist-get other :name)))
              (should (equal 2 (length rsr/agent-sessions--folders))))
            (setq rsr/agent-sessions--folders nil
                  rsr/agent-sessions--folders-loaded-p t
                  rsr/agent-sessions--folders-cache-version nil)
            (should (equal 2 (length (rsr/agent-sessions--folders-for-repo repo)))))
        (delete-directory root t)))))

(ert-deftest rsr/folders-render-repo-folder-and-worktree-label ()
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-render-" t))
           (terminal (generate-new-buffer " *render-terminal*"))
           (dashboard (generate-new-buffer " *render-dashboard*"))
           (rsr/agent-sessions-icons nil)
           (rsr/agent-sessions--states nil)
           (rsr/agent-sessions--notes nil)
           (rsr/agent-sessions--shared-files nil)
           (rsr/agent-sessions--shared-links nil))
      (unwind-protect
          (let* ((folder (rsr/agent-sessions--folder-create
                          "Tasks" (rsr/agent-sessions--canonical-path root)))
                 (session (list :buffer terminal :agent-session-id "render"
                                :agent-type "codex" :status 'stopped
                                :repo "sample-repo" :repo-root root
                                :worktree "sample-worktree (feature/test)"
                                :worktree-name "sample-worktree"
                                :branch "feature/test" :worktree-path root))
                 (entry (list :id "render" :session session :title "Task")))
            (rsr/agent-sessions--folder-set session (plist-get folder :id))
            (with-current-buffer dashboard
              (rsr/agent-sessions-mode)
              (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                         (lambda () (list entry))))
                (rsr/agent-sessions--refresh)
                ;; The folder heading names the worktree its rows share.
                (should (string-match-p "sample-repo\n  Tasks (1)  @feature/test\n"
                                        (buffer-string)))
                ;; No session is outside a folder, so nothing stands for one.
                (should-not (string-match-p "No folder" (buffer-string)))
                ;; The row does not repeat it.
                (let ((row (seq-find
                            (lambda (line) (string-match-p "Task  " line))
                            (split-string (buffer-string) "\n" t))))
                  (should-not (string-match-p "feature/test" row))
                  ;; The agent comes last, after the title.
                  (should (string-match-p "Task  codex$" row)))
                (setq rsr/agent-sessions--overview-level 1)
                (rsr/agent-sessions--show-overview-level 1)
                (rsr/agent-sessions--refresh)
                (let* ((repo-section (car (oref magit-root-section children)))
                       (folder-section
                        (seq-find (lambda (child) (oref child value))
                                  (oref repo-section children)))
                       (row-section (car (oref folder-section children))))
                  (should-not (oref repo-section hidden))
                  (should (oref folder-section hidden))
                  (should (oref row-section hidden))))))
        (mapc #'kill-buffer (list terminal dashboard))
        (delete-directory root t)))))

(ert-deftest rsr/folders-unassigned-sessions-sit-under-the-repo ()
  "A session in no folder renders under the repo, before the folders."
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-loose-" t))
           (repo (rsr/agent-sessions--canonical-path root))
           (a (generate-new-buffer " *loose-a*"))
           (b (generate-new-buffer " *loose-b*"))
           (dashboard (generate-new-buffer " *loose-dashboard*"))
           (rsr/agent-sessions-icons nil)
           (folder (rsr/agent-sessions--folder-create "Tasks" repo))
           (filed (list :buffer a :repo "repo" :repo-root root
                        :worktree-name "wt" :worktree-path root
                        :agent-session-id "filed"))
           (loose (list :buffer b :repo "repo" :repo-root root
                        :worktree-name "wt" :worktree-path root
                        :agent-session-id "loose"))
           (entries (list (list :id "filed" :title "Filed task" :session filed)
                          (list :id "loose" :title "Loose task" :session loose))))
      (unwind-protect
          (progn
            (rsr/agent-sessions--folder-set filed (plist-get folder :id))
            (with-current-buffer dashboard
              (rsr/agent-sessions-mode)
              (progn
                (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                           (lambda () entries)))
                  (rsr/agent-sessions--refresh)
                  (should-not (string-match-p "No folder" (buffer-string)))
                  (should (string-match-p
                           "^repo  @wt\n    .*Loose task\n  Tasks (1)  @wt\n    .*Filed task"
                           (buffer-string)))
                  ;; The loose row folds with the repo's children, as a
                  ;; headingless group has no line of its own to fold to.
                  (setq rsr/agent-sessions--overview-level 1)
                  (rsr/agent-sessions--show-overview-level 1)
                  (let* ((repo-section (car (oref magit-root-section children)))
                         (loose-group (car (oref repo-section children))))
                    (should-not (oref loose-group value))
                    (should-not (oref loose-group hidden))
                    (should (oref (car (oref loose-group children)) hidden)))))))
        (mapc #'kill-buffer (list a b dashboard))
        (delete-directory root t)))))

(ert-deftest rsr/folders-loose-rows-name-only-a-different-worktree ()
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-width-" t))
           (a (generate-new-buffer " *width-a*"))
           (b (generate-new-buffer " *width-b*"))
           (dashboard (generate-new-buffer " *width-dashboard*"))
           (rsr/agent-sessions-icons nil)
           (entries (list
                     (list :id "a" :title "First task"
                           :session (list :buffer a :repo "repo" :repo-root root
                                          :worktree-name "short" :worktree-path root))
                     (list :id "b" :title "Second task"
                           :session (list :buffer b :repo "repo" :repo-root root
                                          :worktree-name "long-worktree-name"
                                          :worktree-path root)))))
      (unwind-protect
          (with-current-buffer dashboard
            (rsr/agent-sessions-mode)
            (progn
              (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                         (lambda () entries)))
                (rsr/agent-sessions--refresh)
                ;; The repo heading names one worktree; only the row in the
                ;; other one names its own, after the title.
                (let* ((text (buffer-string))
                       (heading (and (string-match "^repo  \\(@[^\n]+\\)$" text)
                                     (match-string 1 text)))
                       (lines (split-string text "\n" t)))
                  (should (member heading '("@short" "@long-worktree-name")))
                  (should (= 1 (seq-count
                                (lambda (line)
                                  (string-match-p
                                   "^    .*task  @\\(short\\|long-worktree-name\\)$"
                                   line))
                                lines)))
                  (should-not (string-match-p (concat "task  " heading) text))))))
        (mapc #'kill-buffer (list a b dashboard))
        (delete-directory root t)))))

(ert-deftest rsr/folders-manual-order-is-persisted-per-folder ()
  (rsr/folder-test-with-db
    (let* ((repo (rsr/agent-sessions--canonical-path
                  (make-temp-file "folder-order-repo-" t)))
           (a (generate-new-buffer " *folder-order-a*"))
           (b (generate-new-buffer " *folder-order-b*"))
           (c (generate-new-buffer " *folder-order-c*"))
           (dashboard (generate-new-buffer " *folder-order-dashboard*"))
           (one (rsr/agent-sessions--folder-create "One" repo))
           (two (rsr/agent-sessions--folder-create "Two" repo))
           (_empty (rsr/agent-sessions--folder-create "Empty" repo))
           (a-session (list :buffer a :repo "repo" :repo-root repo
                            :worktree-path repo :agent-session-id "a"))
           (b-session (list :buffer b :repo "repo" :repo-root repo
                            :worktree-path repo :agent-session-id "b"))
           (c-session (list :buffer c :repo "repo" :repo-root repo
                            :worktree-path repo :agent-session-id "c"))
           (rsr/agent-sessions (make-hash-table :test 'equal))
           (entries (list (list :id "a" :title "First" :session a-session)
                          (list :id "b" :title "Second" :session b-session)
                          (list :id "c" :title "Third" :session c-session))))
      (unwind-protect
          (progn
            (puthash "a" a-session rsr/agent-sessions)
            (puthash "b" b-session rsr/agent-sessions)
            (puthash "c" c-session rsr/agent-sessions)
            (rsr/agent-sessions--folder-set a-session (plist-get one :id))
            (rsr/agent-sessions--folder-set b-session (plist-get one :id))
            (rsr/agent-sessions--folder-set c-session (plist-get two :id))
            (with-current-buffer dashboard
              (rsr/agent-sessions-mode)
              (progn
                (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                           (lambda () entries)))
                  (rsr/agent-sessions--refresh)
                  ;; A folder no session is in is hidden, not deleted.
                  (should-not (string-match-p "Empty" (buffer-string)))
                  (should (rsr/agent-sessions--folder (plist-get _empty :id)))
                  (should (< (save-excursion (goto-char (point-min))
                                             (search-forward "One (2)"))
                             (save-excursion (goto-char (point-min))
                                             (search-forward "Two (1)"))))
                  (goto-char (point-min))
                  (search-forward "Two (1)")
                  (beginning-of-line)
                  (rsr/agent-sessions-move-up)
                  (should (< (save-excursion (goto-char (point-min))
                                             (search-forward "Two (1)"))
                             (save-excursion (goto-char (point-min))
                                             (search-forward "One (2)"))))
                  (should (< (save-excursion (goto-char (point-min))
                                             (search-forward "First"))
                             (save-excursion (goto-char (point-min))
                                             (search-forward "Second"))))
                  (goto-char (point-min))
                  (search-forward "First")
                  (beginning-of-line)
                  (rsr/agent-sessions-move-down)
                  (should (< (save-excursion (goto-char (point-min))
                                             (search-forward "Second"))
                             (save-excursion (goto-char (point-min))
                                             (search-forward "First"))))
                  (setq rsr/agent-sessions--order nil)
                  (rsr/agent-sessions--refresh)
                  (should (< (save-excursion (goto-char (point-min))
                                             (search-forward "Second"))
                             (save-excursion (goto-char (point-min))
                                             (search-forward "First"))))))))
        (mapc #'kill-buffer (list a b c dashboard))
        (delete-directory repo t)))))

(ert-deftest rsr/folders-shift-tab-cycles-hierarchy-depth ()
  (with-temp-buffer
    (rsr/agent-sessions-mode)
    (let ((inhibit-read-only t))
      (magit-insert-section (rsr/agent-sessions-root)
        (magit-insert-section (rsr/agent-session-repo '(:name "repo"))
          (magit-insert-heading "repo")
          (magit-insert-section (rsr/agent-session-folder 1)
            (magit-insert-heading "folder")
            (magit-insert-section (rsr/agent-session-row "s")
              (magit-insert-heading "session")
              (magit-insert-section (rsr/agent-session-file "/tmp/file" t)
                (magit-insert-heading "file"))
              (magit-insert-section (rsr/agent-session-link "https://example.com" t)
                (magit-insert-heading "link")))))))
    (let* ((repo (car (oref magit-root-section children)))
           (folder (car (oref repo children)))
           (session (car (oref folder children)))
           (attachments (oref session children)))
      (cl-labels ((visible (heading)
                    (save-excursion
                      (goto-char (point-min))
                      (search-forward heading)
                      (not (invisible-p (1- (point)))))))
        (should (eq (lookup-key rsr/agent-sessions-mode-map (kbd "<backtab>"))
                    #'rsr/agent-sessions-toggle-overview))
        (should (eq (lookup-key rsr/agent-sessions-mode-map (kbd "<S-tab>"))
                    #'rsr/agent-sessions-toggle-overview))
        (rsr/agent-sessions--show-overview-level 0)
        (should (oref repo hidden))
        (should (visible "repo"))
        (should-not (visible "folder"))
        (rsr/agent-sessions-toggle-overview)
        (should (= rsr/agent-sessions--overview-level 1))
        (should-not (oref repo hidden))
        (should (oref folder hidden))
        (should (visible "folder"))
        (should-not (visible "session"))
        (rsr/agent-sessions-toggle-overview)
        (should (= rsr/agent-sessions--overview-level 2))
        (should-not (oref folder hidden))
        (should (oref session hidden))
        (should (visible "session"))
        (should-not (visible "file"))
        (rsr/agent-sessions-toggle-overview)
        (should (= rsr/agent-sessions--overview-level 3))
        (should-not (oref session hidden))
        (should (cl-every (lambda (section) (not (oref section hidden)))
                          attachments))
        (should (visible "file"))
        (should (visible "link"))
        (rsr/agent-sessions-toggle-overview)
        (should (= rsr/agent-sessions--overview-level 0))
        (should (oref repo hidden))))))

(ert-deftest rsr/folders-shift-tab-skips-absent-attachment-level ()
  (with-temp-buffer
    (rsr/agent-sessions-mode)
    (let ((inhibit-read-only t))
      (magit-insert-section (rsr/agent-sessions-root)
        (magit-insert-section (rsr/agent-session-repo '(:name "repo"))
          (magit-insert-heading "repo")
          (magit-insert-section (rsr/agent-session-folder 1)
            (magit-insert-heading "folder")
            (magit-insert-section (rsr/agent-session-row "s")
              (magit-insert-heading "session"))))))
    (let* ((repo (car (oref magit-root-section children)))
           (worktree (car (oref repo children)))
           (session (car (oref worktree children))))
      (should (= (rsr/agent-sessions--overview-max-level) 2))
      (rsr/agent-sessions--show-overview-level 0)
      (dotimes (level 2)
        (rsr/agent-sessions-toggle-overview)
        (should (= rsr/agent-sessions--overview-level (1+ level))))
      (should-not (oref repo hidden))
      (should-not (oref worktree hidden))
      (should-not (oref session hidden))
      (rsr/agent-sessions-toggle-overview)
      (should (= rsr/agent-sessions--overview-level 0))
      (should (oref repo hidden)))))

(ert-deftest rsr/folders-manually-opened-session-survives-refresh ()
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-visible-" t))
           (path (make-temp-file "shared-visible-"))
           (terminal (generate-new-buffer " *visible-terminal*"))
           (dashboard (generate-new-buffer " *visible-dashboard*"))
           (session (list :buffer terminal :agent-session-id "visible"
                          :repo "repo" :repo-root root :worktree "worktree"
                          :worktree-path root))
           (entry (list :id "visible" :title "Task" :session session)))
      (unwind-protect
          (with-current-buffer dashboard
            (rsr/agent-sessions-mode)
            (progn
              (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                         (lambda () (list entry)))
                        ((symbol-function 'rsr/agent-sessions--session-files)
                         (lambda (_) (list (list :path path :visited-at 1)))))
                (rsr/agent-sessions--refresh)
                (setq rsr/agent-sessions--overview-level 2)
                (rsr/agent-sessions--show-overview-level 2)
                (let* ((repo (car (oref magit-root-section children)))
                       (loose (car (oref repo children)))
                       (row (car (oref loose children))))
                  (should (oref row hidden))
                  ;; Opening one row with TAB must survive an unrelated hook
                  ;; refresh while the global Shift+TAB level stays at two.
                  (magit-section-show row))
                (rsr/agent-sessions--refresh)
                (let* ((repo (car (oref magit-root-section children)))
                       (loose (car (oref repo children)))
                       (row (car (oref loose children))))
                  (should-not (oref row hidden))
                  (goto-char (point-min))
                  (search-forward (file-name-nondirectory path))
                  (should-not (invisible-p (1- (point))))))))
        (mapc #'kill-buffer (list terminal dashboard))
        (delete-file path)
        (delete-directory root t)))))

(ert-deftest rsr/folders-action-creates-in-session-repo ()
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-action-" t))
           (terminal (generate-new-buffer " *action-terminal*"))
           (dashboard (generate-new-buffer " *action-dashboard*"))
           (rsr/agent-sessions (make-hash-table :test 'equal))
           (session (list :buffer terminal :agent-session-id "action"
                          :repo-root root :worktree-path root)))
      (unwind-protect
          (progn
            (puthash "action" session rsr/agent-sessions)
            (with-current-buffer dashboard
              (rsr/agent-sessions-mode)
              (let ((inhibit-read-only t))
                (magit-insert-section (rsr/agent-sessions-root)
                  (magit-insert-section (rsr/agent-session-row "action")
                    (magit-insert-heading "session\n"))))
              (goto-char (point-min))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) "New task"))
                        ((symbol-function 'rsr/agent-sessions--refresh) #'ignore))
                (rsr/agent-sessions-folder-action))
              (should (equal (rsr/agent-sessions--canonical-path root)
                             (plist-get (car rsr/agent-sessions--folders) :repo)))
              (should (rsr/agent-sessions--folder-for-session session))))
        (mapc #'kill-buffer (list terminal dashboard))
        (delete-directory root t)))))

(ert-deftest rsr/folders-migrate-global-assignments-by-repo ()
  (rsr/folder-test-with-db
    (let ((db (sqlite-open rsr/agent-sessions-db-file)))
      (unwind-protect
          (progn
            (sqlite-execute db "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
            (sqlite-execute db "INSERT INTO meta VALUES ('schema_version', '2')")
            (sqlite-execute db "CREATE TABLE folders (
              id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE)")
            (sqlite-execute db "CREATE TABLE session_folders (
              agent_sid TEXT PRIMARY KEY, folder_id INTEGER NOT NULL)")
            (sqlite-execute db "CREATE TABLE sessions (
              id INTEGER PRIMARY KEY, agent_sid TEXT, repo TEXT)")
            (sqlite-execute db "INSERT INTO folders VALUES (1, 'Work')")
            (sqlite-execute db "INSERT INTO session_folders VALUES ('a', 1), ('b', 1)")
            (sqlite-execute db "INSERT INTO sessions VALUES
              (1, 'a', '/repo-a/'), (2, 'b', '/repo-b/')")
            (rsr/agent-sessions--db-migrate db)
            (should (equal '(3) (car (sqlite-select db
               "SELECT COUNT(*) FROM folders"))))
            (should (equal '(("/repo-a/") ("/repo-b/"))
                           (sqlite-select db "SELECT f.repo FROM session_folders sf
                             JOIN folders f ON f.id = sf.folder_id
                             ORDER BY sf.agent_sid"))))
        (sqlite-close db)))))

(ert-deftest rsr/folders-carry-terminal-choice-into-agent-id ()
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-hydrate-" t))
           (buf (generate-new-buffer " *hydrate*"))
           (rsr/agent-sessions (make-hash-table :test 'equal))
           (terminal-id "terminal"))
      (unwind-protect
          (let* ((folder (rsr/agent-sessions--folder-create
                          "Work" (rsr/agent-sessions--canonical-path root)))
                 (session (list :buffer buf :repo-root root :worktree-path root)))
            (with-current-buffer buf (setq-local rsr/agent-session-id terminal-id))
            (puthash terminal-id session rsr/agent-sessions)
            (rsr/agent-sessions--folder-set session (plist-get folder :id))
            (rsr/agent-sessions--folder-hydrate buf "agent-id")
            (should (equal (plist-get folder :id)
                           (rsr/agent-sessions--folder-for-session
                            (plist-put (copy-sequence session)
                                       :agent-session-id "agent-id")))))
        (kill-buffer buf)
        (delete-directory root t)))))

(ert-deftest rsr/folders-fork-inherits-parent-folder ()
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-fork-" t))
           (other-root (make-temp-file "repo-fork-other-" t))
           (parent-buf (generate-new-buffer " *parent*"))
           (child-buf (generate-new-buffer " *child*"))
           (chosen-buf (generate-new-buffer " *chosen*"))
           (rsr/agent-sessions (make-hash-table :test 'equal)))
      (unwind-protect
          (let* ((repo (rsr/agent-sessions--canonical-path root))
                 (work (rsr/agent-sessions--folder-create "Work" repo))
                 (mine (rsr/agent-sessions--folder-create "Mine" repo))
                 (parent (list :buffer parent-buf :agent-session-id "parent"
                               :repo-root root))
                 (child (list :buffer child-buf :repo-root root
                              :worktree-path root))
                 (from-parent '("parent" . "parent label")))
            (rsr/agent-sessions--folder-set parent (plist-get work :id))
            (with-current-buffer child-buf
              (setq-local rsr/agent-session-id "child-terminal"))
            (puthash "child-terminal" child rsr/agent-sessions)
            ;; A fork lands in its parent's folder, persisted under its own id.
            (rsr/agent-sessions--folder-inherit child-buf from-parent repo)
            (rsr/agent-sessions--folder-hydrate child-buf "child")
            (should (equal (plist-get work :id)
                           (rsr/agent-sessions--folder-for-session
                            (list :agent-session-id "child" :repo-root root))))
            ;; A folder already chosen for the terminal wins over the parent's.
            (with-current-buffer chosen-buf
              (setq-local rsr/agent-session--folder-id (plist-get mine :id)))
            (rsr/agent-sessions--folder-inherit chosen-buf from-parent repo)
            (should (equal (plist-get mine :id)
                           (buffer-local-value 'rsr/agent-session--folder-id
                                               chosen-buf)))
            ;; A parent's folder never crosses into another repo.
            (with-current-buffer chosen-buf
              (setq-local rsr/agent-session--folder-id nil))
            (rsr/agent-sessions--folder-inherit
             chosen-buf from-parent
             (rsr/agent-sessions--canonical-path other-root))
            (should-not (buffer-local-value 'rsr/agent-session--folder-id
                                            chosen-buf)))
        (mapc #'kill-buffer (list parent-buf child-buf chosen-buf))
        (delete-directory root t)
        (delete-directory other-root t)))))

(ert-deftest rsr/folders-new-terminal-placed-from-point ()
  "`+' takes the tmux session and folder from point, asking only on a repo."
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-new-" t))
           (repo (rsr/agent-sessions--canonical-path root))
           (terminal (generate-new-buffer " *new-terminal*"))
           (dashboard (generate-new-buffer " *new-dashboard*"))
           (rsr/agent-sessions-icons nil)
           (rsr/agent-sessions (make-hash-table :test 'equal))
           (folder (rsr/agent-sessions--folder-create "Tasks" repo))
           (session (list :buffer terminal :repo "main" :repo-root root
                          :worktree-name "main" :worktree-path root
                          :agent-session-id "filed"))
           (entries (list (list :id "filed" :title "Filed task"
                                :session session)))
           targets assigned prompts)
      (unwind-protect
          (progn
            (puthash "filed" session rsr/agent-sessions)
            (with-current-buffer terminal
              (setq major-mode 'rsr/agent-tmux-mode
                    rsr/agent-tmux-session "study"))
            (rsr/agent-sessions--folder-set session (plist-get folder :id))
            (with-current-buffer dashboard
              (rsr/agent-sessions-mode)
              (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                         (lambda () entries))
                        ((symbol-function 'rsr/agent-sessions--all-worktrees)
                         #'ignore)
                        ;; The study session was started in this repo.
                        ((symbol-function 'rsr/agent-sessions--tmux-session-home)
                         (lambda (_) (list :repo "main" :repo-root repo)))
                        ((symbol-function 'rsr/agent-sessions--create-terminal)
                         (lambda (&rest _)
                           (push rsr/agent-tmux--target targets)
                           (generate-new-buffer " *created*")))
                        ((symbol-function 'rsr/agent-sessions--folder-set)
                         (lambda (_ id) (push id assigned)))
                        ((symbol-function 'completing-read)
                         (lambda (prompt &rest _) (push prompt prompts) "Tasks"))
                        ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                         #'ignore)
                        ((symbol-function 'rsr/agent-sessions--goto-terminal-row)
                         #'ignore))
                (rsr/agent-sessions--refresh)
                (dolist (where '("^study" "^  Tasks" "Filed task"))
                  (goto-char (point-min))
                  (re-search-forward where)
                  (beginning-of-line)
                  (rsr/agent-sessions-new-vterm))
                ;; The repo's tmux session every time, never asked for.
                (should (equal (make-list 3 (cons "study" repo))
                               (mapcar (lambda (target)
                                         (cons (car target)
                                               (rsr/agent-sessions--canonical-path
                                                (cdr target))))
                                       targets)))
                ;; Every terminal joins Tasks; only the repo heading asked.
                (should (equal (make-list 3 (plist-get folder :id)) assigned))
                (should (equal '("Folder for the new agent: ") prompts)))))
        (dolist (buf (buffer-list))
          (when (string-prefix-p " *created*" (buffer-name buf))
            (kill-buffer buf)))
        (mapc #'kill-buffer (list terminal dashboard))
        (delete-directory root t)))))

(ert-deftest rsr/folders-new-terminal-folder-worktree ()
  "`+' on a folder takes its sessions' worktree, asking when they span several."
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-fwt-" t))
           (side (make-temp-file "repo-fwt-side-" t))
           (repo (rsr/agent-sessions--canonical-path root))
           (side-path (rsr/agent-sessions--canonical-path side))
           (terminal (generate-new-buffer " *fwt-terminal*"))
           (other (generate-new-buffer " *fwt-other*"))
           (dashboard (generate-new-buffer " *fwt-dashboard*"))
           (rsr/agent-sessions-icons nil)
           (rsr/agent-sessions (make-hash-table :test 'equal))
           (folder (rsr/agent-sessions--folder-create "Tasks" repo))
           (worktrees (list (list :label "main" :path repo)
                            (list :label "side (side)" :path side-path)))
           (session (list :buffer terminal :repo "main" :repo-root root
                          :worktree-name "main" :worktree-path root
                          :agent-session-id "one"))
           (session2 (list :buffer other :repo "main" :repo-root root
                           :worktree-name "side" :worktree-path side
                           :agent-session-id "two"))
           (entries (list (list :id "one" :title "First" :session session)))
           targets prompts)
      (unwind-protect
          (progn
            (puthash "one" session rsr/agent-sessions)
            (puthash "two" session2 rsr/agent-sessions)
            (dolist (buf (list terminal other))
              (with-current-buffer buf
                (setq major-mode 'rsr/agent-tmux-mode
                      rsr/agent-tmux-session "study")))
            (rsr/agent-sessions--folder-set session (plist-get folder :id))
            (rsr/agent-sessions--folder-set session2 (plist-get folder :id))
            (with-current-buffer dashboard
              (rsr/agent-sessions-mode)
              (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                         (lambda () entries))
                        ((symbol-function 'rsr/agent-sessions--all-worktrees)
                         (lambda (_) worktrees))
                        ((symbol-function 'rsr/agent-sessions--tmux-session-home)
                         (lambda (_) (list :repo "main" :repo-root repo)))
                        ((symbol-function 'rsr/agent-sessions--create-terminal)
                         (lambda (&rest _)
                           (push rsr/agent-tmux--target targets)
                           (generate-new-buffer " *fwt-created*")))
                        ((symbol-function 'rsr/agent-sessions--folder-set)
                         #'ignore)
                        ((symbol-function 'completing-read)
                         (lambda (prompt &rest _)
                           (push prompt prompts) "side (side)"))
                        ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                         #'ignore)
                        ((symbol-function 'rsr/agent-sessions--goto-terminal-row)
                         #'ignore))
                (cl-flet ((plus-on-folder (&optional ask)
                            (rsr/agent-sessions--refresh)
                            (goto-char (point-min))
                            (re-search-forward "^  Tasks")
                            (beginning-of-line)
                            (rsr/agent-sessions-new-vterm ask))
                          (last-dir ()
                            (rsr/agent-sessions--canonical-path
                             (cdr (car targets)))))
                  ;; The folder's sessions share one worktree: taken, not asked.
                  (plus-on-folder)
                  (should (null prompts))
                  (should (equal repo (last-dir)))
                  ;; C-u asks anyway.
                  (plus-on-folder t)
                  (should (equal '("Worktree: ") prompts))
                  (should (equal side-path (last-dir)))
                  ;; Sessions in two worktrees: asked.
                  (setq entries (list (list :id "one" :title "First"
                                            :session session)
                                      (list :id "two" :title "Second"
                                            :session session2))
                        prompts nil)
                  (plus-on-folder)
                  (should (equal '("Worktree: ") prompts))
                  (should (equal side-path (last-dir)))))))
        (dolist (buf (buffer-list))
          (when (string-prefix-p " *fwt-created*" (buffer-name buf))
            (kill-buffer buf)))
        (mapc #'kill-buffer (list terminal other dashboard))
        (delete-directory root t)
        (delete-directory side t)))))

(ert-deftest rsr/folders-tmux-agent-asks-folder-outside-dashboard ()
  "`C-c i i' away from the dashboard asks for a folder; in it, reads point."
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-cii-" t))
           (repo (rsr/agent-sessions--canonical-path root))
           (folder (rsr/agent-sessions--folder-create "Tasks" repo))
           (created (generate-new-buffer " *cii-created*"))
           at-point assigned sent prompts)
      (unwind-protect
          (cl-letf (((symbol-function 'rsr/agent-tmux-read-target)
                     (lambda (&rest _) (cons "study" root)))
                    ((symbol-function 'rsr/agent-sessions--create-terminal)
                     (lambda (&rest _) created))
                    ((symbol-function 'rsr/agent-sessions--new-terminal-at-point)
                     (lambda () (push t at-point) created))
                    ((symbol-function 'rsr/agent-sessions--terminal-session)
                     (lambda (buf) (list :buffer buf :repo-root root)))
                    ((symbol-function 'rsr/agent-sessions--tmux-home) #'ignore)
                    ((symbol-function 'rsr/agent-sessions--terminal-send)
                     (lambda (_ program) (push program sent)))
                    ((symbol-function 'rsr/agent-sessions--folder-set)
                     (lambda (_ id) (push id assigned)))
                    ((symbol-function 'completing-read)
                     (lambda (prompt &rest _) (push prompt prompts) "Tasks"))
                    ((symbol-function 'rsr/agent-sessions--refresh-if-visible)
                     #'ignore))
            (with-temp-buffer
              (rsr/agent-tmux-agent "claude"))
            (should (equal (list (plist-get folder :id)) assigned))
            (should (equal '("Folder for the new agent: ") prompts))
            (should-not at-point)
            (with-temp-buffer
              (rsr/agent-sessions-mode)
              (rsr/agent-tmux-agent "claude"))
            ;; In the dashboard `+''s placement ran instead of the prompt.
            (should (equal '(t) at-point))
            (should (equal 1 (length prompts)))
            (should (equal '("claude" "claude") sent)))
        (kill-buffer created)
        (delete-directory root t)))))

;;; agent-sessions-folder-test.el ends here

(ert-deftest rsr/folders-repo-list-creates-dims-and-deletes ()
  "`F' on a repo heading lists every folder; C-k deletes, the new entry creates."
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-folder-list-" t))
           (terminal (generate-new-buffer " *folder-list-terminal*"))
           (dashboard (generate-new-buffer " *folder-list-dashboard*"))
           (rsr/agent-sessions (make-hash-table :test 'equal))
           (session (list :buffer terminal :repo-root root :worktree-path root
                          :agent-session-id "live"))
           (entries (list (list :id "live" :title "Working" :session session)))
           seen answers)
      (unwind-protect
          (let* ((repo (rsr/agent-sessions--canonical-path root))
                 (busy (rsr/agent-sessions--folder-create "Busy" repo))
                 (_stale (rsr/agent-sessions--folder-create "Stale" repo)))
            (rsr/agent-sessions--folder-set session (plist-get busy :id))
            (with-current-buffer dashboard
              (rsr/agent-sessions-mode)
              (let ((inhibit-read-only t))
                (magit-insert-section (rsr/agent-sessions-root)
                  (magit-insert-section (rsr/agent-session-repo
                                         (list :name "demo" :root root))
                    (magit-insert-heading "demo\n"))))
              (goto-char (point-min))
              ;; First pass: C-k on Stale.  Second pass: RET on the new entry.
              (setq answers (list (lambda () (throw 'rsr/agent-sessions--folder-list
                                                    (cons 'delete "Stale")))
                                  (lambda () rsr/agent-sessions--new-folder-candidate)))
              (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                         (lambda () entries))
                        ((symbol-function 'completing-read)
                         (lambda (_prompt candidates &rest _)
                           (push candidates seen)
                           (funcall (pop answers))))
                        ((symbol-function 'read-string) (lambda (&rest _) "Fresh"))
                        ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                        ((symbol-function 'rsr/agent-sessions--refresh) #'ignore))
                (rsr/agent-sessions-folder-action))
              (let ((first (car (last seen))))
                (should (equal (list rsr/agent-sessions--new-folder-candidate
                                     "Busy" "Stale")
                               (mapcar #'substring-no-properties first)))
                (should-not (get-text-property 0 'face (nth 1 first)))
                (should (eq 'shadow (get-text-property 0 'face (nth 2 first)))))
              (should (equal '("Busy" "Fresh")
                             (sort (mapcar (lambda (f) (plist-get f :name))
                                           (rsr/agent-sessions--folders-for-repo repo))
                                   #'string-lessp)))))
        (mapc #'kill-buffer (list terminal dashboard))
        (delete-directory root t)))))
