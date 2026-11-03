;;; agent-workflow.el --- Workflow v2 keys on top of agent-sessions  -*- lexical-binding: t; -*-

;; The planning workflow's Emacs side: the `C-c i w' keys that open a session
;; with a stage skill loaded (top-level, or as a child of a session), bring-in
;; of a child's findings, the dashboard's `O' menu (open a session's code
;; or Plans folder), and `a' (the user's own review in Plannotator).  Kept out of agent-sessions.el, which is the dashboard
;; itself; this file only adds commands that use it.  Sessions are opened by
;; the core launcher, bin/agent-launch, so the keys and the agents' own
;; children start sessions the same way.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'agent-sessions)

;;;; Launching sessions with a skill (`C-c i w', dashboard `c')

(defcustom rsr/agent-workflow-plans-directory
  "/Users/rrimal/Stillness/Agent_Stuffs/Plans/"
  "The Plans workspace: every task folder lives under it."
  :type 'directory
  :group 'rsr/agent-sessions)

(defcustom rsr/agent-workflow-launcher
  (expand-file-name "bin/agent-launch"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The core session launcher every workflow key goes through."
  :type 'file
  :group 'rsr/agent-sessions)

(defconst rsr/agent-workflow-new-task-choice "[new task]"
  "The task choice that starts `clarify-requirements' without a task folder.")

(defconst rsr/agent-workflow-keys
  '(("r" "clarify-requirements" "requirements")
    ("R" "review-requirements" "review requirements")
    ("p" "plan-implementation" "plan")
    ("P" "review-plan" "review plan")
    ("i" "implement-plan" "implement")
    ("I" "review-implementation" "review implementation")
    ("w" "issue-workflow" "issue workflow")
    ("e" "explore-session" "explore")
    ("x" "fix-bug" "bug fix"))
  "(KEY SKILL LABEL) for each workflow key: lowercase does a stage, uppercase
reviews it.  The same letters open a top-level session under `C-c i w' and a
child under `C-c i w c' and the dashboard's `c'.")

(defun rsr/agent-workflow--tasks ()
  "Task folders under the Plans workspace, relative to it.
A task folder is one or two levels down and holds `requirements.org' or
`plan.org'; `templates' is not a task."
  (let ((root (file-name-as-directory rsr/agent-workflow-plans-directory))
        tasks)
    (dolist (dir (append (directory-files root t "\\`[^.]")
                         (seq-mapcat (lambda (d)
                                       (and (file-directory-p d)
                                            (directory-files d t "\\`[^.]")))
                                     (directory-files root t "\\`[^.]"))))
      (when (and (file-directory-p dir)
                 (not (string-prefix-p (expand-file-name "templates" root) dir))
                 (or (file-exists-p (expand-file-name "requirements.org" dir))
                     (file-exists-p (expand-file-name "plan.org" dir))))
        (push (file-relative-name dir root) tasks)))
    (sort tasks #'string<)))

(defun rsr/agent-workflow--read-task (&optional allow-new)
  "Ask for a task folder, with nothing pre-filled; return it, or nil for new.
ALLOW-NEW adds `rsr/agent-workflow-new-task-choice'."
  (let* ((choices (append (and allow-new (list rsr/agent-workflow-new-task-choice))
                          (rsr/agent-workflow--tasks)))
         (choice (completing-read "Task folder: " choices nil t nil nil nil)))
    (unless (or (string-empty-p choice)
                (equal choice rsr/agent-workflow-new-task-choice))
      (file-name-as-directory
       (expand-file-name choice rsr/agent-workflow-plans-directory)))))

(defun rsr/agent-workflow--launch-argv (args)
  "The `agent-launch' arguments for the launch plist ARGS.
ARGS has :skill, :agent, and optionally :model and :task, and for a child
:parent, :slug, :dir and :brief."
  (let ((task (plist-get args :task))
        (model (plist-get args :model))
        (parent (plist-get args :parent)))
    (append (list "--skill" (plist-get args :skill)
                  "--agent" (plist-get args :agent))
            (and model (list "--model" model))
            (and task (list "--task" task))
            (if parent
                (list "--child" "--parent" parent
                      "--slug" (plist-get args :slug)
                      "--dir" (plist-get args :dir)
                      "--brief" (plist-get args :brief))
              (list "--top" "--cwd" (or task rsr/agent-workflow-plans-directory)))
            (list "--title" (plist-get args :skill)))))

(defun rsr/agent-workflow--launch (&rest args)
  "Open a session through `rsr/agent-workflow-launcher' with plist ARGS.
The launcher asks this Emacs (by its server socket) to open the window, so the
session gets a dashboard row.  That is why it runs asynchronously: a
synchronous `call-process' blocks the server, and the launcher's `emacsclient'
then waits on it forever.  Returns the process; when it exits, its first line
of output is shown, or the failure with its output."
  (let ((process-environment
         (append (and (bound-and-true-p server-socket-dir)
                      (list (format "EMACS_SOCKET_NAME=%s"
                                    (expand-file-name server-name server-socket-dir))))
                 ;; Emacs is not the parent pane, whatever tmux it started in.
                 (list "TMUX" "TMUX_PANE" "EMACS_AGENT_SESSION_ID"
                       (format "AGENT_DEFAULT=%s" (rsr/agent-sessions-select-agent)))
                 process-environment)))
    (make-process
     :name "agent-launch"
     :buffer (generate-new-buffer " *agent-launch*")
     :command (cons rsr/agent-workflow-launcher
                    (rsr/agent-workflow--launch-argv args))
     :connection-type 'pipe
     :noquery t
     :sentinel
     (lambda (proc _event)
       (unless (process-live-p proc)
         (let ((output (with-current-buffer (process-buffer proc) (buffer-string))))
           (kill-buffer (process-buffer proc))
           (if (and (eq (process-status proc) 'exit)
                    (eq (process-exit-status proc) 0))
               (rsr/agent-workflow--report output)
             (message "agent-launch failed: %s" (string-trim output)))))))))

(defun rsr/agent-workflow--agent (prefix)
  "The configured default agent, or its alternate with PREFIX."
  (rsr/agent-sessions-select-agent prefix))

(defun rsr/agent-workflow--report (output)
  "Show the first line of the launcher's OUTPUT."
  (message "%s" (car (split-string (or output "") "\n" t))))

(defun rsr/agent-workflow-open-top-level (skill agent &optional model)
  "Open a top-level session running SKILL with AGENT; ask for the task folder.
MODEL, when given, is the model AGENT runs on."
  (let ((task (rsr/agent-workflow--read-task (equal skill "clarify-requirements"))))
    (rsr/agent-workflow--launch :skill skill :agent agent :model model :task task)))

(defun rsr/agent-workflow--parent-session ()
  "The session a child opens under, as (TERMINAL-ID . SESSION).
On the dashboard, the session row at point; in a session's terminal buffer,
that session; otherwise the user picks one.  Never guessed."
  (or (and (derived-mode-p 'rsr/agent-sessions-mode)
           (when-let ((row (rsr/agent-sessions--enclosing-section 'rsr/agent-session-row)))
             (let ((id (oref row value)))
               (cons id (rsr/agent-sessions--session-for-id id)))))
      (and (bound-and-true-p rsr/agent-session-id)
           (rsr/agent-sessions--session-for-id rsr/agent-session-id)
           (cons rsr/agent-session-id
                 (rsr/agent-sessions--session-for-id rsr/agent-session-id)))
      (let (choices)
        (maphash (lambda (id session)
                   (push (cons (rsr/agent-sessions--session-label session)
                               (cons id session))
                         choices))
                 rsr/agent-sessions)
        (unless choices (user-error "No agent sessions to open a child under"))
        (cdr (assoc (completing-read "Child of which session? " choices nil t)
                    choices)))))

(defun rsr/agent-workflow--child-dir (task skill)
  "A new output folder for a SKILL child under TASK's artifacts."
  (let* ((base (expand-file-name
                (format "artifacts/%s-%s" (format-time-string "%Y-%m-%d") skill)
                task))
         (dir base)
         (n 1))
    (while (file-exists-p dir)
      (setq n (1+ n) dir (format "%s-%d" base n)))
    (make-directory dir t)
    (file-name-as-directory dir)))

(defun rsr/agent-workflow--write-child-brief (dir skill task parent-id parent)
  "Write DIR/brief.md for a SKILL child of PARENT (terminal PARENT-ID) on TASK.
Pointers only, never transcript: the child works from the files."
  (let ((brief (expand-file-name "brief.md" dir)))
    (with-temp-file brief
      (insert (format "# Child brief: %s\n\n" skill)
              (format "- Opened by the user from Emacs as a child of session `%s' (terminal %s).\n"
                      (rsr/agent-sessions--session-short-label parent) parent-id)
              (format "- Task folder: %s\n" task)
              (format "- Write your findings in: %s\n" dir)
              "- Report back when done as the workflow conventions say for children "
              "(=instructions/shared/workflow-conventions.md=, \"Children and report-back\").\n"))
    brief))

(defun rsr/agent-workflow-open-child (skill agent &optional model)
  "Open a SKILL session with AGENT as a child of the current session.
MODEL, when given, is the model AGENT runs on.  The child inherits the
parent's registered Plans folder; when the parent has none, the user is
asked, as for a top-level key."
  (pcase-let* ((`(,parent-id . ,parent) (rsr/agent-workflow--parent-session))
               (task (or (car (rsr/agent-sessions--session-folder-paths parent "plans"))
                         (rsr/agent-workflow--read-task)
                         (user-error "A child needs a task folder")))
               (dir (rsr/agent-workflow--child-dir task skill))
               (brief (rsr/agent-workflow--write-child-brief
                       dir skill task parent-id parent)))
    (rsr/agent-workflow--launch :skill skill :agent agent :model model :task task
                                :parent parent-id :slug skill :dir dir
                                :brief brief)))

(defvar rsr/agent-workflow-map (make-sparse-keymap)
  "Workflow keys, bound under `C-c i w': open a session with a stage skill.")

(defvar rsr/agent-workflow-child-map (make-sparse-keymap)
  "The same keys, opening the session as a child (`C-c i w c', dashboard `c').")

(dolist (entry rsr/agent-workflow-keys)
  (pcase-let ((`(,key ,skill ,label) entry))
    (let ((top (intern (format "rsr/agent-workflow-%s" skill)))
          (child (intern (format "rsr/agent-workflow-child-%s" skill))))
      (defalias top
        (lambda (prefix)
          (interactive "P")
          (rsr/agent-workflow-open-top-level skill (rsr/agent-workflow--agent prefix)))
        (format "Open %s (%s) with the default agent; \\[universal-argument] selects the alternate."
                skill label))
      (defalias child
        (lambda (prefix)
          (interactive "P")
          (rsr/agent-workflow-open-child skill (rsr/agent-workflow--agent prefix)))
        (format "Open a %s child (%s) with the default agent; \\[universal-argument] selects the alternate."
                skill label))
      (define-key rsr/agent-workflow-map (kbd key) (cons label top))
      (define-key rsr/agent-workflow-child-map (kbd key) (cons label child)))))

;;;; Bring in a finished child's findings (`y')

(defun rsr/agent-workflow--finished-children (session)
  "Summaries shared with SESSION by children that reported back.
A child reports back by sharing its summary under its parent's row with a
label ending in \"ready to bring in\" (see the workflow conventions)."
  (seq-filter (lambda (file)
                (string-suffix-p "ready to bring in" (or (plist-get file :label) "")))
              (rsr/agent-sessions--session-files session)))

(defun rsr/agent-workflow-bring-in ()
  "Pick one of this session's finished children and tell the session to bring it in.
Always shows the list, even with one child; types the request into the
session as if the user had."
  (interactive)
  (pcase-let* ((`(,_id . ,session) (rsr/agent-workflow--parent-session))
               (files (rsr/agent-workflow--finished-children session))
               (choices (mapcar (lambda (f)
                                  (cons (format "%s  (%s)" (plist-get f :label)
                                                (abbreviate-file-name (plist-get f :path)))
                                        f))
                                files)))
    (unless choices (user-error "No finished children to bring in for this session"))
    (let* ((file (cdr (assoc (completing-read "Bring in: " choices nil t) choices)))
           (path (plist-get file :path))
           (buf (plist-get session :buffer)))
      (rsr/agent-sessions--terminal-send
       buf (format "bring in the findings: %s" path)))))

(define-key rsr/agent-workflow-map (kbd "c") (cons "child..." rsr/agent-workflow-child-map))
(define-key rsr/agent-workflow-map (kbd "y") (cons "bring in" #'rsr/agent-workflow-bring-in))
(define-key rsr/agent-sessions-mode-map (kbd "y") #'rsr/agent-workflow-bring-in)

;;;; `O': open the code or Plans folder of the thing at point

(defun rsr/agent-workflow--sessions-under (section)
  "Sessions of every row inside SECTION, at any depth, in display order."
  (let ((own (and (eq (oref section type) 'rsr/agent-session-row)
                  (rsr/agent-sessions--session-for-id (oref section value)))))
    (append (and own (list own))
            (mapcan #'rsr/agent-workflow--sessions-under
                    (oref section children)))))

(defun rsr/agent-workflow--git-directory-p (dir)
  "Non-nil when DIR is inside a git repository."
  (let ((default-directory dir))
    (ignore-errors (magit-toplevel))))

(defun rsr/agent-workflow--folders-at-point (kind)
  "Folders of KIND (\"code\" or \"plans\") for the dashboard thing at point.
On a session row these are the folders its workflow stage registered with
`emacs-share folder'; nothing else is consulted, so a session that registered
nothing has no known folder rather than a guessed one.  On a repository
or folder heading they are the folders registered by every session
under it, and for code also the heading's own directory when it is a git
repository (a workflow session runs in its Plans folder, so its heading's
directory is often not code at all).  Returns a list of directories, possibly
empty."
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'rsr/agent-session-note))
      (setq section (oref section parent)))
    (pcase (and section (oref section type))
      ((or 'rsr/agent-session-repo 'rsr/agent-session-folder)
       (let* ((value (oref section value))
              (dir (and (consp value)
                        (or (plist-get value :path) (plist-get value :root))))
              (own (and (equal kind "code") dir (file-directory-p dir)
                        (rsr/agent-workflow--git-directory-p dir)
                        (list dir))))
         (seq-filter #'file-directory-p
                     (seq-uniq
                      (append own
                              (mapcan (lambda (session)
                                        (copy-sequence
                                         (rsr/agent-sessions--session-folder-paths
                                          session kind)))
                                      (rsr/agent-workflow--sessions-under
                                       section)))))))
      (_
       (let ((session (rsr/agent-workflow--row-session)))
         (and session
              (seq-filter #'file-directory-p
                          (rsr/agent-sessions--session-folder-paths session kind))))))))

(defun rsr/agent-workflow--row-session ()
  "The session of the row at point, or of the row a note at point is under."
  (let* ((section (magit-current-section))
         (row (if (and section (eq (oref section type) 'rsr/agent-session-row))
                  section
                (rsr/agent-sessions--enclosing-section 'rsr/agent-session-row))))
    (and row (rsr/agent-sessions--session-for-id (oref row value)))))

;;;; Assigning a folder by hand (`O C', `O P', or `O c'/`O p' with none known)

(defconst rsr/agent-workflow-type-path-choice "[type a path]"
  "The folder choice that falls back to reading a directory name.")

(defvar projectile-known-projects)
(defvar magit-repository-directories)
(declare-function magit-list-repos "magit-repos")

(defun rsr/agent-workflow--code-candidates ()
  "Repositories to offer as a code folder, each once, as directory names.
Projectile's known projects, magit's `magit-repository-directories' scan,
the repositories of sessions on the dashboard, and every code folder any
session has registered.  Directories that no longer exist are dropped."
  (let (dirs)
    (dolist (dir (bound-and-true-p projectile-known-projects))
      (push dir dirs))
    (when (and (bound-and-true-p magit-repository-directories)
               (require 'magit-repos nil t))
      (dolist (dir (magit-list-repos)) (push dir dirs)))
    (maphash (lambda (_id session)
               (when-let* ((root (plist-get session :repo-root)))
                 (push root dirs)))
             rsr/agent-sessions)
    (maphash (lambda (key paths)
               (when (equal (cdr key) "code")
                 (dolist (path paths) (push path dirs))))
             (rsr/agent-sessions--registered-folders-table))
    (seq-filter #'file-directory-p
                (seq-uniq (mapcar (lambda (dir)
                                    (file-name-as-directory (expand-file-name dir)))
                                  (nreverse dirs))))))

(defun rsr/agent-workflow--read-folder (kind)
  "Ask for a KIND folder and return it as an absolute directory name.
Plans offers the task folders, code the repositories of
`rsr/agent-workflow--code-candidates'; both end with a choice to type a path."
  (let* ((root (file-name-as-directory rsr/agent-workflow-plans-directory))
         (choices (if (equal kind "plans")
                      (mapcar (lambda (task) (cons task (expand-file-name task root)))
                              (rsr/agent-workflow--tasks))
                    (mapcar (lambda (dir) (cons (abbreviate-file-name dir) dir))
                            (rsr/agent-workflow--code-candidates))))
         (choice (completing-read
                  (format "Assign %s folder: " (if (equal kind "code") "code" "Plans"))
                  (append choices (list rsr/agent-workflow-type-path-choice))
                  nil t)))
    (file-name-as-directory
     (expand-file-name
      (if (equal choice rsr/agent-workflow-type-path-choice)
          (read-directory-name "Folder: " (and (equal kind "plans") root) nil t)
        (cdr (assoc choice choices)))))))

(defun rsr/agent-workflow-assign-folder (kind)
  "Ask for a KIND folder, register it for the session at point, return it.
The same registration `emacs-share folder' makes, so the agent and the user
both write it and the last one wins: a Plans folder replaces the old one, a
code folder is added.  Only a session row has one session to register on, so
anywhere else this says so and returns nil."
  (let ((session (rsr/agent-workflow--row-session)))
    (if (null session)
        (progn (message "Assign a %s folder on a session row" kind) nil)
      (let ((dir (rsr/agent-workflow--read-folder kind)))
        (rsr/agent-sessions--register-folder session kind dir)
        (rsr/agent-sessions--refresh-if-visible)
        dir))))

(defun rsr/agent-workflow--select-main-window ()
  "Leave the dashboard's side window for the window beside it.
A side window is dedicated, so magit and dired cannot show a buffer in it and
split the window beside it instead.  Selecting that window first lets them
replace what it shows.  An ordinary dashboard window is left selected."
  (when (window-parameter nil 'window-side)
    (let ((main (or (get-mru-window nil nil t) (window-main-window))))
      (when (window-live-p main)
        (select-window main)))))

(defun rsr/agent-workflow--open-dir (kind dir)
  "Open DIR as a KIND folder: code in magit, plans in dired.
From the side-window dashboard it replaces the window beside it rather than
splitting it."
  (rsr/agent-workflow--select-main-window)
  (if (equal kind "code") (magit-status dir) (dired dir)))

(defun rsr/agent-workflow-open-folder (kind)
  "Open the KIND folder of the thing at point: code in magit, plans in dired.
With several code folders (a task spanning repositories), ask which one; never
pick for the user.  With none on a session row, offer to assign one and open
it; with none on a heading, say so and open nothing."
  (let* ((dirs (rsr/agent-workflow--folders-at-point kind))
         (dir (if (cdr dirs)
                  (completing-read (format "Open which %s folder? " kind) dirs nil t)
                (car dirs))))
    (cond
     (dir (rsr/agent-workflow--open-dir kind dir))
     ((rsr/agent-workflow--row-session)
      (when-let* ((dir (rsr/agent-workflow-assign-folder kind)))
        (rsr/agent-workflow--open-dir kind dir)))
     (t
      (message "No %s folder known here; assign one on a session row with `O %s'"
               (if (equal kind "code") "code" "Plans")
               (if (equal kind "code") "C" "P"))))))

(defun rsr/agent-workflow-open-menu ()
  "Open the code (`c', in magit) or Plans folder (`p', in dired) at point.
`C' and `P' assign one to the session at point first, even when it has one."
  (interactive)
  (pcase (read-char-choice
          "Open: [c] code in magit  [p] Plans in dired  [C/P] assign then open  "
          '(?c ?p ?C ?P ?q ?\C-g))
    (?c (rsr/agent-workflow-open-folder "code"))
    (?p (rsr/agent-workflow-open-folder "plans"))
    ((and key (or ?C ?P))
     (let ((kind (if (eq key ?C) "code" "plans")))
       (when-let* ((dir (rsr/agent-workflow-assign-folder kind)))
         (rsr/agent-workflow--open-dir kind dir))))
    (_ (message nil))))

;; Capital: `o' is the dashboard's "open in other window", as in dired.
(define-key rsr/agent-sessions-mode-map (kbd "O") #'rsr/agent-workflow-open-menu)

;;;; `a': the user's own review of a task document, in Plannotator

(defcustom rsr/agent-workflow-plannotator "plannotator"
  "The Plannotator command `rsr/agent-workflow-annotate' runs."
  :type 'string
  :group 'rsr/agent-sessions)

(defconst rsr/agent-workflow-annotate-documents
  '("plan.org" "requirements.org" "decisions.org")
  "The task documents `rsr/agent-workflow-annotate' offers, in this order.")

(defun rsr/agent-workflow--document-status (file)
  "The `#+status:' of FILE, or \"?\" when it has none."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (if (re-search-forward "^#\\+status:[ \t]*\\(.*\\)$" nil t)
        (string-trim (match-string 1))
      "?")))

(defun rsr/agent-workflow--annotate-argv (doc result)
  "The Plannotator arguments to review DOC, publishing the decision to RESULT."
  (list "annotate" doc "--gate" "--json" "--result-file" result))

(defun rsr/agent-workflow--write-human-review (dir task doc status decision)
  "Write the user's review of DOC into DIR; return the summary path.
STATUS is DOC's `#+status:' when it was opened.  DECISION is Plannotator's
record, an alist with `decision' and `feedback'.  The findings file keeps the
feedback verbatim: it is the user's own words, so nothing here ranks or
rewrites it."
  (let* ((verdict (alist-get 'decision decision))
         (feedback (string-trim (or (alist-get 'feedback decision) "")))
         (findings (expand-file-name "findings.md" dir))
         (summary (expand-file-name "summary.md" dir))
         (date (format-time-string "%Y-%m-%d")))
    (with-temp-file findings
      (insert (format "# Human review — %s\n" (file-name-nondirectory
                                                  (directory-file-name task)))
              (format "Reviewed: %s (#+status: %s) · %s · reviewer: the user, in Plannotator\n"
                      doc status date)
              (format "Decision: %s\n\n" verdict)
              "## Feedback\n\n"
              (if (string-empty-p feedback) "- none" feedback)
              "\n"))
    (with-temp-file summary
      (insert (format "What: the user's own review of %s: %s%s.\n"
                      (file-name-nondirectory doc) verdict
                      (if (string-empty-p feedback) ", no feedback" ", with feedback"))
              (format "Where: %s\n" findings)
              (format "Open: %s\n"
                      (cond ((string-empty-p feedback) "nothing")
                            ((equal verdict "approved")
                             "the notes are guidance, not change requests")
                            (t "address each annotation in the findings file")))))
    summary))

(defun rsr/agent-workflow--annotate-finished (proc session task doc status dir result)
  "Handle Plannotator PROC's exit for SESSION's review of DOC in TASK.
A decision with feedback, or an approval, is written into DIR and its summary
shared under SESSION as ready to bring in, so `y' hands it over when the user
chooses; a dismissal or a failure leaves nothing behind."
  (let ((output (with-current-buffer (process-buffer proc) (buffer-string)))
        (decision (and (file-exists-p result)
                       (ignore-errors
                         (with-temp-buffer
                           (insert-file-contents result)
                           (json-parse-buffer :object-type 'alist))))))
    (kill-buffer (process-buffer proc))
    (cond
     ((and (null decision) (not (equal (process-exit-status proc) 0)))
      (delete-directory dir t)
      (message "Plannotator failed: %s" (string-trim output)))
     ((or (null decision) (equal (alist-get 'decision decision) "dismissed"))
      (delete-directory dir t)
      (message "Plannotator closed without a decision; nothing saved"))
     (t
      (let ((summary (rsr/agent-workflow--write-human-review
                      dir task doc status decision)))
        (rsr/agent-sessions--share-file
         session summary
         (format "human-review %s: ready to bring in" (file-name-nondirectory doc)))
        (rsr/agent-sessions--refresh-if-visible)
        (message "Your review of %s is ready to bring in (y)"
                 (file-name-nondirectory doc)))))))

(defun rsr/agent-workflow-annotate ()
  "Review a task document of the session at point yourself, in Plannotator.
Asks which document of the session's Plans folder (or, with none registered,
which task folder, and registers it), then opens it in Plannotator's browser
view.  The process runs asynchronously, since the review waits on the user for
as long as they take.  When the user decides, the review lands under the
session as ready to bring in, the same as a review child's, so the agent sees
it only when `y' hands it over."
  (interactive)
  (pcase-let* ((`(,_id . ,session) (rsr/agent-workflow--parent-session))
               (task (or (car (seq-filter #'file-directory-p
                                          (rsr/agent-sessions--session-folder-paths
                                           session "plans")))
                         (let ((task (or (rsr/agent-workflow--read-task)
                                         (user-error "A review needs a task folder"))))
                           (rsr/agent-sessions--register-folder session "plans" task)
                           task)))
               (docs (seq-filter (lambda (name)
                                   (file-exists-p (expand-file-name name task)))
                                 rsr/agent-workflow-annotate-documents))
               (doc (expand-file-name
                     (if docs
                         (completing-read "Review which document? " docs nil t)
                       (user-error "No task documents in %s" task))
                     task))
               (status (rsr/agent-workflow--document-status doc))
               (dir (rsr/agent-workflow--child-dir task "human-review"))
               (result (expand-file-name "decision.json" dir)))
    (make-process
     :name "plannotator"
     :buffer (generate-new-buffer " *plannotator*")
     :command (cons rsr/agent-workflow-plannotator
                    (rsr/agent-workflow--annotate-argv doc result))
     :connection-type 'pipe
     ;; Quitting Emacs ends the review; asking first is the only warning.
     :noquery nil
     :sentinel
     (lambda (proc _event)
       (unless (process-live-p proc)
         (rsr/agent-workflow--annotate-finished
          proc session task doc status dir result))))
    (message "Plannotator opened %s in the browser" (file-name-nondirectory doc))))

(define-key rsr/agent-workflow-map (kbd "a") (cons "annotate" #'rsr/agent-workflow-annotate))
(define-key rsr/agent-sessions-mode-map (kbd "a") #'rsr/agent-workflow-annotate)

;;;; The workflow menu: stage and agent on one screen (`C-c i w', dashboard `c')

;; Two choices go into opening a stage: which stage, and which agent runs it.
;; The stage changes every time, so it stays one key; the agent changes
;; rarely, so `-a' sets it once and it is shown and kept until changed.  `-c'
;; opens the stage as a child; the dashboard's `c' opens the menu with it on.

(require 'transient)

(defcustom rsr/agent-workflow-agents nil
  "Agents `-a' cycles through in the workflow menu.
The package offers none: set this in local.el to the agents installed on the
machine.  Each entry is an agent `bin/agent-launch' accepts (claude, pi,
agy), or (LABEL :agent AGENT :model MODEL) to run that agent on a model:

  (\"claude\" \"agy\" (\"pi-local\" :agent \"pi\" :model \"ollama/qwen2.5-coder:32b\"))

The menu shows each entry by its name or LABEL.  Left nil, the menu only uses
the default agent."
  :type '(repeat (choice string
                         (cons string (plist :key-type symbol :value-type string))))
  :group 'rsr/agent-sessions)

(defvar rsr/agent-workflow-agent nil
  "Label of the entry the workflow menu opens stages with; nil for the default.
Set by `-a' in the menu and kept for the rest of the Emacs session.")

(defun rsr/agent-workflow--labels ()
  "The labels of `rsr/agent-workflow-agents', in order."
  (mapcar (lambda (entry) (if (consp entry) (car entry) entry))
          rsr/agent-workflow-agents))

(defun rsr/agent-workflow--menu-agent ()
  "The label of the entry the menu's stage keys use."
  (or rsr/agent-workflow-agent (rsr/agent-sessions-select-agent)))

(defun rsr/agent-workflow--resolve (label)
  "The (AGENT . MODEL) the entry LABEL names; a bare name is its own agent."
  (let ((entry (assoc label (seq-filter #'consp rsr/agent-workflow-agents))))
    (if entry
        (cons (plist-get (cdr entry) :agent) (plist-get (cdr entry) :model))
      (cons label nil))))

(defun rsr/agent-workflow-cycle-agent ()
  "Make the next entry in `rsr/agent-workflow-agents' the menu's agent."
  (interactive)
  (let* ((labels (rsr/agent-workflow--labels))
         (tail (cdr (member (rsr/agent-workflow--menu-agent) labels))))
    (setq rsr/agent-workflow-agent (or (car tail) (car labels)))))

(defun rsr/agent-workflow--agent-description ()
  "The `-a' line: every agent, the current one highlighted."
  (let ((current (rsr/agent-workflow--menu-agent)))
    (format "agent [%s]"
            (mapconcat (lambda (label)
                         (propertize label 'face (if (equal label current)
                                                     'transient-value
                                                   'transient-inactive-value)))
                       (or (rsr/agent-workflow--labels) (list current)) "|"))))

(defun rsr/agent-workflow--menu-run (skill)
  "Open SKILL with the menu's agent and model, as a child when `-c' is on.
A model typed with `-m' wins over the entry's; with neither, the agent runs
on its own default."
  (pcase-let* ((args (transient-args 'rsr/agent-workflow-menu))
               (`(,agent . ,entry-model)
                (rsr/agent-workflow--resolve (rsr/agent-workflow--menu-agent)))
               (model (or (transient-arg-value "--model=" args) entry-model)))
    (if (transient-arg-value "--child" args)
        (rsr/agent-workflow-open-child skill agent model)
      (rsr/agent-workflow-open-top-level skill agent model))))

(dolist (entry rsr/agent-workflow-keys)
  (let ((skill (nth 1 entry)))
    (defalias (intern (format "rsr/agent-workflow-menu-%s" skill))
      (lambda ()
        (interactive)
        (rsr/agent-workflow--menu-run skill))
      (format "Open %s from the workflow menu, with its agent and `-c'." skill))))

(defun rsr/agent-workflow--stage-children (reviews)
  "Menu suffixes for the stage keys; the review keys when REVIEWS is non-nil."
  (transient-parse-suffixes
   'rsr/agent-workflow-menu
   (mapcar (pcase-lambda (`(,key ,skill ,label))
             (list key label (intern (format "rsr/agent-workflow-menu-%s" skill))))
           (seq-filter (lambda (entry)
                         (eq (and reviews t)
                             (not (equal (car entry) (downcase (car entry))))))
                       rsr/agent-workflow-keys))))

(transient-define-prefix rsr/agent-workflow-menu ()
  "Open a workflow stage: the agent with `-a', a model with `-m', a child with `-c'."
  ["Options"
   ("-a" rsr/agent-workflow-cycle-agent
    :description rsr/agent-workflow--agent-description :transient t)
   ("-m" "model, this launch only" "--model=" :prompt "Model: ")
   ("-c" "as child of the current session" "--child")]
  [["Stage" :class transient-column
    :setup-children (lambda (_) (rsr/agent-workflow--stage-children nil))]
   ["Review" :class transient-column
    :setup-children (lambda (_) (rsr/agent-workflow--stage-children t))]
   ["Other"
    ("y" "bring in" rsr/agent-workflow-bring-in)
    ("a" "annotate" rsr/agent-workflow-annotate)]])

(defun rsr/agent-workflow-child-menu ()
  "The workflow menu with `-c' already on."
  (interactive)
  (transient-setup 'rsr/agent-workflow-menu nil nil :value '("--child")))

(define-key rsr/agent-sessions-mode-map (kbd "c") #'rsr/agent-workflow-child-menu)

(provide 'agent-workflow)
;;; agent-workflow.el ends here
