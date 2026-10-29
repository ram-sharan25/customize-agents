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

(ert-deftest rsr/folders-render-repo-folder-and-worktree-column ()
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
                (let ((rsr/agent-sessions-group-by-folder t))
                  (rsr/agent-sessions--refresh)
                  (should (string-match-p "sample-repo\n  Tasks (1)"
                                          (buffer-string)))
                  (should (string-match-p "No folder (0)" (buffer-string)))
                  (should (string-match-p "sample-worktree.*Task  (feature/test)"
                                          (buffer-string))))
                (let ((rsr/agent-sessions-group-by-folder nil))
                  (rsr/agent-sessions--refresh)
                  (should (string-match-p
                           (concat (regexp-quote
                                    "  sample-worktree (feature/test)\n")
                                   "    .*Task.*\\[Tasks\\]")
                           (buffer-string)))
                  (let ((row (seq-find
                              (lambda (line) (string-match-p "Task" line))
                              (split-string (buffer-string) "\n" t))))
                    (should-not (string-match-p "sample-worktree" row))
                    (should-not (string-match-p "feature/test" row)))
                  (setq rsr/agent-sessions--overview-level 1)
                  (rsr/agent-sessions--show-overview-level 1)
                  (rsr/agent-sessions--refresh)
                  (let* ((repo-section
                          (car (oref magit-root-section children)))
                         (worktree-section
                          (car (oref repo-section children))))
                    (should-not (oref repo-section hidden))
                    (should (oref worktree-section hidden)))
                  (setq rsr/agent-sessions--overview-level 3)
                  (rsr/agent-sessions--show-overview-level 3)
                  (rsr/agent-sessions--refresh)
                  (should (= rsr/agent-sessions--overview-level 2))))))
        (mapc #'kill-buffer (list terminal dashboard))
        (delete-directory root t)))))

(ert-deftest rsr/folders-worktree-column-follows-longest-name ()
  (rsr/folder-test-with-db
    (let* ((root (make-temp-file "repo-width-" t))
           (a (generate-new-buffer " *width-a*"))
           (b (generate-new-buffer " *width-b*"))
           (dashboard (generate-new-buffer " *width-dashboard*"))
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
            (let ((rsr/agent-sessions-group-by-folder t))
              (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                         (lambda () entries)))
                (rsr/agent-sessions--refresh)
                (should (= rsr/agent-sessions--worktree-column-width 19))
                (let ((lines (split-string (buffer-string) "\n" t)))
                  (should (seq-some
                           (lambda (line)
                             (string-match-p
                              "^    short +  .*First task$" line))
                           lines))
                  (should (seq-some
                           (lambda (line)
                             (string-match-p
                              "^    long-worktree-name +  .*Second task$" line))
                           lines))))))
        (mapc #'kill-buffer (list a b dashboard))
        (delete-directory root t)))))

(ert-deftest rsr/folders-manual-order-is-persisted-per-folder ()
  (rsr/folder-test-with-db
    (let* ((repo (rsr/agent-sessions--canonical-path
                  (make-temp-file "folder-order-repo-" t)))
           (a (generate-new-buffer " *folder-order-a*"))
           (b (generate-new-buffer " *folder-order-b*"))
           (dashboard (generate-new-buffer " *folder-order-dashboard*"))
           (one (rsr/agent-sessions--folder-create "One" repo))
           (two (rsr/agent-sessions--folder-create "Two" repo))
           (a-session (list :buffer a :repo "repo" :repo-root repo
                            :worktree-path repo :agent-session-id "a"))
           (b-session (list :buffer b :repo "repo" :repo-root repo
                            :worktree-path repo :agent-session-id "b"))
           (rsr/agent-sessions (make-hash-table :test 'equal))
           (entries (list (list :id "a" :title "First" :session a-session)
                          (list :id "b" :title "Second" :session b-session))))
      (unwind-protect
          (progn
            (puthash "a" a-session rsr/agent-sessions)
            (puthash "b" b-session rsr/agent-sessions)
            (rsr/agent-sessions--folder-set a-session (plist-get one :id))
            (rsr/agent-sessions--folder-set b-session (plist-get one :id))
            (with-current-buffer dashboard
              (rsr/agent-sessions-mode)
              (let ((rsr/agent-sessions-group-by-folder t))
                (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                           (lambda () entries)))
                  (rsr/agent-sessions--refresh)
                  (should (< (save-excursion (goto-char (point-min))
                                             (search-forward "One (2)"))
                             (save-excursion (goto-char (point-min))
                                             (search-forward "Two (0)"))))
                  (goto-char (point-min))
                  (search-forward "Two (0)")
                  (beginning-of-line)
                  (rsr/agent-sessions-move-up)
                  (should (< (save-excursion (goto-char (point-min))
                                             (search-forward "Two (0)"))
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
        (mapc #'kill-buffer (list a b dashboard))
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
          (magit-insert-section
              (rsr/agent-session-worktree '(:label "worktree"))
            (magit-insert-heading "worktree")
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
            (let ((rsr/agent-sessions-group-by-folder nil))
              (cl-letf (((symbol-function 'rsr/agent-sessions--live-entries)
                         (lambda () (list entry)))
                        ((symbol-function 'rsr/agent-sessions--session-files)
                         (lambda (_) (list (list :path path :visited-at 1)))))
                (rsr/agent-sessions--refresh)
                (setq rsr/agent-sessions--overview-level 2)
                (rsr/agent-sessions--show-overview-level 2)
                (let* ((repo (car (oref magit-root-section children)))
                       (worktree (car (oref repo children)))
                       (row (car (oref worktree children))))
                  (should (oref row hidden))
                  ;; Opening one row with TAB must survive an unrelated hook
                  ;; refresh while the global Shift+TAB level stays at two.
                  (magit-section-show row))
                (rsr/agent-sessions--refresh)
                (let* ((repo (car (oref magit-root-section children)))
                       (worktree (car (oref repo children)))
                       (row (car (oref worktree children))))
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

;;; agent-sessions-folder-test.el ends here
