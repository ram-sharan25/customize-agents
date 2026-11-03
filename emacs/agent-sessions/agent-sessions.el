;; Dashboard for Claude/Codex/Pi sessions running in vterm buffers.
;;
;; Every vterm buffer gets a unique id injected into its shell environment
;; (EMACS_AGENT_SESSION_ID) at creation time, with no special launcher command
;; needed. Hook scripts for Claude Code / Codex, and a Pi extension, forward
;; their event payloads to `rsr/agent-hook-notify' via emacsclient, keyed by
;; that id, so sessions sharing a worktree still resolve to the right buffer.

(require 'cl-lib)
(require 'seq)
(require 'json)
(require 'server)
(require 'diff)
;; Not autoloaded: `with-sqlite-transaction' is a macro in sqlite.el, so
;; without this the persistent store's writes fail at *call* time, long after
;; the file has loaded cleanly.
(require 'sqlite)
(require 'magit)
(require 'magit-section)
(require 'project)
(require 'org)
;; Not autoloaded: `format-spec' renders the launch templates in
;; `rsr/agent-orchestration-launch-commands', and a spawn is the first thing
;; that would notice it missing — long after this file loaded cleanly.
(require 'format-spec)
(require 'agent-sessions-tmux)

(defconst rsr/agent-sessions--dir
  (file-name-directory (or load-file-name buffer-file-name
                           (locate-library "agent-sessions") default-directory))
  "Directory this package lives in; its hook forwarder scripts sit beside it.")

(defconst rsr/agent-sessions--bin-dir
  (expand-file-name "bin" rsr/agent-sessions--dir)
  "Directory of the commands an agent may run from inside a session terminal.
Placed on the PATH of every session terminal, so `emacs-share' is simply there
— nothing for the user to install and nothing for the agent to locate.")

(defvar rsr/agent-sessions--extra-terminal-env nil
  "Extra `VAR=VALUE' strings to inject into the next terminal created.
Bound around a terminal-creating call.  It exists because the environment is
assembled by the vterm/eat advice, deep inside those packages' own internals,
so there is no argument to thread through: see `rsr/agent-orchestration-spawn',
the only binder.  A worker learns its role and its coordinator from the
environment rather than from its launch command because the id it is addressed
by is minted by that same advice, and so is not known to the caller yet.")

(defvar rsr/agent-sessions--tmux-window-options nil
  "Options for the next tmux window `rsr/agent-sessions--tmux-open' makes.
A plist: `:name' is the tmux window name; `:detached' non-nil leaves the
session's current window where it is (`new-window -d'); `:silent' non-nil
skips showing the session in Emacs afterwards.  Bound around a
terminal-creating call, for the reason `rsr/agent-sessions--extra-terminal-env'
is: the backend is reached through `rsr/agent-sessions--create-terminal',
which has no argument to carry them.  See `rsr/agent-sessions-explore-spawn'.")

(defun rsr/agent-sessions--terminal-environment (id)
  "Environment entries to inject into a session terminal identified by ID.
The PATH entry is built from the PATH the terminal was going to inherit anyway
\(`process-environment' is what the subprocess gets), so this is strictly
additive.  Assembling one from anywhere else could silently *shrink* the
shell's PATH, which is the failure mode worth designing away here."
  (append (list (format "EMACS_AGENT_SESSION_ID=%s" id)
                (format "AGENT_DEFAULT=%s" (rsr/agent-sessions-select-agent))
                (format "PATH=%s%s%s" rsr/agent-sessions--bin-dir path-separator
                        (or (getenv "PATH") "")))
          rsr/agent-sessions--extra-terminal-env))

(defvar rsr/agent-session-id->buffer (make-hash-table :test 'equal)
  "Session id -> vterm buffer, populated for every vterm buffer at creation.")

(defvar rsr/agent-sessions (make-hash-table :test 'equal)
  "Session id -> plist of live agent state and its terminal buffer.
Includes agent identity, hook status, repo/worktree, and Claude's most recently
submitted prompt when its `UserPromptSubmit' hook provided one.
Populated lazily: an entry only exists once a hook event has fired for it.")

(defvar rsr/agent-session-counter 0)

(defconst rsr/agent-orchestration-message-types
  '("status" "done" "blocked" "question" "answer")
  "The types an inter-agent message may carry.
Deliberately short: `done' is the one an orchestrator waits on, `blocked' and
`question' are the two ways a worker stops short of it, `answer' closes a
question or replies to later mail delivered to a resting worker, and `status'
is everything else.  A larger vocabulary would have to earn itself by changing
what some command *does*, not just what a row says.")

(defconst rsr/agent-orchestration-actionable-message-types
  '("done" "blocked" "question" "answer")
  "Mail types important enough to steer a running Codex turn.
Plain `status' mail waits for the recipient to become idle, unless actionable
mail is queued with it, so progress chatter cannot repeatedly steer active
work and earlier context still stays ordered with the actionable message.")

(defvar rsr/agent-orchestration--mail (make-hash-table :test 'equal)
  "Recipient terminal id -> list of message plists, oldest first.
A message is (:id :from :from-key :from-label :to :to-key :type :subject :body
:files :report :sent-at :read).

This is the working copy, keyed the way mail is *addressed* at runtime; the
record is the `mail' table, keyed by durable identity.  Both exist because they
answer different questions: the render path reads this one (it must never touch
the database), and a session that outlives this Emacs is found again through the
other.  Filled from the database by `rsr/agent-orchestration--hydrate' when a
session's identity becomes known, and dropped for a terminal when it is killed
\(`rsr/agent-session--cleanup') — dropping the working copy, never the record.")

(defvar rsr/agent-orchestration--counter 0
  "Source of message and brief ids within this Emacs.")

(defvar-local rsr/agent-orchestration-coordinator nil
  "Terminal id of the agent that spawned this one, when it was spawned by one.
Set on the worker's buffer at spawn, which is what `emacs-agent list' reads to
answer \"whose workers are these\" without consulting the message log.")

(defvar-local rsr/agent-session-id nil
  "Unique id injected into this vterm buffer's shell environment, if any.")

(defvar-local rsr/agent-session--created-at nil
  "When this terminal buffer was created; the dashboard's stable sort key.
Lives on the buffer rather than in the session plist because the plist is
rebuilt from scratch on every hook event, and because plain terminals that
have never fired a hook need the same key.  See
`rsr/agent-sessions--sort-entries'.")

(defvar-local rsr/agent-session--viewed-at nil
  "When the user most recently selected this terminal buffer.
Used to order the agent picker shown by `rsr/agent-sessions-send-region',
and as the history `rsr/agent-sessions-visit-last-agent' goes back through.")

(defvar rsr/agent-sessions--last-focused-buffer nil
  "Buffer seen by the previous focus-hook run.
This distinguishes actually selecting a terminal from hook runs caused by
output arriving in a terminal that was already selected.")

(defvar-local rsr/agent-session--resuming-session-id nil
  "Agent session id this terminal was opened to resume.
This bridges startup until the agent's first hook confirms its identity, so a
message addressed through an older terminal can find this live replacement.")

(defvar-local rsr/agent-session--folder-id nil
  "Folder chosen for this terminal before or between agent session ids.")

(defconst rsr/agent-sessions-buffer-name "*Agent Sessions*")

(defgroup rsr/agent-sessions nil
  "Dashboard of agent sessions running in terminals."
  :group 'tools)

(defcustom rsr/agent-sessions-default-agent 'claude
  "Default agent for fresh sessions: `claude' or `pi'.
Set this in local.el before loading the package.  A prefix argument on
agent-launching commands selects the other agent.  Explicit agent choices
and existing-session identities are never changed by this preference."
  :type '(choice (const claude) (const pi))
  :group 'rsr/agent-sessions)

(defun rsr/agent-sessions-select-agent (&optional alternate)
  "Return the default agent name, or the other agent when ALTERNATE is non-nil."
  (unless (memq rsr/agent-sessions-default-agent '(claude pi))
    (user-error "Invalid default agent: %S (expected claude or pi)"
                rsr/agent-sessions-default-agent))
  (symbol-name (if alternate
                   (if (eq rsr/agent-sessions-default-agent 'pi) 'claude 'pi)
                 rsr/agent-sessions-default-agent)))

(defcustom rsr/agent-sessions-terminal 'vterm
  "Terminal emulator backend used for agent sessions.
One of `vterm', `eat', `ghostel' or `tmux'.  Only the selected package needs to
be installed; it is loaded lazily the first time a session terminal is created.
`tmux' opens each terminal as a window in the repository's tmux session (see
agent-sessions-tmux.el), shown in Emacs through ghostel."
  :type '(choice (const :tag "vterm" vterm)
                 (const :tag "eat" eat)
                 (const :tag "ghostel" ghostel)
                 (const :tag "tmux" tmux)))

(defcustom rsr/agent-session-notify-on-attention t
  "When non-nil, show a desktop notification when a session needs attention.
The notification fires only on the transition into `needs-attention'/`error',
not on every hook event, so a session that stays waiting is announced once."
  :type 'boolean)

(defvar rsr/agent-sessions-sort-by-activity nil
  "When non-nil, sort repos and sessions by most recent activity.
Off by default because `:updated-at' changes on every hook event, so two
sessions running at once continually swap places in the dashboard.  The
default is a stable alphabetical repo order with attention sorted sessions.
Toggle with `s' \(`rsr/agent-sessions-toggle-sort').")

(defcustom rsr/agent-sessions-sort-by-attention t
  "When non-nil, the stable order lifts rows that need you to the top.
Within a worktree or folder, rows then sort error, needs-attention, running,
rest, and only then by age, so a row moves when its status changes.  When nil,
rows keep their creation order and never move on their own.  Toggle with `S'
\(`rsr/agent-sessions-toggle-attention-sort').  Has no effect while `s'
\(activity order) is on."
  :type 'boolean)

(defcustom rsr/agent-sessions-icons t
  "When non-nil, start each dashboard line with an icon saying what it is.
Icons come from `nerd-icons' and are left out when it is not installed."
  :type 'boolean
  :group 'rsr/agent-sessions)

(defcustom rsr/agent-sessions-display-side 'left
  "Side of the frame `rsr/agent-sessions-list' opens the dashboard on.
A side window stays put while other buffers come and go, so the dashboard can
sit beside the work.  nil opens it in an ordinary window via `pop-to-buffer'."
  :type '(choice (const left) (const right) (const top) (const bottom)
                 (const :tag "Ordinary window" nil))
  :group 'rsr/agent-sessions)

(defcustom rsr/agent-sessions-window-width 45
  "Width in columns of the dashboard's side window on the left or right."
  :type 'integer
  :group 'rsr/agent-sessions)

(defcustom rsr/agent-sessions-worktree-label 'branch
  "What a worktree is shown as after its `@': its branch or its folder name.
A branch label falls back to the folder name on a detached HEAD."
  :type '(choice (const branch) (const folder))
  :group 'rsr/agent-sessions)

(defconst rsr/agent-session-status-alist
  '((claude . ((SessionStart . stopped)
               (Stop . needs-attention)
               (StopFailure . error)
               (PermissionRequest . needs-attention)
               (TeammateIdle . needs-attention)
               (UserPromptSubmit . running)))
    (codex . ((Stop . needs-attention)
              (PermissionRequest . needs-attention)
              (UserPromptSubmit . running)
              (agent-turn-complete . needs-attention)))
    (pi . ((SessionStart . stopped)
           (Stop . needs-attention)
           (StopFailure . error)
           (UserPromptSubmit . running)))
    (agy . ((SessionStart . stopped)
            (PreInvocation . running)
            (Stop . needs-attention))))
  "Per-agent hook/notify event name -> status.
Events not listed here (PreToolUse, PostToolUse, SubagentStart/Stop, etc.)
leave a session's existing status unchanged rather than resetting it — hook
invocations are independent async processes with no delivery ordering
guarantee, so an informational event can arrive after Stop/PermissionRequest
and must not clobber the needs-attention state those set.  SessionStart maps
to `stopped', never `running': pi and Claude fire it when the TUI opens at an
idle prompt (and Claude on --resume), so a brand-new session would otherwise
fall through to the `running' default in `rsr/agent-hook-notify' and read as
mid-turn while sitting at its prompt.  No entry for Codex — its SessionStart
fires lazily on the first prompt, in the same instant as UserPromptSubmit, so
mapping it would risk clobbering `running' under unordered delivery.  agy has
no prompt event; `PreInvocation' (before each model call) marks the turn.")

(defun rsr/agent-session--status-for (agent-type event-name)
  "Return the status EVENT-NAME maps to, or nil if it shouldn't change status."
  (cdr (assq (intern event-name)
             (alist-get (intern agent-type) rsr/agent-session-status-alist))))

(defun rsr/agent-sessions--canonical-path (path)
  "Return PATH canonicalized to a directory name for use as a hash-table key."
  (and path (file-name-as-directory (file-truename path))))

(defun rsr/agent-sessions--worktree-label (path branch)
  "Return the display label for the worktree at PATH on BRANCH.
Shows the worktree directory name and, when known, its branch as
`<dir> (<branch>)' so sessions sharing a repo but on different worktrees are
easy to tell apart.  Falls back to just the directory name when BRANCH is nil
(detached HEAD)."
  (let ((dir (file-name-nondirectory (directory-file-name path))))
    (if branch
        (format "%s (%s)" dir branch)
      dir)))

(defun rsr/agent-sessions--head-branch (path)
  "The branch checked out in the git worktree at PATH, read from its HEAD file.
Returns the branch name, `detached' for a detached HEAD, or nil when PATH is
not a readable worktree.  Reading the file rather than asking git keeps a
render free of subprocesses, yet still follows a branch switched since the
session was registered."
  (when path
    (ignore-errors
      (let* ((dotgit (expand-file-name ".git" path))
             (gitdir (if (file-directory-p dotgit)
                         dotgit
                       ;; A linked worktree's .git is a file naming its gitdir.
                       (with-temp-buffer
                         (insert-file-contents dotgit)
                         (and (looking-at "gitdir: *\\(.*\\)$")
                              (expand-file-name (match-string 1) path)))))
             (head (with-temp-buffer
                     (insert-file-contents (expand-file-name "HEAD" gitdir))
                     (buffer-substring-no-properties
                      (point-min) (line-end-position)))))
        (if (string-prefix-p "ref: refs/heads/" head)
            (substring head (length "ref: refs/heads/"))
          'detached)))))

(defun rsr/agent-sessions--at-label (path folder branch)
  "The `@' label for the worktree at PATH named FOLDER, last seen on BRANCH.
The live HEAD wins over BRANCH; BRANCH only stands in when HEAD is unreadable.
See `rsr/agent-sessions-worktree-label'."
  (let* ((head (rsr/agent-sessions--head-branch path))
         (branch (if head (and (stringp head) head) branch))
         (folder (or folder
                     (and path (file-name-nondirectory
                                (directory-file-name path)))
                     "?")))
    (concat "@" (if (and branch (eq rsr/agent-sessions-worktree-label 'branch))
                    branch
                  folder))))

(defun rsr/agent-sessions--repo-name (root)
  "The display name of the repo whose main checkout is ROOT.
The name recorded in its git config when it is laid out as REPO/<branch>/
\(see `rsr/agent-sessions-new-worktree'), else ROOT's folder name."
  (or (rsr/agent-tmux-recorded-repo-name root)
      (file-name-nondirectory (directory-file-name root))))

(defun rsr/agent-session--repo-info (dir)
  "Return session repo/worktree info for the git repo containing DIR.
The plist has :repo NAME, :repo-root ROOT (the main worktree's directory),
:worktree LABEL, :worktree-name NAME, :branch BRANCH, and :worktree-path DIR."
  (let* ((default-directory dir)
         (toplevel (ignore-errors (magit-toplevel))))
    (if (not toplevel)
        (list :repo nil :repo-root nil :worktree nil :worktree-name nil
              :branch nil :worktree-path nil)
      (let* ((common-dir (ignore-errors
                            (let ((default-directory toplevel))
                              (magit-git-string "rev-parse" "--path-format=absolute"
                                                 "--git-common-dir"))))
             (main-root (if common-dir
                            (file-name-as-directory (expand-file-name ".." common-dir))
                          toplevel))
             (repo-name (rsr/agent-sessions--repo-name main-root))
             (branch (ignore-errors (let ((default-directory toplevel))
                                       (magit-get-current-branch))))
             (worktree-label (rsr/agent-sessions--worktree-label toplevel branch)))
        (list :repo repo-name
              :repo-root (file-name-as-directory main-root)
              :worktree worktree-label
              :worktree-name (file-name-nondirectory
                              (directory-file-name toplevel))
              :branch branch
              :worktree-path (file-name-as-directory toplevel))))))

(defun rsr/agent-sessions--compute-worktrees (root)
  "Return (:label L :path P) for every non-bare worktree of the repo at ROOT.
Runs git; use `rsr/agent-sessions--all-worktrees' for the cached version."
  (ignore-errors
    (let ((default-directory root))
      (delq nil
            (mapcar
             (lambda (wt)
               ;; (PATH COMMIT BRANCH BARE DETACHED LOCKED PRUNABLE)
               (unless (nth 3 wt)
                 (let* ((path (car wt))
                        (branch (nth 2 wt))
                        (label (rsr/agent-sessions--worktree-label path branch)))
                   (list :label label :path (file-name-as-directory path)
                         :branch branch))))
             (magit-list-worktrees))))))

(defvar rsr/agent-sessions--worktrees-cache (make-hash-table :test 'equal)
  "Cache of repo ROOT -> git worktree list, to keep refreshes cheap.
`magit-list-worktrees' spawns a git subprocess per repo, which made
re-rendering (e.g. toggling the sort with `s') slow.  Invalidated by
`rsr/agent-sessions-refresh' (\\`g'), which re-reads git.")

(defun rsr/agent-sessions--all-worktrees (root)
  "Return the cached git worktree list for the repo at ROOT.
Populates the cache on first use; `rsr/agent-sessions-refresh' clears it."
  (let ((cached (gethash root rsr/agent-sessions--worktrees-cache 'miss)))
    (if (eq cached 'miss)
        (puthash root (rsr/agent-sessions--compute-worktrees root)
                 rsr/agent-sessions--worktrees-cache)
      cached)))

(defvar-local rsr/agent-session--previous-id nil
  "The terminal id a previous Emacs gave this session, when it was reattached.
Its agent still carries that id in `EMACS_AGENT_SESSION_ID', so hooks and
`emacs-share' keep resolving through it.
See `rsr/agent-sessions-tmux-reattach'.")

(defun rsr/agent-session--cleanup ()
  (when rsr/agent-session-id
    (when (eq rsr/agent-sessions--last-focused-buffer (current-buffer))
      (setq rsr/agent-sessions--last-focused-buffer nil))
    (rsr/agent-sessions--log-close-buffer)
    (remhash rsr/agent-session-id rsr/agent-session-id->buffer)
    (when rsr/agent-session--previous-id
      (remhash rsr/agent-session--previous-id rsr/agent-session-id->buffer))
    (remhash rsr/agent-session-id rsr/agent-sessions)
    (remhash rsr/agent-session-id rsr/agent-orchestration--mail)
    (rsr/agent-sessions--refresh-if-visible)))

(defun rsr/agent-sessions--vterm-advice (orig-fun pop-to-buf-fun &optional arg)
  (let* ((id (format "%d-%d" (emacs-pid) (cl-incf rsr/agent-session-counter)))
         (vterm-environment (append (rsr/agent-sessions--terminal-environment id)
                                    vterm-environment))
         (buf (funcall orig-fun pop-to-buf-fun arg)))
    (when (buffer-live-p buf)
      (puthash id buf rsr/agent-session-id->buffer)
      (with-current-buffer buf
        (setq-local rsr/agent-session-id id)
        (setq-local rsr/agent-session--created-at (current-time))
        (add-hook 'kill-buffer-hook #'rsr/agent-session--cleanup nil t))
      (rsr/agent-sessions--log-open buf)
      (rsr/agent-sessions--refresh-if-visible))
    buf))

(defvar-local rsr/agent-session-title nil
  "Terminal title most recently set by this vterm's process (OSC escape), if any.
Agents typically set this to something like the current task/session summary.")

(defvar-local rsr/agent-session-title-override nil
  "A user-chosen title for this session, set via the dashboard's `SPC' command.
When non-nil it takes precedence over `rsr/agent-session-title' everywhere the
session is labelled, so the agent's OSC title updates don't clobber it.")

(defvar-local rsr/agent-session--branched-from nil
  "When non-nil, a cons (PARENT-SID . LABEL) recording the session this one was
branched/forked from.  Set on a freshly branched terminal (by the `b' command
or `rsr/agent-sessions-mark-parent') so its agent session records the parentage
once its first hook fires, and preserved across subsequent hook events.")

(defvar-local rsr/agent-session--parent-detached-p nil
  "Non-nil when this session was explicitly detached from its fork parent.
This prevents fork auto-detection from restoring a relationship removed with
`rsr/agent-sessions-detach-parent'.")

(defvar-local rsr/agent-session--marked-unread nil
  "When non-nil, the user marked this session as needing attention (`u').
Kept on the buffer rather than in `rsr/agent-sessions' so it works for a plain
terminal that has no registry entry yet, and so a later hook event's status
computation (which honours the *previous* status) can't be skewed by it.  The
flag only overrides the status at display time, and is cleared the same way a
real needs-attention is: by looking at the session.")

(defun rsr/agent-sessions--capture-title (title)
  (setq-local rsr/agent-session-title title))

(defun rsr/agent-sessions--eat-advice (orig-fun program arg display-fn)
  "Give eat sessions the same id injection/registration as vterm.
Injects EMACS_AGENT_SESSION_ID and the agent command directory via
`process-environment' (which `eat-exec' inherits when it spawns the shell) and
registers the resulting buffer."
  (let* ((id (format "%d-%d" (emacs-pid) (cl-incf rsr/agent-session-counter)))
         (process-environment
          (append (rsr/agent-sessions--terminal-environment id)
                  process-environment))
         (buf (funcall orig-fun program arg display-fn)))
    (when (buffer-live-p buf)
      (puthash id buf rsr/agent-session-id->buffer)
      (with-current-buffer buf
        (setq-local rsr/agent-session-id id)
        (setq-local rsr/agent-session--created-at (current-time))
        (add-hook 'kill-buffer-hook #'rsr/agent-session--cleanup nil t))
      (rsr/agent-sessions--log-open buf)
      (rsr/agent-sessions--refresh-if-visible))
    buf))

;; eat's default title handler is `ignore', so instead capture the title by
;; advising the emulator's title setter, which runs with the eat buffer
;; current (same idea as the `vterm--set-title' advice above).
(defun rsr/agent-sessions--eat-capture-title (title &rest _)
  (setq-local rsr/agent-session-title title))

(defun rsr/agent-sessions--ghostel-advice (orig-fun &rest args)
  "Give ghostel sessions the same id injection/registration as vterm.
Wraps `ghostel-create', the one constructor behind `ghostel', `ghostel-new' and
`ghostel-project'.  `ghostel-environment' is prepended to the child's
environment at spawn, so binding it here reaches the shell the same way
`vterm-environment' does."
  (let* ((id (format "%d-%d" (emacs-pid) (cl-incf rsr/agent-session-counter)))
         (ghostel-environment (append (rsr/agent-sessions--terminal-environment id)
                                      ghostel-environment))
         (buf (apply orig-fun args)))
    (when (buffer-live-p buf)
      (puthash id buf rsr/agent-session-id->buffer)
      (with-current-buffer buf
        (setq-local rsr/agent-session-id id)
        (setq-local rsr/agent-session--created-at (current-time))
        (add-hook 'kill-buffer-hook #'rsr/agent-session--cleanup nil t))
      (rsr/agent-sessions--log-open buf)
      (rsr/agent-sessions--refresh-if-visible))
    buf))

(defun rsr/agent-session--clear-attention-on-focus ()
  "Downgrade needs-attention to `stopped' for the session in the selected window.
A needs-attention session has stopped and is waiting for the user; once the
user looks at it the highlight should clear, but the agent is still idle, so
the status becomes `stopped' rather than `running' (which would wrongly imply
it is thinking/outputting).

Deliberately does not rely on `current-buffer' here: vterm's process filter
briefly makes its buffer current while inserting output even when it isn't
the buffer the user is actually looking at, which would clear the flag
spuriously.

Looking at a tmux session's buffer counts as looking at the agent in that
session's current window (`rsr/agent-tmux-window-of')."
  (rsr/agent-session--clear-attention
   (rsr/agent-tmux-window-of (window-buffer (selected-window)))))

(defun rsr/agent-session--clear-attention (buf)
  "Record that the user is looking at BUF, clearing what that settles.
See `rsr/agent-session--clear-attention-on-focus'."
  (let* ((id (and (buffer-live-p buf) (buffer-local-value 'rsr/agent-session-id buf)))
         (changed nil))
    (unless (eq buf rsr/agent-sessions--last-focused-buffer)
      (setq rsr/agent-sessions--last-focused-buffer buf)
      (when id
        (with-current-buffer buf
          (setq-local rsr/agent-session--viewed-at (current-time)))))
    (when id
      (let ((session (gethash id rsr/agent-sessions)))
        ;; A user-set unread mark clears the same way, and for the same reason:
        ;; the user has now looked at the session.
        (when (buffer-local-value 'rsr/agent-session--marked-unread buf)
          (with-current-buffer buf (setq-local rsr/agent-session--marked-unread nil))
          (setq changed t))
        (when (and session (eq (plist-get session :status) 'needs-attention))
          (puthash id (plist-put session :status 'stopped) rsr/agent-sessions)
          (setq changed t))))
    ;; A shared file stops nagging once it has been read, however it was
    ;; opened — `RET' in the dashboard is the common way, but a file the agent
    ;; also mentioned by path and you jumped to yourself has still been read.
    ;; Gated on the database being open, which it is whenever a terminal has
    ;; ever been created, so an Emacs with no sessions pays nothing for this
    ;; on a hook that runs at every buffer switch.
    (when (and (buffer-live-p buf) (sqlitep rsr/agent-sessions--db))
      (let ((truename (buffer-local-value 'buffer-file-truename buf)))
        (when (and truename
                   (rsr/agent-sessions--shared-path-p truename)
                   (rsr/agent-sessions--set-visited
                    (lambda (f) (equal (file-truename (plist-get f :path))
                                       truename))
                    t))
          (setq changed t))))
    (when changed
      (rsr/agent-sessions--refresh-if-visible))))

(defcustom rsr/agent-session-terminal-notifier
  "/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
  "The `terminal-notifier' binary used for clickable macOS notifications.
It must live inside an app bundle in /Applications or ~/Applications: macOS
grants notification permission only to apps in those locations, so Homebrew's
copy under /opt/homebrew/Cellar is refused.  When missing, `osascript' is used."
  :type 'file)

(defun rsr/agent-session-focus-from-notification (name)
  "Raise Emacs and show the session terminal buffer called NAME.
The click action of a `terminal-notifier' notification, run via emacsclient."
  (let ((buf (get-buffer name)))
    (select-frame-set-input-focus (selected-frame))
    (if (buffer-live-p buf)
        (rsr/agent-sessions--show-terminal buf)
      (message "Session %s is gone." name))))

(defun rsr/agent-session--notify-click-command (buf)
  "Shell command that focuses BUF when its notification is clicked, or nil.
Needs emacsclient and a running server, which the click talks to."
  (let ((client (executable-find "emacsclient")))
    (when (and client (buffer-live-p buf)
               (fboundp 'server-running-p) (server-running-p))
      (format "%s -n -e %s"
              (shell-quote-argument client)
              (shell-quote-argument
               (format "(rsr/agent-session-focus-from-notification %S)"
                       (buffer-name buf)))))))

(defun rsr/agent-session--desktop-notify (title body &optional buf)
  "Show a desktop notification with TITLE and BODY.
On macOS, `terminal-notifier' is used when installed so that clicking the
notification jumps to session terminal BUF; otherwise `osascript', whose
notifications only open Script Editor when clicked.  D-Bus
`notifications-notify' where available, and the echo area otherwise.  Always
non-blocking."
  (let ((notifier (and (eq system-type 'darwin)
                       (file-executable-p rsr/agent-session-terminal-notifier)
                       rsr/agent-session-terminal-notifier))
        (click (and buf (rsr/agent-session--notify-click-command buf))))
    (cond
     (notifier
      ;; One group per buffer, so a newer notice replaces the stale one.
      (apply #'call-process notifier nil 0 nil
             "-title" title "-message" body
             "-group" (format "agent-session:%s" (if buf (buffer-name buf) title))
             (and click (list "-execute" click))))
     ((eq system-type 'darwin)
      (call-process "osascript" nil 0 nil
                    "-e" (format "display notification %S with title %S"
                                 body title)))
     ((fboundp 'notifications-notify)
      (notifications-notify :title title :body body))
     (t (message "%s: %s" title body)))))

(defun rsr/agent-session--notify-attention (buf agent-type info status)
  "Notify that BUF's AGENT-TYPE session needs attention.
INFO is the repo plist from `rsr/agent-session--repo-info'; STATUS is the new
\(attention-worthy) status.  The notification title is `<repo> - <worktree>';
the body names the agent type, state, and its terminal title (task summary)."
  (let* ((repo (plist-get info :repo))
         (wt (plist-get info :worktree))
         (where (cond ((and repo wt) (format "%s - %s" repo wt))
                      (wt wt)
                      (repo repo)
                      (t (buffer-name buf))))
         (title (or (buffer-local-value 'rsr/agent-session-title buf)
                    (buffer-name buf))))
    (rsr/agent-session--desktop-notify
     where
     (format "%s %s: %s"
             agent-type
             (if (eq status 'error) "error" "needs attention")
             title)
     buf)))

(defun rsr/agent-sessions--taken-over-p (existing agent-type buf)
  "Non-nil when a new AGENT-TYPE session has replaced EXISTING in terminal BUF.
Either the old agent reported `SessionEnd', or the program now running in BUF
is AGENT-TYPE while EXISTING recorded another type (an agent killed without
saying so).  A stray event from a daemon with a stale environment meets
neither, so it is still turned away.  An exited agent is gone from the
dashboard for good; its own resume menu brings it back."
  (and existing
       (or (equal (plist-get existing :last-event) "SessionEnd")
           (and (not (equal agent-type (plist-get existing :agent-type)))
                (equal agent-type
                       (rsr/agent-sessions--foreground-command buf))))))

(defun rsr/agent-sessions--hook-buffer (transport-id agent-type payload)
  "Resolve a hook PAYLOAD to its terminal buffer.
TRANSPORT-ID is the `EMACS_AGENT_SESSION_ID' inherited by the hook process.
Normally it names the terminal directly.  A shared agent daemon can retain an
older terminal's environment, however, so prefer an already-known agent
session id and reject a direct buffer that belongs to a different session.
As a final fallback, return the unique unresolved AGENT-TYPE terminal whose
directory matches PAYLOAD's `cwd'; return nil rather than guess if ambiguous."
  (let* ((agent-sid (or (and payload (gethash "session_id" payload))
                        (and payload (gethash "conversation_id" payload))
                        (and payload (gethash "conversationId" payload))
                        (and payload (gethash "thread_id" payload))))
         (cwd (and payload (gethash "cwd" payload)))
         (canonical-cwd (and cwd (ignore-errors
                                   (rsr/agent-sessions--canonical-path cwd))))
         (direct (gethash transport-id rsr/agent-session-id->buffer))
         (known
          (and agent-sid
               (catch 'found
                 (maphash
                  (lambda (_id session)
                    (when (equal agent-sid
                                 (plist-get session :agent-session-id))
                      (let ((buf (plist-get session :buffer)))
                        (when (buffer-live-p buf)
                          (throw 'found buf)))))
                  rsr/agent-sessions)
                 nil))))
    (or known
        (and (buffer-live-p direct)
             (let ((existing (gethash transport-id rsr/agent-sessions)))
               (and (or (null agent-sid)
                        (null (plist-get existing :agent-session-id))
                        (equal agent-sid
                               (plist-get existing :agent-session-id))
                        (rsr/agent-sessions--taken-over-p
                         existing agent-type direct))
                    (or (null canonical-cwd)
                        (equal canonical-cwd
                               (ignore-errors
                                 (rsr/agent-sessions--canonical-path
                                  (buffer-local-value 'default-directory
                                                      direct)))))
                    direct)))
        (and canonical-cwd
             (let (candidates)
               (maphash
                (lambda (id buf)
                  (when (buffer-live-p buf)
                    (let ((existing (gethash id rsr/agent-sessions)))
                      (when (and
                             ;; A terminal already owned by another durable
                             ;; session cannot be this hook's origin.
                             (or (null (plist-get existing :agent-session-id))
                                 (equal agent-sid
                                        (plist-get existing :agent-session-id)))
                             (equal canonical-cwd
                                    (ignore-errors
                                      (rsr/agent-sessions--canonical-path
                                       (buffer-local-value 'default-directory
                                                           buf))))
                             (equal agent-type
                                    (or (plist-get existing :agent-type)
                                        (rsr/agent-sessions--foreground-command
                                         buf))))
                        (push buf candidates)))))
                rsr/agent-session-id->buffer)
               (and (= (length candidates) 1) (car candidates)))))))

(defun rsr/agent-hook-notify (session-id agent-type payload-file)
  "Entry point called via emacsclient from the Claude/Codex hook scripts.
SESSION-ID is the terminal id inherited by the hook process.  The payload's
agent session id and working directory can reroute a stale daemon environment
to the terminal that actually owns the event."
  (let* ((payload (unwind-protect
                      (ignore-errors
                        (json-parse-string (with-temp-buffer
                                              (insert-file-contents payload-file)
                                              (buffer-string))))
                    (ignore-errors (delete-file payload-file))))
         (buf (rsr/agent-sessions--hook-buffer session-id agent-type payload))
         ;; From here onward SESSION-ID must mean the actual terminal being
         ;; updated, not the possibly stale environment value the hook used.
         (session-id (or (and (buffer-live-p buf)
                              (buffer-local-value 'rsr/agent-session-id buf))
                         session-id))
         (event-name (or (and payload (gethash "hook_event_name" payload))
                         (and payload (gethash "type" payload))
                         "unknown"))
         (existing (let ((old (gethash session-id rsr/agent-sessions))
                         (sid (and payload
                                   (or (gethash "session_id" payload)
                                       (gethash "conversation_id" payload)
                                       (gethash "conversationId" payload)
                                       (gethash "thread_id" payload)))))
                     ;; A new agent in the same terminal starts fresh rather
                     ;; than inheriting the exited one's parent, prompt or id.
                     (unless (and old sid (plist-get old :agent-session-id)
                                  (not (equal sid (plist-get old :agent-session-id)))
                                  (buffer-live-p buf)
                                  (rsr/agent-sessions--taken-over-p
                                   old agent-type buf))
                       old)))
         ;; Whether a turn is in progress: opened by the prompt, closed by
         ;; anything that ends one.  Only the status table's own events move
         ;; it, so a straggler cannot reopen a turn that has ended.
         (turn-open (pcase event-name
                      ((or "UserPromptSubmit" "PreInvocation") t)
                      ((or "Stop" "StopFailure" "SessionEnd" "SessionStart"
                           "agent-turn-complete")
                       nil)
                      (_ (and existing (plist-get existing :turn-open)))))
         (status (or (rsr/agent-session--status-for agent-type event-name)
                     ;; A tool finishing mid-turn means the agent is working
                     ;; again: the permission or question that set
                     ;; needs-attention (and looking at it, `stopped') was
                     ;; answered.  Without this the row kept `○' for the rest
                     ;; of the turn.  Not PreToolUse: it races the
                     ;; PermissionRequest of the same tool and would clear the
                     ;; attention before the user saw it.
                     (and turn-open
                          (member event-name '("PostToolUse" "PostToolUseFailure"))
                          'running)
                     (and existing (plist-get existing :status))
                     'running))
         ;; The agent's *own* session id (a UUID), as opposed to our
         ;; per-buffer EMACS_AGENT_SESSION_ID. This is what `claude --resume'
         ;; / `codex resume' need. Not every event carries it, so fall back
         ;; to the previously captured value.
         (agent-session-id (or (and payload (gethash "session_id" payload))
                               (and payload (gethash "conversation_id" payload))
                               (and payload (gethash "conversationId" payload))
                               (and payload (gethash "thread_id" payload))
                               (and existing (plist-get existing :agent-session-id))))
         ;; Path to this session's transcript (Claude includes it on every
         ;; hook, notably SessionStart). Used to auto-detect fork parentage.
         (transcript-path (or (and payload (gethash "transcript_path" payload))
                              (and existing (plist-get existing :transcript-path))))
         ;; Claude leaves the submitted text rendered in its composer while a
         ;; turn starts and sometimes after it stops.  Remember the hook's
         ;; authoritative value so that retained text is not mistaken for a
         ;; new human draft.  Other events preserve the last submitted value.
         (submitted-prompt
          (or (and (equal event-name "UserPromptSubmit")
                   payload
                   (gethash "user_prompt" payload))
              (and existing (plist-get existing :submitted-prompt)))))
    (when (buffer-live-p buf)
      (let* ((info (rsr/agent-sessions--buffer-repo-info buf))
             ;; Parentage, in priority order: what a previous event already
             ;; recorded; the marker a fresh `b'-branch left on the buffer; or,
             ;; the first time we see this session, an auto-detected fork parent
             ;; (a manual `claude … --fork-session' shares the parent's history).
             (branched-from (or (and existing (plist-get existing :branched-from))
                                (buffer-local-value 'rsr/agent-session--branched-from buf)
                                (and (not existing)
                                     (not (buffer-local-value
                                           'rsr/agent-session--parent-detached-p buf))
                                     (equal agent-type "claude")
                                     transcript-path
                                     (rsr/agent-sessions--detect-parent
                                      agent-session-id transcript-path session-id)))))
        (puthash session-id
                 (list :buffer buf
                       :agent-type agent-type
                       :agent-session-id agent-session-id
                       :transcript-path transcript-path
                       :submitted-prompt submitted-prompt
                       :status status
                       :turn-open turn-open
                       :last-event event-name
                       :updated-at (current-time)
                       :repo (plist-get info :repo)
                       :repo-root (plist-get info :repo-root)
                       :worktree (plist-get info :worktree)
                       :worktree-name (plist-get info :worktree-name)
                       :branch (plist-get info :branch)
                       :worktree-path (plist-get info :worktree-path)
                       :branched-from branched-from)
                 rsr/agent-sessions)
        ;; A fork starts in its parent's folder.  Only on the first event, the
        ;; same moment parentage is decided, so it stays a default rather than
        ;; a rule the user's later choice has to fight.
        (unless existing
          (rsr/agent-sessions--folder-inherit
           buf branched-from
           (rsr/agent-sessions--canonical-path (plist-get info :repo-root))))
        (rsr/agent-sessions--folder-hydrate buf agent-session-id)
        (when (and agent-session-id
                   (not (and existing (plist-get existing :agent-session-id))))
          (rsr/agent-sessions--adopt-agent-id
           (gethash session-id rsr/agent-sessions)))
        ;; Keep the restore log in step.  `SessionEnd' is the agent telling us
        ;; it is going away while its terminal stays; every other event just
        ;; describes a session that is still running.  Note this deliberately
        ;; does not appear in `rsr/agent-session-status-alist': ending is not a
        ;; status a straggler event should be able to undo.
        (if (equal event-name "SessionEnd")
            (rsr/agent-sessions--log-end buf)
          (rsr/agent-sessions--log-update buf agent-type agent-session-id))
        ;; Notify only on the transition *into* an attention state, so a
        ;; session that stays waiting isn't re-announced on every later event.
        (when (and rsr/agent-session-notify-on-attention
                   (rsr/agent-sessions--attention-p status)
                   (not (rsr/agent-sessions--attention-p
                         (and existing (plist-get existing :status)))))
          (rsr/agent-session--notify-attention buf agent-type info status))
        ;; This event is where a session's durable identity becomes known, so
        ;; it is also where mail stored for it under that identity — by a
        ;; previous Emacs, or before this terminal had an agent id — is picked
        ;; up.  Then deliver: Codex has a session-aware native queue, while an
        ;; agent without one may have been waiting for this event to make a
        ;; terminal paste safe.
        (rsr/agent-orchestration--hydrate session-id)
        (rsr/agent-orchestration-deliver
         session-id (equal event-name "UserPromptSubmit"))))
    (rsr/agent-sessions--refresh-if-visible))
  nil)

(defvar-local rsr/agent-sessions--repo-info-cache nil
  "Cons of (DIRECTORY . REPO-INFO-PLIST) cached per terminal buffer.
Computing repo info shells out to git, so cache it per buffer and only
recompute when the buffer's `default-directory' changes (e.g. after a `cd').")

(defun rsr/agent-sessions--parent-home (buf)
  "The live session BUF was opened under, when it is placed in a repo, or nil.
BUF's recorded parent (`rsr/agent-session--branched-from') is looked up by
its agent session id, so a parent whose terminal is gone does not count."
  (when-let* ((parent-sid (car (buffer-local-value
                                'rsr/agent-session--branched-from buf)))
              (parent (rsr/agent-sessions--session-for-agent-id parent-sid))
              ((plist-get parent :repo-root)))
    parent))

(defun rsr/agent-sessions--buffer-repo-info (buf)
  "Return `rsr/agent-session--repo-info' for BUF, cached on its directory.
A tmux proxy outside any git repository takes its place from elsewhere.  A
child (a review in its Plans folder, say) belongs with its parent, so it
carries the parent's repo and worktree: that is where its folder is, and the
only group it can nest under the parent in, whichever tmux session either
runs in.  Any other such proxy is grouped by its tmux session: the session's
name stands in for the repo name and the session's start directory for the
repo root.  Either way the tmux session's name is the worktree label (which
the session log keeps, so a resume knows the session) and the proxy's own
directory the worktree path (which the log keeps as the place to resume in)."
  (with-current-buffer buf
    (let* ((dir default-directory)
           (info (if (and rsr/agent-sessions--repo-info-cache
                          (equal (car rsr/agent-sessions--repo-info-cache) dir))
                     (cdr rsr/agent-sessions--repo-info-cache)
                   (cdr (setq rsr/agent-sessions--repo-info-cache
                              (cons dir (rsr/agent-session--repo-info dir)))))))
      (if (and (null (plist-get info :repo)) (rsr/agent-tmux-proxy-p buf))
          (let ((session rsr/agent-tmux-session)
                (parent (rsr/agent-sessions--parent-home buf)))
            (if parent
                (list :repo (plist-get parent :repo)
                      :repo-root (plist-get parent :repo-root)
                      :worktree session
                      :worktree-name (rsr/agent-sessions--session-worktree-name
                                      parent)
                      :branch (rsr/agent-sessions--session-branch parent)
                      :worktree-path (rsr/agent-sessions--canonical-path dir))
              (list :repo session
                    :tmux-session session
                    :repo-root (or (rsr/agent-tmux-session-path session)
                                   (rsr/agent-sessions--canonical-path dir))
                    :worktree session
                    :worktree-name session
                    :branch nil
                    :worktree-path (rsr/agent-sessions--canonical-path dir))))
        info))))

(defun rsr/agent-sessions--session-tmux-group (session)
  "The tmux session SESSION is grouped under, or nil when it groups by repo.
Only an agent outside any git repository groups by its tmux session.  One
working in a repo groups with that repo, whichever tmux session started it, so
the agents changing the same code are always listed together."
  (let ((buf (plist-get session :buffer)))
    (and (buffer-live-p buf)
         (plist-get (rsr/agent-sessions--buffer-repo-info buf) :tmux-session))))

(defvar rsr/agent-sessions--tmux-home-cache (make-hash-table :test 'equal)
  "Cache of tmux start directory -> its repo info, or `none' outside git.
Reading repo info runs git, and the render path asks once per tmux agent.
Cleared by `g'.")

(defconst rsr/agent-sessions--repo-fields
  '(:repo :repo-root :worktree :worktree-name :branch :worktree-path)
  "The session fields that place it under a repo and worktree.")

(defun rsr/agent-sessions--tmux-session-home (tmux)
  "Repo info for the git checkout the tmux session TMUX was started in, or nil."
  (when-let ((dir (rsr/agent-tmux-session-path tmux)))
    (let ((info (or (gethash dir rsr/agent-sessions--tmux-home-cache)
                    (puthash dir (or (rsr/agent-session--repo-info dir) 'none)
                             rsr/agent-sessions--tmux-home-cache))))
      (and (listp info) (plist-get info :repo) info))))

(defun rsr/agent-sessions--tmux-home (session)
  "Repo info for the git checkout SESSION's tmux session was started in, or nil.
An agent outside git in a tmux session started inside a repo (a planning agent
in a Plans folder, say) belongs with that repo's agents, not in a group of its
own beside them."
  (when-let ((tmux (rsr/agent-sessions--session-tmux-group session)))
    (rsr/agent-sessions--tmux-session-home tmux)))

(defun rsr/agent-sessions--adopt-tmux-entries (entries)
  "ENTRIES, with each tmux agent outside git placed in its tmux session's repo.
Such an entry gets a copy of its session carrying that repo's fields and is
marked `:adopted', so grouping treats it as a repo agent.  The registry is
left alone: only the tree's placement changes, and resume still uses the
agent's own directory and tmux session."
  (mapcar (lambda (e)
            (let* ((session (plist-get e :session))
                   (home (rsr/agent-sessions--tmux-home session)))
              (if (not home)
                  e
                (let ((copy (copy-sequence session)))
                  (dolist (field rsr/agent-sessions--repo-fields)
                    (setq copy (plist-put copy field (plist-get home field))))
                  (append (list :session copy :adopted t) e)))))
          entries))

(defun rsr/agent-sessions--buffer-terminal-type (buf)
  "Return a symbol naming BUF's terminal backend (`vterm', `eat', `ghostel', or `term')."
  (pcase (buffer-local-value 'major-mode buf)
    ('vterm-mode 'vterm)
    ('eat-mode 'eat)
    ('ghostel-mode 'ghostel)
    ('rsr/agent-tmux-mode 'tmux)
    (_ 'term)))

(defun rsr/agent-sessions--foreground-groups (buf)
  "Return (TPGID . PGRP) for BUF's terminal, or nil when the platform can't say.
TPGID is the pty's foreground process group, PGRP the shell's own.  ghostel
owns its pty natively, so `get-buffer-process' is only an event pipe there and
the pair comes from ghostel's own probe instead.  A tmux proxy has no process
at all; its window's shell pid, from tmux, takes the process's place."
  (with-current-buffer buf
    (if (derived-mode-p 'ghostel-mode)
        (let ((fg (ignore-errors (ghostel-foreground-pid))))
          (and (integerp fg) (cons fg (ghostel--shell-pgid fg))))
      (let* ((pid (if (derived-mode-p 'rsr/agent-tmux-mode)
                      (rsr/agent-tmux-pane-pid buf)
                    (let ((proc (get-buffer-process buf)))
                      (and proc (process-live-p proc) (process-id proc)))))
             (attrs (and pid (ignore-errors (process-attributes pid)))))
        (and (assq 'tpgid attrs)
             (cons (cdr (assq 'tpgid attrs)) (cdr (assq 'pgrp attrs))))))))

(defvar-local rsr/agent-sessions--foreground-cache nil
  "Cache for `rsr/agent-sessions--foreground-command': (TPGID . NAME).")

(defun rsr/agent-sessions--foreground-command (buf)
  "Name of the command running in the foreground of BUF's terminal, or nil.
Nil means BUF's own shell is in the foreground — nothing is running — so the
caller should fall back to naming the terminal backend.

Reads the pty's foreground process *group* (`tpgid') straight out of Emacs's
native process table: two `process-attributes' calls, no subprocess and no
walk of the process list.  When a command is in the foreground the kernel
points `tpgid' at that job's leader; when it exits, `tpgid' returns to the
shell's own `pgrp', so a row tracks start and finish with no bookkeeping and
nothing to keep in sync.

The name comes from `args', not `comm': Claude's executable lives in a
version-numbered directory, so its `comm' reads \"2.1.231\".  Platforms whose
`process-attributes' omits `tpgid' just get nil, and rows read as before.

The foreground group is re-read on every call, and only the *name* is cached,
reused while that group is unchanged.  That test is exact rather than a
heuristic — the same foreground group is the same job, so its name cannot have
changed — which is why there is no time-based reuse here.  A timed cache was
tried and removed: reading the group for 12 terminals costs ~3.6ms against a
~22ms refresh, and skipping that check bought back only those 3.6ms in
exchange for a label that could be up to a third of a second out of date.  For
a display whose whole purpose is showing what is running now, that is the
wrong side of the trade; `g' already costs ~1.4s, so this is not the expensive
thing on the path.  What the cache does save is real: reading a *command line*
is the costly half, and a job that sits there never pays it twice."
  (with-current-buffer buf
    (let* ((groups (rsr/agent-sessions--foreground-groups buf))
           (tpgid (car groups))
           (pgrp (cdr groups))
           ;; Non-nil only when some job other than the shell holds the
           ;; terminal, i.e. a command is actually running.
           (fg (and (integerp tpgid) (> tpgid 0) (not (eql tpgid pgrp)) tpgid))
           (cache rsr/agent-sessions--foreground-cache))
      (cond
       ((null fg)
        (setq-local rsr/agent-sessions--foreground-cache nil)
        nil)
       ((and cache (eql fg (car cache)))
        (cdr cache))
       (t
        (let* ((args (cdr (assq 'args (ignore-errors (process-attributes fg)))))
               (name (and (stringp args) (not (string-empty-p args))
                          (file-name-nondirectory
                           (car (split-string args nil t))))))
          (setq-local rsr/agent-sessions--foreground-cache (cons fg name))
          name))))))

(defun rsr/agent-sessions--terminal-session (buf)
  "Synthesize a session plist for a plain terminal BUF with no agent session.
These fill in for vterm/eat buffers that have not (yet) fired an agent hook,
so idle terminals still appear in the dashboard tree."
  (let ((info (rsr/agent-sessions--buffer-repo-info buf)))
    (list :buffer buf
          :agent-session-id
          (buffer-local-value 'rsr/agent-session--resuming-session-id buf)
          ;; Whatever is running right now, agent or not; the backend name only
          ;; when the terminal is sitting at its shell prompt.
          :agent-type (or (rsr/agent-sessions--foreground-command buf)
                          (rsr/agent-sessions--buffer-terminal-type buf))
          :status 'idle
          :last-event nil
          :updated-at nil
          ;; What the buffer already knows about its parentage, so a terminal
          ;; that was just branched or spawned nests under the session that
          ;; created it straight away rather than only once its first hook
          ;; event promotes the marker into a registry entry.
          :branched-from (buffer-local-value 'rsr/agent-session--branched-from buf)
          :repo (plist-get info :repo)
          :repo-root (plist-get info :repo-root)
          :worktree (plist-get info :worktree)
          :worktree-name (plist-get info :worktree-name)
          :branch (plist-get info :branch)
          :worktree-path (plist-get info :worktree-path))))

(defun rsr/agent-sessions--session-for-id (id)
  "Return the session plist for ID.
Prefers a real agent session (`rsr/agent-sessions'); falls back to a
synthesized terminal session for a plain terminal buffer that has no
agent hook yet, or nil if no live buffer is registered for ID."
  (or (gethash id rsr/agent-sessions)
      (let ((buf (gethash id rsr/agent-session-id->buffer)))
        (and (buffer-live-p buf)
             (rsr/agent-sessions--terminal-session buf)))))

(defun rsr/agent-sessions--session-for-agent-id (agent-session-id)
  "Return the live session whose durable id is AGENT-SESSION-ID.
Unlike a terminal id, this identity belongs to the Claude or Codex session and
therefore remains trustworthy when a shared agent daemon has retained an older
terminal's environment."
  (catch 'found
    (maphash
     (lambda (_id session)
       (when (and (equal agent-session-id
                         (plist-get session :agent-session-id))
                  (buffer-live-p (plist-get session :buffer)))
         (throw 'found session)))
     rsr/agent-sessions)
    nil))

(defun rsr/agent-sessions--session-for-share (terminal-id agent-session-id)
  "Resolve a share command's TERMINAL-ID and AGENT-SESSION-ID.
Prefer a supplied durable agent identity.  If it is unknown, return nil rather
than fall back to TERMINAL-ID: a stale daemon environment can name a different
live terminal, and attaching work to that session would be worse than failing."
  (if (and agent-session-id (not (string-empty-p agent-session-id)))
      (rsr/agent-sessions--session-for-agent-id agent-session-id)
    (rsr/agent-sessions--session-for-id terminal-id)))

(defun rsr/agent-sessions--session-title (session)
  "The title for SESSION's buffer: the user override if any, else the OSC title."
  (let ((buf (plist-get session :buffer)))
    (and (buffer-live-p buf)
         (or (buffer-local-value 'rsr/agent-session-title-override buf)
             (buffer-local-value 'rsr/agent-session-title buf)))))

(defun rsr/agent-sessions--session-short-label (session)
  "A concise human label for SESSION: its terminal title, else worktree, else id."
  (or (rsr/agent-sessions--session-title session)
      (plist-get session :worktree)
      (plist-get session :agent-session-id)
      "?"))

(defun rsr/agent-sessions--session-label (session)
  "A disambiguating label for SESSION: `<worktree> [<agent>] <title>'.
Used when prompting the user to pick a session."
  (format "%s [%s] %s"
          (or (plist-get session :worktree) "?")
          (plist-get session :agent-type)
          (or (rsr/agent-sessions--session-title session)
              (plist-get session :agent-session-id)
              "")))

(defcustom rsr/agent-session-auto-detect-branches t
  "When non-nil, auto-detect that a Claude session was forked from another.
A fork (`claude --resume … --fork-session', or Claude's own fork feature)
copies the parent's transcript verbatim, so the child's message uuids include
the parent's, sharing the same root uuid.  On the child's first hook we scan
tracked sessions and record the best-matching parent as `:branched-from', the
same field the `b' command and `rsr/agent-sessions-mark-parent' set by hand."
  :type 'boolean)

(defvar rsr/agent-sessions--uuid-cache (make-hash-table :test 'equal)
  "Transcript PATH -> (MTIME ROOT-UUID . UUID-HASHSET).
Caches the message uuids of a JSONL transcript, keyed on file mtime so a
grown transcript is re-read but an unchanged one is not.")

(defun rsr/agent-sessions--transcript-uuids (path)
  "Return (ROOT-UUID . SET) of message uuids in the JSONL transcript at PATH.
ROOT-UUID is the first message uuid (the conversation root, shared by every
fork of a lineage); SET is a hash-set of all message uuids.  Cached by mtime.
Returns nil when PATH is unreadable or has no message uuids."
  (when (and path (file-readable-p path))
    (let* ((mtime (file-attribute-modification-time (file-attributes path)))
           (cached (gethash path rsr/agent-sessions--uuid-cache)))
      (if (and cached (equal (car cached) mtime))
          (cdr cached)
        (let ((set (make-hash-table :test 'equal))
              (root nil))
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (while (re-search-forward
                    "\"uuid\"[[:space:]]*:[[:space:]]*\"\\([0-9a-fA-F-]+\\)\"" nil t)
              (let ((u (match-string 1)))
                (unless root (setq root u))
                (puthash u t set))))
          (if (zerop (hash-table-count set))
              (progn (puthash path (cons mtime nil) rsr/agent-sessions--uuid-cache) nil)
            (cdr (puthash path (cons mtime (cons root set))
                          rsr/agent-sessions--uuid-cache))))))))

(defun rsr/agent-sessions--detect-parent (child-sid child-transcript self-id)
  "Return (PARENT-SID . LABEL) if CHILD-TRANSCRIPT looks like a fork, else nil.
CHILD-SID is the child's own agent session id and SELF-ID its EMACS session id
\(both used to avoid matching the child against itself).  A fork copies its
parent's messages verbatim, so among tracked Claude sessions sharing the
child's root uuid, the parent is the one whose uuids are (almost) fully
contained in the child's; the largest such match is the immediate parent."
  (when rsr/agent-session-auto-detect-branches
    (let ((child (rsr/agent-sessions--transcript-uuids child-transcript)))
      (when (and child (cdr child) (> (hash-table-count (cdr child)) 1))
        (let ((child-root (car child))
              (child-set (cdr child))
              (best nil) (best-overlap 0))
          (maphash
           (lambda (id session)
             (let ((p-path (plist-get session :transcript-path))
                   (p-sid (plist-get session :agent-session-id)))
               (when (and p-path
                          (equal (plist-get session :agent-type) "claude")
                          (not (equal id self-id))
                          (not (and child-sid p-sid (equal p-sid child-sid)))
                          (not (equal p-path child-transcript)))
                 (let ((p (rsr/agent-sessions--transcript-uuids p-path)))
                   (when (and p (cdr p) (equal (car p) child-root))
                     (let ((p-set (cdr p)) (p-size 0) (overlap 0))
                       (maphash (lambda (u _)
                                  (cl-incf p-size)
                                  (when (gethash u child-set) (cl-incf overlap)))
                                p-set)
                       ;; Parent must be (nearly) wholly contained in the child
                       ;; and smaller than it; pick the most-contained match.
                       (when (and (> p-size 0)
                                  (>= overlap 2)
                                  (< p-size (hash-table-count child-set))
                                  (>= (/ (float overlap) p-size) 0.85)
                                  (> overlap best-overlap))
                         (setq best session best-overlap overlap))))))))
           rsr/agent-sessions)
          (when best
            (cons (plist-get best :agent-session-id)
                  (rsr/agent-sessions--session-short-label best))))))))

(defun rsr/agent-sessions--tpgid-readable-p (buf)
  "Non-nil when BUF's terminal platform reports a foreground process group.
Platforms whose `process-attributes' omits `tpgid' make every
`rsr/agent-sessions--foreground-command' call return nil, so there a nil means
`unknown', not `shell in front' — and `running' must not be demoted on it."
  (and (buffer-live-p buf)
       (rsr/agent-sessions--foreground-groups buf)
       t))

(defun rsr/agent-sessions--reconcile-status (session buf)
  "SESSION with `running' demoted to `stopped' when BUF's terminal is idle.
Status only becomes `running' from a hook event, and only a later event moves
it off — so an agent killed mid-turn (no `session_shutdown' / `SessionEnd'
fires) freezes there forever.  Demote only when the platform can name a
foreground group and it is empty: the shell then owns the terminal, so no turn
can be in progress.  An idle pi still holds the foreground with its TUI, which
is why the SessionStart mapping in `rsr/agent-session-status-alist' — not this
— covers the idle-at-prompt case.  Returns a copy; the registry stays the
hook's record, exactly as `rsr/agent-sessions--unread-status' does."
  (if (and (eq (plist-get session :status) 'running)
           (rsr/agent-sessions--tpgid-readable-p buf)
           (not (rsr/agent-sessions--foreground-command buf)))
      (plist-put (copy-sequence session) :status 'stopped)
    session))

(defun rsr/agent-sessions--unread-status (session buf)
  "SESSION with its status forced to `needs-attention' if BUF is marked unread.
Returns a *copy* — the registry plist must not be mutated, or the mark would
leak into the status a later hook event inherits.  An `error' status outranks
the mark and is left alone."
  (if (and (buffer-live-p buf)
           (buffer-local-value 'rsr/agent-session--marked-unread buf)
           (not (memq (plist-get session :status) '(needs-attention error))))
      (plist-put (copy-sequence session) :status 'needs-attention)
    session))

(defun rsr/agent-sessions--live-entries ()
  "Return (:id ID :session PLIST :title TITLE) for each live terminal buffer.
Includes both real agent sessions (those a hook event has fired for) and
plain vterm/eat buffers with no agent session yet, so idle terminals still
show up in the dashboard.  Opportunistically drops registry entries whose
buffer has been killed, since `kill-buffer-hook' cleanup can be missed (e.g.
buffer killed without running local hooks).  A tmux proxy whose window has
closed counts as dead (`rsr/agent-sessions--sync-tmux')."
  (let ((dead (rsr/agent-sessions--sync-tmux))
        entries)
    ;; Real agent sessions: a hook event has fired for these.
    (maphash
     (lambda (id session)
       (let ((buf (plist-get session :buffer)))
         (cond
          ;; Left for its scheduled kill, whose cleanup logs the close and
          ;; needs the registry entry to do it.
          ((memq buf dead))
          ((buffer-live-p buf)
           (push (list :id id
                       :session (rsr/agent-sessions--unread-status
                                 (rsr/agent-sessions--reconcile-status session buf)
                                 buf)
                       :title (or (buffer-local-value 'rsr/agent-session-title-override buf)
                                  (buffer-local-value 'rsr/agent-session-title buf)))
                 entries))
          (t
           (remhash id rsr/agent-sessions)
           (remhash id rsr/agent-session-id->buffer)))))
     rsr/agent-sessions)
    ;; Plain terminal buffers with no agent session yet.  A reattached proxy
    ;; is also filed under its previous Emacs's id, an alias for hooks and
    ;; `emacs-share' only; listing it would show the buffer twice.
    (maphash
     (lambda (id buf)
       (cond ((memq buf dead))
             ((not (buffer-live-p buf))
              (remhash id rsr/agent-session-id->buffer))
             ((not (equal id (buffer-local-value 'rsr/agent-session-id buf))))
             ((not (gethash id rsr/agent-sessions))
              (push (list :id id
                          :session (rsr/agent-sessions--unread-status
                                    (rsr/agent-sessions--terminal-session buf) buf)
                          :title (or (buffer-local-value 'rsr/agent-session-title-override buf)
                                    (buffer-local-value 'rsr/agent-session-title buf)))
                    entries))))
     rsr/agent-session-id->buffer)
    (nreverse entries)))

(defun rsr/agent-sessions--sync-tmux ()
  "Bring tmux proxies up to date; return those whose windows have closed.
Titles follow the window's title, as OSC titles do for the other backends.
Closed windows' proxies are killed just after the current render (killing
one refreshes the dashboard, which must not happen inside a render); their
cleanup logs the close.  Asks tmux nothing when there are no proxies."
  (when-let ((proxies (rsr/agent-tmux-proxies)))
    (let ((dead (rsr/agent-tmux-dead-proxies proxies)))
      (dolist (buf proxies)
        (unless (memq buf dead)
          (when-let ((title (rsr/agent-tmux-pane-title buf)))
            (with-current-buffer buf
              (setq-local rsr/agent-session-title title)))))
      (when dead
        (run-at-time 0 nil #'rsr/agent-tmux-reap dead))
      dead)))

(defface rsr/agent-session-needs-attention
  '((t :inherit warning :weight bold :extend t
       :background "#4a3b00" :foreground "#ffd75f"))
  "Face for a session row that needs attention (spans the full row).")

(defface rsr/agent-session-error
  '((t :inherit error :weight bold :extend t
       :background "#4a1010" :foreground "#ff8f8f"))
  "Face for a session row in the error state (spans the full row).")

(defface rsr/agent-session-on-screen
  '((((background dark)) :background "#1f2f3a" :extend t)
    (t :background "#e3edf3" :extend t))
  "Background of the row whose terminal is on screen.
Left off a row that needs attention or has failed, whose own background says
more.")

(defface rsr/agent-session-on-screen-glyph
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for `rsr/agent-sessions-on-screen-glyph'.")

(defcustom rsr/agent-sessions-on-screen-glyph "▸"
  "Drawn at the left edge of the row whose terminal is on screen.
It takes the place of the row's first indent column, so nothing shifts."
  :type 'string
  :group 'rsr/agent-sessions)

(defun rsr/agent-sessions--face-for (status)
  (pcase status
    ('needs-attention 'rsr/agent-session-needs-attention)
    ('error 'rsr/agent-session-error)
    (_ 'default)))

(defvar-local rsr/agent-sessions--row-status nil
  "Alist of (LINE-POS . STATUS) for the rows as last rendered, in buffer order.
Filled by the render path and consumed by `N'/`P'.  It exists because the
status a row *shows* is not the one in the registry — `rsr/agent-sessions--
unread-status' overlays the `u' mark onto a copy at display time — so a
navigation command that re-derives status from the registry silently skips
every manually marked row.  Record what was drawn; don't derive it twice.")

(defvar-local rsr/agent-sessions--row-buffers nil
  "Alist of (LINE-POS . BUFFER) for the session rows as last rendered.
Filled beside `rsr/agent-sessions--row-status', for the same reason: the
on-screen mark (`rsr/agent-sessions--mark-on-screen') moves between renders
and must find the rows that were drawn, not look them up again.")

(defun rsr/agent-orchestration--messages (id)
  (gethash id rsr/agent-orchestration--mail))

(defun rsr/agent-orchestration--pending (id &optional types)
  "Unread messages for ID, optionally filtered to TYPES (a list of strings)."
  (seq-filter (lambda (m)
                (and (not (plist-get m :read))
                     (or (null types) (member (plist-get m :type) types))))
              (rsr/agent-orchestration--messages id)))

(defun rsr/agent-orchestration--pending-count (id)
  (length (rsr/agent-orchestration--pending id)))

(defun rsr/agent-orchestration--consume (messages)
  "Mark MESSAGES read, in memory and in the database.
Each plist carries `:read' from birth so this mutates the stored plist rather
than a copy.  The database write is what stops a message being delivered twice
across a restart; a failure to record it is reported rather than raised, since
an agent reading its inbox must not fail because the database is busy."
  (let ((now (rsr/agent-sessions--now)))
    (dolist (m messages)
      (plist-put m :read t)
      (condition-case err
          (sqlite-execute (rsr/agent-sessions--db)
                          "UPDATE mail SET read_at = ? WHERE id = ?"
                          (list now (plist-get m :id)))
        (error (message "agent-sessions: could not mark mail read (%s)"
                        (error-message-string err)))))))

(defun rsr/agent-orchestration--row-badge (id)
  "The dashboard suffix announcing unread mail for ID, or an empty string."
  (let ((n (rsr/agent-orchestration--pending-count id)))
    (if (> n 0) (format "  ✉%d" n) "")))

(defun rsr/agent-sessions--session-worktree-name (session)
  "Return SESSION's worktree directory name, including older registry entries."
  (or (plist-get session :worktree-name)
      (let* ((label (plist-get session :worktree))
             (path (plist-get session :worktree-path))
             (name (and path (file-name-nondirectory
                              (directory-file-name path)))))
        (if (and name label (string-prefix-p (concat name " (") label)
                 (string-suffix-p ")" label))
            name
          (or label name "?")))))

(defun rsr/agent-sessions--session-branch (session)
  "Return SESSION's branch, including older registry entries."
  (or (plist-get session :branch)
      (let* ((label (plist-get session :worktree))
             (name (rsr/agent-sessions--session-worktree-name session))
             (prefix (concat name " (")))
        (and label (string-prefix-p prefix label)
             (string-suffix-p ")" label)
             (substring label (length prefix) -1)))))

(defun rsr/agent-sessions--session-at-label (session)
  "The `@' label of SESSION's worktree; see `rsr/agent-sessions--at-label'."
  (rsr/agent-sessions--at-label (plist-get session :worktree-path)
                                (rsr/agent-sessions--session-worktree-name session)
                                (rsr/agent-sessions--session-branch session)))

;;;; Line icons and part faces
;;
;; Every kind of line gets an icon, and the parts of a line their own face, so
;; a repo, a directory group, a session, a file and a link read differently at
;; a glance.  The faces inherit theme faces, so they follow light and dark
;; themes; customize any of them by name.

(defface rsr/agent-session-repo
  '((t :inherit (font-lock-keyword-face bold)))
  "Face for a repo heading.")

(defface rsr/agent-session-agent
  '((t :inherit font-lock-keyword-face))
  "Face for the agent name on a session row.")

(defface rsr/agent-session-status-running
  '((t :inherit success))
  "Face for the `running' status glyph.")

(defface rsr/agent-session-status-idle
  '((t :inherit font-lock-constant-face))
  "Face for the `idle' status glyph.")

(defface rsr/agent-session-status-stopped
  '((t :inherit shadow))
  "Face for the `stopped' status glyph.")

(defface rsr/agent-session-status
  '((t :inherit font-lock-type-face))
  "Face for any other status glyph.")

(defface rsr/agent-session-worktree-name
  '((t :inherit font-lock-string-face))
  "Face for the `@' worktree label on a folder heading and a session row.")

(defface rsr/agent-session-detail
  '((t :inherit shadow))
  "Face for a session row's trailing details: folder, `↳ from', branch.")

(defface rsr/agent-session-file-name
  '((t :inherit font-lock-function-name-face))
  "Face for the name of a shared file.")

(defface rsr/agent-session-file-label
  '((t :inherit shadow))
  "Face for the label after a shared file's name.")

(defface rsr/agent-session-link-kind
  '((t :inherit font-lock-builtin-face))
  "Face for the kind label of a shared link.")

(defconst rsr/agent-sessions--icon-specs
  '((repo nerd-icons-octicon "nf-oct-repo" rsr/agent-session-repo)
    (tmux nerd-icons-codicon "nf-cod-terminal_tmux" rsr/agent-session-repo)
    (worktree nerd-icons-octicon "nf-oct-file_directory" font-lock-function-name-face)
    (folder nerd-icons-mdicon "nf-md-folder_star" font-lock-function-name-face)
    (note nerd-icons-mdicon "nf-md-note_text_outline" rsr/agent-session-note)
    (link nerd-icons-octicon "nf-oct-link_external" rsr/agent-session-link-kind)
    ("claude" nerd-icons-codicon "nf-cod-claude" font-lock-constant-face)
    ("pi" nerd-icons-mdicon "nf-md-pi_box" font-lock-type-face)
    ("codex" nerd-icons-mdicon "nf-md-code_braces" font-lock-string-face)
    ("agy" nerd-icons-mdicon "nf-md-google" font-lock-keyword-face)
    (agent nerd-icons-mdicon "nf-md-robot_outline" rsr/agent-session-agent))
  "(KIND FUNCTION NAME FACE) for each line icon.
KIND is a line kind, or an agent type string for a session row (`agent' for an
agent not listed); FACE colors the icon.")

(declare-function nerd-icons-icon-for-file "nerd-icons")

(defun rsr/agent-sessions--icon (kind &optional file)
  "The icon for line KIND and a space, or \"\" with icons off or unavailable.
With FILE, the icon is the one `nerd-icons' gives that file's type.  The
icon's font goes on `font-lock-face': these buffers run font-lock, which
strips a plain `face', and without its font the glyph does not render."
  (if (not (and rsr/agent-sessions-icons (require 'nerd-icons nil t)))
      ""
    (let* ((spec (and (not file)
                      (or (assoc kind rsr/agent-sessions--icon-specs)
                          (assq 'agent rsr/agent-sessions--icon-specs))))
           (icon (if file
                     (nerd-icons-icon-for-file file)
                   (funcall (nth 1 spec) (nth 2 spec))))
           (font (get-text-property 0 'face icon)))
      (concat (propertize (substring-no-properties icon) 'font-lock-face
                          (if spec (list font (nth 3 spec)) font))
              " "))))

(defconst rsr/agent-sessions--highlight-faces
  '(rsr/agent-session-needs-attention rsr/agent-session-error
    rsr/agent-session-file-unvisited rsr/agent-session-link-unvisited)
  "Line faces that must keep their color over the parts' own faces.")

(defun rsr/agent-sessions--dress (string face)
  "STRING with FACE as the `font-lock-face' of every part, layered with its own.
A plain `propertize' would replace an icon's font and the parts' colors.  A
part's own face wins, except under a highlight face (attention, error, an
unopened file or link), whose color must hold across the whole line."
  (let ((s (copy-sequence string))
        (pos 0)
        (len (length string)))
    (while (< pos len)
      (let ((end (next-single-property-change pos 'font-lock-face s len))
            (own (get-text-property pos 'font-lock-face s)))
        (put-text-property pos end 'font-lock-face
                           (cond ((null own) face)
                                 ((memq face rsr/agent-sessions--highlight-faces)
                                  (list face own))
                                 (t (list own face)))
                           s)
        (setq pos end)))
    s))

(defun rsr/agent-sessions--status-face (status)
  "The face for the STATUS glyph on a session row."
  (pcase status
    ('running 'rsr/agent-session-status-running)
    ('idle 'rsr/agent-session-status-idle)
    ('stopped 'rsr/agent-session-status-stopped)
    (_ 'rsr/agent-session-status)))

(defun rsr/agent-sessions--status-glyph (status)
  "The glyph that stands for STATUS at the start of a session row.
A glyph rather than the status word keeps the row narrow enough for a side
window; the needs-attention and error row faces still span the whole line."
  (pcase status
    ('running "●")
    ('idle "◐")
    ('stopped "○")
    ('needs-attention "●")
    ('error "✖")
    (_ " ")))

(defun rsr/agent-sessions--detail (string)
  "STRING in `rsr/agent-session-detail', or \"\" for an empty one."
  (if (string-empty-p string) "" (propertize string 'font-lock-face 'rsr/agent-session-detail)))

(defun rsr/agent-sessions--row-text (prefix state suffix face)
  "Build a session row: PREFIX, then STATE (when non-nil) and SUFFIX.
STATE goes at the end of what the row says rather than in a column, so a row
with none spends no blank space before its title.
FACE dresses the whole row (it is what spans an attention highlight across it),
and the state's own face is *merged* on top rather than replacing it — merged,
because the state faces set a foreground and the row face sets a background, and
either replacing the row face or letting it win would lose one of the two."
  (let* ((column (if state (concat "  " state) ""))
         (start (+ (length prefix) (if state 2 0)))
         (row (rsr/agent-sessions--dress (concat prefix column suffix) face))
         (state-face (and state (rsr/agent-sessions--state-face state))))
    (when state-face
      ;; A *list* of faces on `font-lock-face', not `add-face-text-property':
      ;; that function merges into `face', which these rows do not use (magit
      ;; buffers run font-lock, which owns `face'), so the merge was silently
      ;; ignored.  Earlier faces in the list win per attribute, which is
      ;; exactly the split wanted here — the state's foreground over the row's
      ;; background.
      (put-text-property start
                         (+ start (length state))
                         'font-lock-face (list state-face face)
                         row))
    row))

(defun rsr/agent-sessions--row-title (title)
  "TITLE without the activity glyph an agent puts in front of it.
Claude Code prefixes its terminal title with `✳' when idle and a braille
spinner frame while working; the row's own status glyph already says that."
  (replace-regexp-in-string "\\`[✳✻✽✶✢·⠀-⣿]+ *" "" (or title "")))

(defun rsr/agent-sessions--insert-session (entry &optional depth suppress-parent-note)
  "Insert a session row for ENTRY.
DEPTH indents the row (children of a branched-from parent are rendered one
level deeper).  When SUPPRESS-PARENT-NOTE is non-nil the `↳ from …' suffix is
omitted — used when the row is already nested under its parent, where the
indentation conveys the relationship."
  (let* ((id (plist-get entry :id))
         (session (plist-get entry :session))
         (status (plist-get session :status))
         (face (rsr/agent-sessions--face-for status))
         (marker (propertize (concat (rsr/agent-sessions--status-glyph status) " ")
                             'font-lock-face (rsr/agent-sessions--status-face status)))
         (title (rsr/agent-sessions--row-title (plist-get entry :title)))
         (branched-from (plist-get session :branched-from))
         (indent (make-string (* 2 (or depth 0)) ?\s))
         ;; A child row draws `└' in its last indent step, so the tie to the
         ;; parent above shows even where the indent alone is easy to miss.
         (connector (if (and depth (> depth 0))
                        (concat (make-string (* 2 (1- depth)) ?\s)
                                (propertize "└ " 'font-lock-face
                                            'rsr/agent-session-detail))
                      ""))
         (base "    "))
    ;; Record what this row *shows*, for `N'/`P' (see the variable's docstring).
    (push (cons (line-beginning-position) status) rsr/agent-sessions--row-status)
    (push (cons (line-beginning-position) (plist-get session :buffer))
          rsr/agent-sessions--row-buffers)
    (magit-insert-section (rsr/agent-session-row id)
      ;; A heading rather than a plain insert so the row's note becomes its
      ;; collapsible body; with no note the body is empty and magit shows no
      ;; fold indicator.
      (magit-insert-heading
        (rsr/agent-sessions--row-text
         (concat base connector marker title
                 (rsr/agent-orchestration--row-badge id)
                 ;; Only when it differs from the one its heading names.
                 (if-let ((label (plist-get entry :at-label)))
                     (propertize (concat "  " label)
                                 'font-lock-face 'rsr/agent-session-worktree-name)
                   "")
                 (rsr/agent-sessions--detail
                  (if (and branched-from (not suppress-parent-note))
                      (format "  ↳ from %s" (cdr branched-from))
                    ""))
                 (rsr/agent-sessions--detail
                  ;; The `@' column already names the branch unless it is set
                  ;; to show folders.
                  (if-let ((branch (and (eq rsr/agent-sessions-worktree-label 'folder)
                                       (rsr/agent-sessions--session-branch session))))
                      (format "  (%s)" branch)
                    ""))
                 ;; The agent goes last: the title is what tells rows apart.
                 (if-let ((agent (plist-get session :agent-type)))
                     (concat "  " (rsr/agent-sessions--icon agent)
                             (propertize (format "%s" agent)
                                         'font-lock-face 'rsr/agent-session-agent))
                   ""))
         (rsr/agent-sessions--session-state session)
         "\n"
         face))
      (rsr/agent-sessions--insert-note
       (rsr/agent-sessions--session-note-keys session)
       (concat base indent "    "))
      (let ((rsr/agent-sessions--attachment-width
             (rsr/agent-sessions--attachment-name-width session)))
        (rsr/agent-sessions--insert-links session (concat base indent "    "))
        (rsr/agent-sessions--insert-files session (concat base indent "    "))))))

(defun rsr/agent-sessions--insert-entries (entries)
  "Insert ENTRIES, nesting any branched session under its parent when present.
A session whose `:branched-from' parent id matches another entry in ENTRIES is
rendered indented directly beneath that parent (one extra level per hop);
entries whose parent isn't in this list render at the top level.

The parent/child graph is built and walked by unique entry `:id' (never by
the shared agent session id) and a session is never made its own parent, so
duplicate session ids and reference cycles cannot cause infinite recursion; a
visited set and a final safety-net pass guarantee each entry renders exactly
once."
  (let ((by-sid (make-hash-table :test 'equal))    ; agent-session-id -> entries
        (children (make-hash-table :test 'equal))  ; parent entry :id -> child entries
        (parent-of (make-hash-table :test 'equal)) ; entry :id -> t when it has a parent
        (roots nil))
    ;; Index sid -> list of entries (a session id can appear in more than one
    ;; terminal — notably a just-forked child briefly shares its parent's id
    ;; until the fork mints a new one).
    (dolist (e entries)
      (let ((sid (plist-get (plist-get e :session) :agent-session-id)))
        (when sid (push e (gethash sid by-sid)))))
    (maphash (lambda (sid es) (puthash sid (nreverse es) by-sid)) by-sid)
    ;; Resolve each entry's parent from its recorded parent session id.  Match a
    ;; *different* entry carrying that id: a fork can transiently share its
    ;; parent's session id, so `sid = psid' is fine as long as it's another
    ;; terminal.  The visited set below is what actually prevents cycles.
    (dolist (e entries)
      (let* ((psid (car (plist-get (plist-get e :session) :branched-from)))
             (parent (and psid
                          (seq-find (lambda (c) (not (eq c e)))
                                    (gethash psid by-sid)))))
        (when parent
          (puthash (plist-get e :id) t parent-of)
          (push e (gethash (plist-get parent :id) children)))))
    (dolist (e entries)
      (unless (gethash (plist-get e :id) parent-of)
        (push e roots)))
    (setq roots (nreverse roots))
    (let ((visited (make-hash-table :test 'equal)))
      (cl-labels ((emit (e depth nested)
                    (unless (gethash (plist-get e :id) visited)
                      (puthash (plist-get e :id) t visited)
                      (rsr/agent-sessions--insert-session e depth nested)
                      (dolist (c (reverse (gethash (plist-get e :id) children)))
                        (emit c (1+ depth) t)))))
        (dolist (r roots) (emit r 0 nil))
        ;; Safety net: any entry not reached from a root (e.g. a mutual cycle)
        ;; still renders, at top level.
        (dolist (e entries) (emit e 0 nil))))))

(defun rsr/agent-sessions--entry-time (entry)
  "The :updated-at time of ENTRY's session, or nil."
  (plist-get (plist-get entry :session) :updated-at))

(defun rsr/agent-sessions--entries-time (entries)
  "The most recent :updated-at among ENTRIES, or nil when none have one."
  (let (best)
    (dolist (e entries best)
      (let ((tm (rsr/agent-sessions--entry-time e)))
        (when (and tm (or (null best) (time-less-p best tm)))
          (setq best tm))))))

(defun rsr/agent-sessions--by-recency (time-fn items)
  "Return ITEMS sorted most-recent-first by (TIME-FN item).
Items whose TIME-FN returns nil (no activity, e.g. empty worktrees) sort last."
  (sort (copy-sequence items)
        (lambda (a b)
          (let ((ta (funcall time-fn a))
                (tb (funcall time-fn b)))
            (cond ((and ta tb) (time-less-p tb ta))
                  (ta t)
                  (t nil))))))

(defconst rsr/agent-sessions--status-rank
  '((error . 0) (needs-attention . 1) (running . 2))
  "Sort rank per status; anything unlisted (stopped, idle, nil) ranks last.
Only these coarse buckets participate in ordering: a status change is a rare,
meaningful event (a session started waiting on you), so a row moving between
buckets carries information, whereas a row moving because a tool ran does not.")

(defun rsr/agent-sessions--entry-rank (entry)
  (or (alist-get (plist-get (plist-get entry :session) :status)
                 rsr/agent-sessions--status-rank)
      (length rsr/agent-sessions--status-rank)))

(defun rsr/agent-sessions--entry-created (entry)
  "ENTRY's buffer creation time, or nil for a buffer registered before the
`rsr/agent-session--created-at' stamp existed."
  (let ((buf (plist-get (plist-get entry :session) :buffer)))
    (and (buffer-live-p buf)
         (buffer-local-value 'rsr/agent-session--created-at buf))))

(defun rsr/agent-sessions--session-buffer-name (session)
  (let ((buf (plist-get session :buffer)))
    (or (and (buffer-live-p buf) (buffer-name buf)) "")))

(defun rsr/agent-sessions--entry-buffer-name (entry)
  (rsr/agent-sessions--session-buffer-name (plist-get entry :session)))

(defun rsr/agent-sessions--sort-entries (entries)
  "Sort ENTRIES by attention bucket, then oldest-first, then buffer name.
The attention bucket is skipped when `rsr/agent-sessions-sort-by-attention'
is nil, leaving creation order alone.
Every key is stable under ordinary activity: unlike `:updated-at', none of
them changes when a session merely runs a tool, so two busy sessions keep
their positions instead of trading places on each hook event.  The buffer name
is the final tie-break so the order never depends on hash-table iteration
order (e.g. for buffers with no creation stamp)."
  (sort (copy-sequence entries)
        (lambda (a b)
          (let ((ra (if rsr/agent-sessions-sort-by-attention
                        (rsr/agent-sessions--entry-rank a)
                      0))
                (rb (if rsr/agent-sessions-sort-by-attention
                        (rsr/agent-sessions--entry-rank b)
                      0)))
            (if (/= ra rb)
                (< ra rb)
              (let ((ca (rsr/agent-sessions--entry-created a))
                    (cb (rsr/agent-sessions--entry-created b)))
                (cond ((and ca cb (not (time-equal-p ca cb))) (time-less-p ca cb))
                      ;; Unstamped buffers sort after stamped ones.
                      ((and ca (not cb)) t)
                      ((and cb (not ca)) nil)
                      (t (string< (rsr/agent-sessions--entry-buffer-name a)
                                  (rsr/agent-sessions--entry-buffer-name b))))))))))

;;; Persisted user intent ---------------------------------------------------
;;
;; Everything else in this file is rebuilt from live buffers, but the manual
;; order (below) and the notes (further down) record decisions the *user* made,
;; not observed session state, so they are written to disk (see CLAUDE.md).
;; All three live in one SQLite file: the notes, the manual order, and the
;; session log that `R' and `rsr/agent-sessions-restore-previous' read.  The log
;; is what forced a database — it is append-heavy, queried by recency, and
;; grows without bound, so the old rewrite-the-whole-file-per-change approach
;; was never going to fit it.  Notes and order moved in alongside so there is
;; exactly one persistent thing to back up, inspect, or delete.
;;
;; Both of those are still cached in a hash table and read from it: the render
;; path must never touch the database.  The database is read once on first use
;; and written only when something actually changes.

(defcustom rsr/agent-sessions-db-file
  (expand-file-name "agent-sessions.db" user-emacs-directory)
  "SQLite file holding the notes, the manual order, and the session log."
  :type 'file)

(defconst rsr/agent-sessions--schema-version 3)

(defvar rsr/agent-sessions--db nil
  "Open SQLite handle, or nil before the database is first used.")

(defvar rsr/agent-sessions--heartbeat-timer nil
  "Timer stamping `meta.last_seen'; see `rsr/agent-sessions--db-heartbeat'.")

(defconst rsr/agent-sessions--db-schema
  '("CREATE TABLE IF NOT EXISTS meta (
       key   TEXT PRIMARY KEY,
       value TEXT NOT NULL)"

    ;; One row per agent session — not per terminal.  A terminal you run
    ;; `claude' in twice produces two rows, so either can be restored.
    "CREATE TABLE IF NOT EXISTS sessions (
       id           INTEGER PRIMARY KEY,
       emacs_sid    TEXT    NOT NULL,
       agent_type   TEXT,
       agent_sid    TEXT,
       worktree     TEXT    NOT NULL,
       repo         TEXT,
       label        TEXT,
       title        TEXT,
       opened_at    INTEGER NOT NULL,
       closed_at    INTEGER,
       close_reason TEXT)"
    "CREATE INDEX IF NOT EXISTS sessions_recent ON sessions (closed_at DESC)"
    "CREATE INDEX IF NOT EXISTS sessions_open
       ON sessions (emacs_sid) WHERE closed_at IS NULL"
    "CREATE INDEX IF NOT EXISTS sessions_agent ON sessions (agent_sid)"

    "CREATE TABLE IF NOT EXISTS folders (
       id   INTEGER PRIMARY KEY,
       repo TEXT NOT NULL,
       name TEXT NOT NULL COLLATE NOCASE,
       UNIQUE (repo, name))"
    "CREATE TABLE IF NOT EXISTS session_folders (
       agent_sid TEXT PRIMARY KEY,
       folder_id INTEGER NOT NULL)"

    "CREATE TABLE IF NOT EXISTS notes (
       kind       TEXT NOT NULL,
       key        TEXT NOT NULL,
       note       TEXT NOT NULL,
       updated_at INTEGER NOT NULL,
       PRIMARY KEY (kind, key))"

    ;; The scope columns default to '' rather than NULL on purpose: SQLite
    ;; treats NULLs as distinct from each other in a primary key, so a NULL
    ;; scope would make every write insert a duplicate instead of replacing.
    ;; The workflow state a session is in (`t' in the dashboard).  Keyed like a
    ;; note, because it is the same kind of thing: something the user chose
    ;; about a session, which would be useless if it evaporated on restart.
    "CREATE TABLE IF NOT EXISTS session_states (
       kind       TEXT NOT NULL,
       key        TEXT NOT NULL,
       state      TEXT NOT NULL,
       updated_at INTEGER NOT NULL,
       PRIMARY KEY (kind, key))"

    "CREATE TABLE IF NOT EXISTS order_entries (
       kind           TEXT    NOT NULL,
       scope_repo     TEXT    NOT NULL DEFAULT '',
       scope_worktree TEXT    NOT NULL DEFAULT '',
       member         TEXT    NOT NULL,
       position       INTEGER NOT NULL,
       PRIMARY KEY (kind, scope_repo, scope_worktree, member))"
    "CREATE INDEX IF NOT EXISTS order_group
       ON order_entries (kind, scope_repo, scope_worktree, position)"

    ;; Files an agent handed the user to look at, keyed by the same identity a
    ;; session's note uses.  Two timestamps, not one: `shared_at' is the first
    ;; time a path was shared and is what orders the list, while `updated_at'
    ;; is the latest, so an agent re-sharing a changed file can light its row
    ;; up again without the row moving out from under the cursor.
    ;; Mail between agents.  Filed under the same durable identity a note or a
    ;; shared file uses, never under the terminal id it was addressed to at
    ;; runtime: terminal ids carry this Emacs's pid and die with it, while the
    ;; agent session id is what `R' resumes, so mail filed under it comes back
    ;; attached to the conversation it belongs to.  Read messages are kept
    ;; rather than deleted, the way `sessions' keeps closed rows: what the
    ;; workers reported is the record of the run.
    "CREATE TABLE IF NOT EXISTS mail (
       id         TEXT PRIMARY KEY,
       from_kind  TEXT NOT NULL,
       from_key   TEXT NOT NULL,
       from_label TEXT,
       to_kind    TEXT NOT NULL,
       to_key     TEXT NOT NULL,
       type       TEXT NOT NULL,
       subject    TEXT NOT NULL,
       body       TEXT,
       files      TEXT,
       report     TEXT,
       sent_at    INTEGER NOT NULL,
       read_at    INTEGER)"
    "CREATE INDEX IF NOT EXISTS mail_inbox ON mail (to_kind, to_key, read_at)"

    "CREATE TABLE IF NOT EXISTS shared_files (
       kind       TEXT    NOT NULL,
       key        TEXT    NOT NULL,
       path       TEXT    NOT NULL,
       label      TEXT,
       shared_at  INTEGER NOT NULL,
       updated_at INTEGER NOT NULL,
       visited_at INTEGER,
       PRIMARY KEY (kind, key, path))"

    ;; The two most recent copies made when an agent shared a file.  The
    ;; contents live outside SQLite in `rsr/agent-sessions-file-snapshot-directory';
    ;; this table only follows the same durable owner identity as the file row.
    "CREATE TABLE IF NOT EXISTS shared_file_snapshots (
       kind          TEXT    NOT NULL,
       key           TEXT    NOT NULL,
       path          TEXT    NOT NULL,
       previous_path TEXT,
       current_path  TEXT    NOT NULL,
       updated_at    INTEGER NOT NULL,
       PRIMARY KEY (kind, key, path))"

    ;; External work items an agent wants to keep visible beside its shared
    ;; files.  Each URL has its own row; retrying a registration is idempotent.
    "CREATE TABLE IF NOT EXISTS shared_links (
       owner_kind TEXT    NOT NULL,
       owner_key  TEXT    NOT NULL,
       link_kind  TEXT    NOT NULL,
       url        TEXT    NOT NULL,
       label      TEXT,
       shared_at  INTEGER NOT NULL,
       updated_at INTEGER NOT NULL,
       visited_at INTEGER,
       PRIMARY KEY (owner_kind, owner_key, url))"

    ;; Folders a workflow stage registered for its session: the task's Plans
    ;; folder and its code folder(s).  They are not rendered as rows; `O' on
    ;; the dashboard opens them (agent-workflow.el).
    "CREATE TABLE IF NOT EXISTS registered_folders (
       owner_kind  TEXT    NOT NULL,
       owner_key   TEXT    NOT NULL,
       folder_kind TEXT    NOT NULL,
       path        TEXT    NOT NULL,
       shared_at   INTEGER NOT NULL,
       PRIMARY KEY (owner_kind, owner_key, folder_kind, path))")
  "Statements that bring an empty or existing database up to date.
Schema migrations are handled by `rsr/agent-sessions--db-migrate'.")

(defun rsr/agent-sessions--db-migrate (db)
  "Migrate existing tables in DB after the additive schema is installed."
  (when (< (string-to-number (or (caar (sqlite-select db
                                                "SELECT value FROM meta WHERE key = 'schema_version'"))
                                 "0")) 2)
    (sqlite-execute db "CREATE TABLE shared_links_v2 (
       owner_kind TEXT NOT NULL, owner_key TEXT NOT NULL,
       link_kind TEXT NOT NULL, url TEXT NOT NULL, label TEXT,
       shared_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
       visited_at INTEGER, PRIMARY KEY (owner_kind, owner_key, url))")
    (sqlite-execute db "INSERT INTO shared_links_v2 SELECT * FROM shared_links")
    ;; Existing manual-order keys were link kinds.  Each kind had one URL.
    (sqlite-execute db "UPDATE order_entries SET member = (
       SELECT url FROM shared_links
        WHERE owner_key = order_entries.scope_repo
          AND link_kind = order_entries.member)
       WHERE kind = 'links' AND EXISTS (
       SELECT 1 FROM shared_links
        WHERE owner_key = order_entries.scope_repo
          AND link_kind = order_entries.member)")
    (sqlite-execute db "DROP TABLE shared_links")
    (sqlite-execute db "ALTER TABLE shared_links_v2 RENAME TO shared_links")
    (sqlite-execute db "UPDATE meta SET value = '2' WHERE key = 'schema_version'")
    (when (boundp 'rsr/agent-sessions--order)
      (setq rsr/agent-sessions--order nil)))
  (when (< (string-to-number (or (caar (sqlite-select db
                                                "SELECT value FROM meta WHERE key = 'schema_version'"))
                                 "0")) 3)
    (sqlite-execute db "CREATE TABLE folders_v3 (
       id INTEGER PRIMARY KEY, repo TEXT NOT NULL,
       name TEXT NOT NULL COLLATE NOCASE, UNIQUE (repo, name))")
    ;; A folder used in more than one repo becomes one folder in each repo.
    ;; The session log records the canonical repo root for durable sessions.
    (sqlite-execute db "INSERT OR IGNORE INTO folders_v3 (repo, name)
       SELECT repos.repo, f.name FROM folders f CROSS JOIN (
         SELECT DISTINCT s.repo FROM session_folders sf
         JOIN sessions s ON s.agent_sid = sf.agent_sid
         WHERE s.repo IS NOT NULL AND s.repo != '') repos")
    ;; Keep unmatched and empty legacy folders available for assignment when
    ;; a session next appears, rather than silently dropping their names.
    (sqlite-execute db "INSERT OR IGNORE INTO folders_v3 (repo, name)
       SELECT '', name FROM folders")
    (sqlite-execute db "UPDATE session_folders SET folder_id = (
       SELECT f3.id FROM folders_v3 f3
       JOIN folders old ON old.name = f3.name COLLATE NOCASE
       WHERE old.id = session_folders.folder_id
         AND f3.repo = COALESCE((SELECT repo FROM sessions
             WHERE agent_sid = session_folders.agent_sid
               AND repo IS NOT NULL AND repo != ''
             ORDER BY id DESC LIMIT 1), ''))")
    (sqlite-execute db "DROP TABLE folders")
    (sqlite-execute db "ALTER TABLE folders_v3 RENAME TO folders")
    (sqlite-execute db "UPDATE meta SET value = '3' WHERE key = 'schema_version'")
    (when (boundp 'rsr/agent-sessions--folders-loaded-p)
      (setq rsr/agent-sessions--folders-loaded-p nil))))

(defun rsr/agent-sessions--now () (truncate (float-time)))

(defun rsr/agent-sessions--db ()
  "Return the open database handle, creating the file on first use.
Opening also reaps (see `rsr/agent-sessions--db-reap'), which is why every
caller goes through here rather than touching `rsr/agent-sessions--db'."
  (if (sqlitep rsr/agent-sessions--db)
      rsr/agent-sessions--db
    (let ((db (sqlite-open rsr/agent-sessions-db-file)))
      ;; WAL so a second Emacs reading the file can't block this one; the
      ;; timeout so that if one does write, we wait rather than signalling.
      (sqlite-execute db "PRAGMA journal_mode=WAL")
      (sqlite-execute db "PRAGMA busy_timeout=3000")
      (with-sqlite-transaction db
        (dolist (stmt rsr/agent-sessions--db-schema)
          (sqlite-execute db stmt))
        (sqlite-execute db "INSERT OR IGNORE INTO meta VALUES ('schema_version', ?)"
                        (list (number-to-string rsr/agent-sessions--schema-version)))
        (rsr/agent-sessions--db-migrate db))
      (setq rsr/agent-sessions--db db)
      (rsr/agent-sessions--db-reap db)
      db)))

;; Re-run the schema against an already-open handle, so *loading* this file
;; picks up a schema addition.  `--db' migrates only when it opens the file,
;; and the handle is cached for the life of the Emacs — so without this the
;; documented way to develop this package (reload into the running server)
;; leaves the new code querying a table the old connection never created,
;; which is a flood of "no such table" rather than a clean failure.  Every
;; statement is `IF NOT EXISTS', so re-running them costs nothing.
(when (sqlitep rsr/agent-sessions--db)
  (with-sqlite-transaction rsr/agent-sessions--db
    (dolist (stmt rsr/agent-sessions--db-schema)
      (sqlite-execute rsr/agent-sessions--db stmt))
    (rsr/agent-sessions--db-migrate rsr/agent-sessions--db)))

(defun rsr/agent-sessions--meta-get (db key)
  (caar (sqlite-select db "SELECT value FROM meta WHERE key = ?" (list key))))

(defun rsr/agent-sessions--meta-set (db key value)
  (sqlite-execute db "INSERT INTO meta VALUES (?, ?)
                      ON CONFLICT(key) DO UPDATE SET value = excluded.value"
                  (list key (format "%s" value))))

(defun rsr/agent-sessions--emacs-alive-p (emacs-sid)
  "Non-nil when the Emacs that minted terminal id EMACS-SID is still running.
Terminal ids are \"PID-COUNTER\", so the pid is read off the front.  A live
process with that pid counts only if it is an Emacs, which keeps a reused pid
from shielding a dead Emacs's rows forever."
  (let ((pid (string-to-number emacs-sid)))
    (or (= pid (emacs-pid))
        (let ((comm (alist-get 'comm (and (> pid 0)
                                          (process-attributes pid)))))
          (and comm (string-match-p "emacs" (downcase comm)))))))

(defun rsr/agent-sessions--db-reap (db)
  "Close session rows that a previous Emacs left open by dying.
This is the whole crash-detection scheme: a row still marked open belongs to
an Emacs that never ran its `kill-emacs-hook' — unless that Emacs is still
running.  Rows whose Emacs is alive are left alone, because any second Emacs
that opens this file (a batch test run, most of all) would otherwise close a
live Emacs's sessions as crashed.  Its terminals never reopen a closed row,
so those sessions would drop out of the log for good: restore-previous would
miss them, and killing them later could not be recorded.  The heartbeat in
`meta' dates the death; without one we fall back to when the session opened."
  (let ((seen (rsr/agent-sessions--meta-get db "last_seen")))
    (dolist (row (sqlite-select db "SELECT DISTINCT emacs_sid FROM sessions
                                     WHERE closed_at IS NULL"))
      (unless (rsr/agent-sessions--emacs-alive-p (car row))
        (sqlite-execute db
                        "UPDATE sessions
                            SET closed_at = COALESCE(?, opened_at),
                                close_reason = 'crash'
                          WHERE closed_at IS NULL AND emacs_sid = ?"
                        (list (and seen (string-to-number seen))
                              (car row)))))))

(defun rsr/agent-sessions--db-heartbeat ()
  "Record that Emacs was alive just now, so a crash can be dated.
Deliberately a no-op until the database has been opened for some other
reason — an Emacs with no agent sessions has nothing to date."
  (when (sqlitep rsr/agent-sessions--db)
    (rsr/agent-sessions--meta-set rsr/agent-sessions--db
                                 "last_seen" (rsr/agent-sessions--now))))

;;; Session log -------------------------------------------------------------
;;
;; A history of every agent session that has run, so one can be brought back
;; after it is gone: `R' for one you ended yourself, and
;; `rsr/agent-sessions-restore-previous' for the lot that went down with Emacs.
;;
;; This is the one thing here that records *observed session state* rather than
;; something the user chose, which the ephemerality rule in CLAUDE.md otherwise
;; forbids.  It earns the exception by never feeding the dashboard: rows still
;; come only from live buffers, so nothing here can make a dead session look
;; alive.  It is a record of what happened, including the dying.
;;
;; How a session's ending is classified, and why it can be:
;;
;;   killed      `kill-buffer-hook' fired — `k' in the dashboard, `C-x k' on
;;               the terminal, or the shell exiting under it.
;;   agent-exit  the agent reported `SessionEnd' but the terminal lives on.
;;   superseded  a different agent session id appeared in the same terminal,
;;               so the previous one had ended without us hearing.
;;   emacs-exit  `kill-emacs-hook' fired: Emacs quit with this still running.
;;   crash       no hook fired at all; found still-open at the next startup.
;;
;; The first three mean "you ended it" and are what `R' offers; the last two
;; mean "it was taken from you" and are what restore-previous offers.  Emacs
;; runs `kill-emacs-hook' but *not* `kill-buffer-hook' when it exits, and that
;; asymmetry is the only reason the two can be told apart at all.

(defvar-local rsr/agent-session--log-row nil
  "Row id in the `sessions' table for this terminal's current agent session.
On the buffer rather than looked up, because a terminal can run several agent
sessions in turn and each gets its own row.")

(defvar-local rsr/agent-session--log-state nil
  "Last (AGENT-SID AGENT-TYPE TITLE) written for `rsr/agent-session--log-row'.
Compared before every write so a busy session touches the database once per
agent session instead of once per hook event.  The dashboard re-renders on
every event; the database must stay off that path.")

(defvar-local rsr/agent-session--log-ended-sid nil
  "Agent session id this terminal has already logged the end of.
Hook events have no delivery-order guarantee, so an informational event can
land after `SessionEnd'.  Without this, such a straggler would open a fresh
row and resurrect a session that has already finished.")

(defun rsr/agent-sessions--log-open (buf)
  "Insert a session-log row for BUF and remember its id on the buffer."
  (with-current-buffer buf
    (let* ((info (rsr/agent-sessions--buffer-repo-info buf))
           (db (rsr/agent-sessions--db)))
      (sqlite-execute
       db "INSERT INTO sessions (emacs_sid, worktree, repo, label, opened_at)
           VALUES (?, ?, ?, ?, ?)"
       (list rsr/agent-session-id
             (or (plist-get info :worktree-path)
                 (rsr/agent-sessions--canonical-path default-directory))
             (plist-get info :repo-root)
             (plist-get info :worktree)
             (rsr/agent-sessions--now)))
      (setq-local rsr/agent-session--log-state nil)
      (setq-local rsr/agent-session--log-row
                  (caar (sqlite-select db "SELECT last_insert_rowid()"))))))

(defun rsr/agent-sessions--log-close-row (row reason)
  "Close session-log ROW with REASON, if it is still open."
  (sqlite-execute (rsr/agent-sessions--db)
                  "UPDATE sessions SET closed_at = ?, close_reason = ?
                    WHERE id = ? AND closed_at IS NULL"
                  (list (rsr/agent-sessions--now) reason row)))

(defun rsr/agent-sessions--log-supersede (row)
  "Retire ROW, whose terminal has started a *different* agent session.
Usually that means the previous agent exited without us hearing, and the row
is closed.  The exception is the fork transient: at `SessionStart' a
`--fork-session' child reports its parent's id before minting its own, so ROW
may be a copy of a session still open in another terminal.  Such a row is an
artifact of the fork rather than a session that ever ran here, so it is
deleted instead of being offered by `R' as a resumable duplicate.

Note this reads the *log*, never the fork-detection state — see CLAUDE.md on
why a `sid == parent-sid' test must not go anywhere near that logic."
  (let ((db (rsr/agent-sessions--db)))
    (if (sqlite-select db
                       "SELECT 1 FROM sessions a
                         WHERE a.id = ?
                           AND EXISTS (SELECT 1 FROM sessions b
                                        WHERE b.agent_sid = a.agent_sid
                                          AND b.id <> a.id
                                          AND b.closed_at IS NULL)"
                       (list row))
        (sqlite-execute db "DELETE FROM sessions WHERE id = ?" (list row))
      (rsr/agent-sessions--log-close-row row "superseded"))))

(defun rsr/agent-sessions--log-update (buf agent-type agent-sid)
  "Bring BUF's session-log row in line with the hook event just processed."
  (with-current-buffer buf
    (let* ((title (or rsr/agent-session-title-override rsr/agent-session-title))
           (state (list agent-sid agent-type title)))
      (unless (or (equal state rsr/agent-session--log-state)
                  (and agent-sid
                       (equal agent-sid rsr/agent-session--log-ended-sid)))
        (let ((prev-sid (car rsr/agent-session--log-state)))
          (when (and rsr/agent-session--log-row prev-sid agent-sid
                     (not (equal prev-sid agent-sid)))
            (rsr/agent-sessions--log-supersede rsr/agent-session--log-row)
            (setq-local rsr/agent-session--log-row nil))
          (unless rsr/agent-session--log-row
            (rsr/agent-sessions--log-open buf))
          (sqlite-execute (rsr/agent-sessions--db)
                          "UPDATE sessions
                              SET agent_type = ?, agent_sid = ?, title = ?
                            WHERE id = ?"
                          (list agent-type agent-sid title
                                rsr/agent-session--log-row))
          (setq-local rsr/agent-session--log-state state))))))

(defun rsr/agent-sessions--log-title (buf)
  "Write BUF's current title to its open session-log row now.
The log otherwise learns a title only at the next hook event, so a session
renamed with `t' and closed before its agent reported again would be offered
by `R' under its old name.  Does nothing until a hook has given the row an
agent identity: an earlier rename is picked up by that first hook anyway."
  (with-current-buffer buf
    (when-let ((state rsr/agent-session--log-state))
      (rsr/agent-sessions--log-update buf (nth 1 state) (car state)))))

(defun rsr/agent-sessions--log-end (buf)
  "Close BUF's current log row: its agent reported that it is exiting.
The terminal itself lives on, and running an agent in it again opens a fresh
row rather than reviving this one."
  (with-current-buffer buf
    (when rsr/agent-session--log-row
      (rsr/agent-sessions--log-close-row rsr/agent-session--log-row "agent-exit")
      (setq-local rsr/agent-session--log-ended-sid
                  (car rsr/agent-session--log-state))
      (setq-local rsr/agent-session--log-row nil)
      (setq-local rsr/agent-session--log-state nil))))

(defun rsr/agent-sessions--log-close-buffer ()
  "Close the log rows of the terminal being killed, from `kill-buffer-hook'.
Covers both `k' in the dashboard (which is a plain `kill-buffer') and `C-x k'
on the terminal.  Does nothing when the database was never opened, which means
this Emacs logged no sessions and so has none to close."
  (when (and rsr/agent-session-id (sqlitep rsr/agent-sessions--db))
    (sqlite-execute rsr/agent-sessions--db
                    "UPDATE sessions SET closed_at = ?, close_reason = 'killed'
                      WHERE emacs_sid = ? AND closed_at IS NULL"
                    (list (rsr/agent-sessions--now) rsr/agent-session-id))))

(defun rsr/agent-sessions--log-close-all ()
  "Mark every still-open session as ended by Emacs exiting.
Runs from `kill-emacs-hook'.  Also stamps the heartbeat, so that if this Emacs
is *killed* mid-exit the reap still has a recent time to date the crash from."
  (when (sqlitep rsr/agent-sessions--db)
    (rsr/agent-sessions--db-heartbeat)
    (sqlite-execute rsr/agent-sessions--db
                    "UPDATE sessions
                        SET closed_at = ?, close_reason = 'emacs-exit'
                      WHERE closed_at IS NULL"
                    (list (rsr/agent-sessions--now)))))

;;; Manual order ------------------------------------------------------------
;;
;; `M-n' / `M-p' nudge the thing at point within its group, overriding the
;; automatic order of `--build-tree' for that group only.

(defvar rsr/agent-sessions--order nil
  "Hash table SCOPE -> ordered list of item keys, or nil before first load.
One scope per group that can be reordered: the repo list, each repo's
folders, and each folder's sessions.  A scope is a list — (\"folders\"
REPO-KEY) and friends — rather than a joined string, so no separator character
can ever appear inside a path component and blur two scopes together.

Item keys are stable identities rather than display labels, which change with
a branch checkout: a canonical repo root, a canonical worktree path, and — for
a session — its buffer name, the only session-level identity that can outlive
a restart.  Backed by the `order_entries' table.")

(defconst rsr/agent-sessions--repos-scope '("repos"))

(defun rsr/agent-sessions--sessions-scope (repo-key worktree-key)
  (list "sessions" repo-key worktree-key))

(defun rsr/agent-sessions--folders-scope (repo-key)
  (list "folders" repo-key))

(defun rsr/agent-sessions--folder-sessions-scope (repo-key folder-id)
  (list "folder-sessions" repo-key (format "%s" (or folder-id "none"))))

(defun rsr/agent-sessions--folder-key (folder)
  (format "%s" (or (plist-get folder :id) "none")))

(defun rsr/agent-sessions--repo-key (repo)
  "Manual-order key for REPO: its canonical root, else its display name."
  (or (rsr/agent-sessions--canonical-path (plist-get repo :root))
      (plist-get repo :name)
      "?"))

(defun rsr/agent-sessions--order-scope-row (scope)
  "Return (KIND SCOPE-REPO SCOPE-WORKTREE) for SCOPE, for use as query values.
Absent scope components become the empty string, never NULL — see the
`order_entries' schema for why."
  (list (car scope) (or (nth 1 scope) "") (or (nth 2 scope) "")))

(defun rsr/agent-sessions--order-table ()
  "Return the manual-order table, loading it from the database once.
An empty table just means the user hasn't reordered anything."
  (or rsr/agent-sessions--order
      (setq rsr/agent-sessions--order
            (let ((table (make-hash-table :test 'equal)))
              (pcase-dolist (`(,kind ,repo ,wt ,member)
                             (sqlite-select
                              (rsr/agent-sessions--db)
                              "SELECT kind, scope_repo, scope_worktree, member
                                 FROM order_entries ORDER BY position"))
                (let ((scope (cond ((string-empty-p repo) (list kind))
                                   ((string-empty-p wt) (list kind repo))
                                   (t (list kind repo wt)))))
                  (puthash scope
                           (append (gethash scope table) (list member))
                           table)))
              table))))

(defun rsr/agent-sessions--order-write-group (scope old new)
  "Persist NEW as SCOPE's member order, writing only the rows that moved.
`M-n' / `M-p' transpose one item with its neighbour, and
`rsr/agent-sessions--merge-order' turns that into a NEW list differing from OLD
in exactly two slots — so this normally issues exactly two UPDATEs no matter
how large the group is, and touches no other group at all.

A member NEW has but OLD doesn't is one being placed for the first time (it
had been keeping the automatic order), and is inserted at its new slot; one
OLD has but NEW doesn't is gone and is deleted."
  (let ((row (rsr/agent-sessions--order-scope-row scope))
        (db (rsr/agent-sessions--db))
        (i 0))
    (with-sqlite-transaction db
      (dolist (member new)
        (unless (eql (seq-position old member) i)
          (sqlite-execute
           db "INSERT INTO order_entries
                 (kind, scope_repo, scope_worktree, member, position)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(kind, scope_repo, scope_worktree, member)
               DO UPDATE SET position = excluded.position"
           (append row (list member i))))
        (setq i (1+ i)))
      (dolist (member old)
        (unless (member member new)
          (sqlite-execute
           db "DELETE FROM order_entries
                WHERE kind = ? AND scope_repo = ? AND scope_worktree = ?
                  AND member = ?"
           (append row (list member))))))))

(defun rsr/agent-sessions--order-delete-group (scope)
  "Forget SCOPE's manual order entirely."
  (sqlite-execute (rsr/agent-sessions--db)
                  "DELETE FROM order_entries
                    WHERE kind = ? AND scope_repo = ? AND scope_worktree = ?"
                  (rsr/agent-sessions--order-scope-row scope)))

(defun rsr/agent-sessions--order-delete-all ()
  "Forget every group's manual order."
  (sqlite-execute (rsr/agent-sessions--db) "DELETE FROM order_entries"))

(defun rsr/agent-sessions--apply-manual-order (scope key-fn items)
  "Return ITEMS reordered to match the manual order recorded for SCOPE.
KEY-FN maps an item to its manual-order key.  Items with no recorded key keep
their incoming (automatic) order and follow the ones that have, so a session
or worktree that appears after a reorder lands at the end of its group rather
than displacing anything the user placed deliberately."
  (let ((order (gethash scope (rsr/agent-sessions--order-table))))
    (if (null order)
        items
      (let (ranked rest)
        (dolist (item items)
          (let ((pos (seq-position order (funcall key-fn item))))
            (if pos (push (cons pos item) ranked) (push item rest))))
        (append (mapcar #'cdr (sort (nreverse ranked)
                                    (lambda (a b) (< (car a) (car b)))))
                (nreverse rest))))))

;;; Notes -------------------------------------------------------------------
;;
;; `e' attaches a free-form, multi-line note to the repo, worktree, or session
;; at point; it renders under that thing's heading.  Persisted for the same
;; reason as the manual order: it is something the user wrote, not session
;; state, so it has to outlive both the session and Emacs.

(defvar rsr/agent-sessions--states nil
  "Hash of (KIND KEY) -> workflow state string, or nil before first use.
Loaded from `session_states' once and written through on change, like the
notes table: the render path reads it on every row and must never query the
database.")

(defvar rsr/agent-sessions--notes nil
  "Hash table KEY -> note string, or nil before the notes are first read.
A KEY is (\"repo\" REPO-KEY), (\"worktree\" WORKTREE-KEY) or (\"session\" ID),
reusing the stable identities of the manual order.  The type tag is not
decoration: a repo's *main* worktree has the same canonical path as the repo
itself, so an untagged key would make those two share one note.

For a session, ID is the agent's own session id when it has one — that
survives renaming the terminal buffer — and the terminal id otherwise, which is
all a plain terminal has to be identified by.  See
`rsr/agent-sessions--session-note-keys'.")

(defun rsr/agent-sessions--notes-table ()
  "Return the notes table, loading it from the database once."
  (or rsr/agent-sessions--notes
      (setq rsr/agent-sessions--notes
            (let ((table (make-hash-table :test 'equal)))
              (pcase-dolist (`(,kind ,key ,note)
                             (sqlite-select (rsr/agent-sessions--db)
                                            "SELECT kind, key, note FROM notes"))
                (puthash (list kind key) note table))
              table))))

(defun rsr/agent-sessions--repo-note-key (repo)
  "Note key for REPO, a plist with :root/:name (a repo section's value)."
  (list "repo" (rsr/agent-sessions--repo-key repo)))

(defun rsr/agent-sessions--session-note-keys (session)
  "Note keys to try for SESSION, most durable identity first.
An agent session is keyed by the agent's own session id, so renaming its
terminal buffer keeps the note; a plain terminal has no such id and falls back
to its terminal id, or its buffer name when it has neither.  Not the buffer
name first: every child of one skill reuses a name like `implement-plan-tmux',
so a name key collects every such child's brief under each later one.  Both
keys are consulted when reading, so a note written on a bare terminal is still
found once `claude'/`codex' starts in it and the session gains an id — at which
point `rsr/agent-sessions--adopt-agent-id' moves it to the id key."
  (let* ((sid (plist-get session :agent-session-id))
         (buf (plist-get session :buffer))
         (tid (and (buffer-live-p buf)
                   (buffer-local-value 'rsr/agent-session-id buf)))
         (name (rsr/agent-sessions--session-buffer-name session)))
    (delq nil (list (and sid (list "session" sid))
                    (cond (tid (list "session" tid))
                          ((not (string-empty-p name)) (list "session" name)))))))

(defun rsr/agent-sessions--adopt-agent-id (session)
  "Move what SESSION's terminal key holds onto its agent session id key.
Called when a hook first reports the id, so a brief attached at spawn moves
with the session instead of waiting for the next share to collapse it."
  (let ((keys (rsr/agent-sessions--session-note-keys session)))
    (when (cdr keys)
      (rsr/agent-sessions--files-collapse keys)
      (rsr/agent-sessions--links-collapse keys)
      (rsr/agent-sessions--shared-paths-invalidate)
      (let ((note (cdr (rsr/agent-sessions--note-find keys)))
            (state (rsr/agent-sessions--session-state session)))
        (when note (rsr/agent-sessions--note-set keys note))
        (when state (rsr/agent-sessions--state-set keys state))))))

;;; Folders -----------------------------------------------------------------
;; Folder names and durable session assignments are user choices.  A plain
;; terminal keeps its choice on the buffer until an agent supplies an id.

(defvar rsr/agent-sessions--folders-loaded-p nil)
(defvar rsr/agent-sessions--folders-cache-version nil
  "Schema version used to populate the in-memory folder cache.")
(defvar rsr/agent-sessions--folders nil
  "List of (:id ID :repo ROOT :name NAME) folders, loaded once from SQLite.")
(defvar rsr/agent-sessions--folder-assignments nil
  "Hash of agent session id to folder id, loaded with the folder list.")

(defun rsr/agent-sessions--load-folders ()
  "Load folder choices once; subsequent dashboard renders use memory only."
  ;; Reloading this module does not reset `defvar' values in a running Emacs.
  ;; A pre-migration cache has folders without :repo and ids that no longer
  ;; match SQLite after the global-to-repo migration.
  (when (and rsr/agent-sessions--folders-loaded-p
             (or (not (eql rsr/agent-sessions--folders-cache-version
                           rsr/agent-sessions--schema-version))
                 (seq-some (lambda (folder) (not (plist-member folder :repo)))
                           rsr/agent-sessions--folders)))
    (setq rsr/agent-sessions--folders-loaded-p nil))
  (unless rsr/agent-sessions--folders-loaded-p
    (let ((db (rsr/agent-sessions--db))
          (assignments (make-hash-table :test 'equal)))
      (setq rsr/agent-sessions--folders
            (mapcar (lambda (row) (list :id (car row) :repo (cadr row)
                                        :name (nth 2 row)))
                    (sqlite-select db "SELECT id, repo, name FROM folders ORDER BY name COLLATE NOCASE")))
      (pcase-dolist (`(,sid ,folder-id)
                     (sqlite-select db "SELECT agent_sid, folder_id FROM session_folders"))
        (puthash sid folder-id assignments))
      (setq rsr/agent-sessions--folder-assignments assignments
            rsr/agent-sessions--folders-loaded-p t
            rsr/agent-sessions--folders-cache-version
            rsr/agent-sessions--schema-version))))

(defun rsr/agent-sessions--folder (id)
  "Return the saved folder with ID, or nil."
  (rsr/agent-sessions--load-folders)
  (seq-find (lambda (folder) (equal id (plist-get folder :id)))
            rsr/agent-sessions--folders))

(defun rsr/agent-sessions--session-repo (session)
  "Return the canonical repo root for SESSION, or nil outside a repo."
  (rsr/agent-sessions--canonical-path
   (or (plist-get session :repo-root)
       (plist-get session :worktree-path)
       (let ((buf (plist-get session :buffer)))
         (and (buffer-live-p buf)
              (buffer-local-value 'default-directory buf))))))

(defun rsr/agent-sessions--folders-for-repo (repo)
  "Return folders belonging to canonical REPO."
  (rsr/agent-sessions--load-folders)
  (seq-filter (lambda (folder) (equal repo (plist-get folder :repo)))
              rsr/agent-sessions--folders))

(defun rsr/agent-sessions--folder-session-id (session)
  "Return SESSION's durable id, including an in-progress resume."
  (or (plist-get session :agent-session-id)
      (let ((buf (plist-get session :buffer)))
        (and (buffer-live-p buf)
             (buffer-local-value 'rsr/agent-session--resuming-session-id buf)))))

(defun rsr/agent-sessions--folder-for-session (session)
  "Return the folder id assigned to SESSION, if any."
  (rsr/agent-sessions--load-folders)
  (let* ((buf (plist-get session :buffer))
         (sid (rsr/agent-sessions--folder-session-id session))
         (saved (and sid (gethash sid rsr/agent-sessions--folder-assignments))))
    (or (and (equal (plist-get (rsr/agent-sessions--folder saved) :repo)
                    (rsr/agent-sessions--session-repo session))
             saved)
        (and (buffer-live-p buf)
             (equal (plist-get (rsr/agent-sessions--folder
                                (buffer-local-value 'rsr/agent-session--folder-id buf))
                               :repo)
                    (rsr/agent-sessions--session-repo session))
             (buffer-local-value 'rsr/agent-session--folder-id buf)))))

(defun rsr/agent-sessions--folder-set (session folder-id)
  "Assign SESSION to FOLDER-ID, or clear its assignment when nil."
  (rsr/agent-sessions--load-folders)
  (when (and folder-id
             (not (equal (plist-get (rsr/agent-sessions--folder folder-id) :repo)
                         (rsr/agent-sessions--session-repo session))))
    (user-error "Folder does not belong to this repo"))
  (let ((sid (rsr/agent-sessions--folder-session-id session))
        (buf (plist-get session :buffer)))
    (when sid
      (if folder-id
          (progn
            (sqlite-execute
             (rsr/agent-sessions--db)
             "INSERT INTO session_folders (agent_sid, folder_id) VALUES (?, ?)
                ON CONFLICT(agent_sid) DO UPDATE SET folder_id = excluded.folder_id"
             (list sid folder-id))
            (puthash sid folder-id rsr/agent-sessions--folder-assignments))
        (sqlite-execute (rsr/agent-sessions--db)
                        "DELETE FROM session_folders WHERE agent_sid = ?" (list sid))
        (remhash sid rsr/agent-sessions--folder-assignments)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq-local rsr/agent-session--folder-id folder-id)))))

(defun rsr/agent-sessions--folder-hydrate (buf agent-sid)
  "Carry BUF's folder choice to AGENT-SID, or restore its saved folder."
  (when (and agent-sid (buffer-live-p buf))
    (rsr/agent-sessions--load-folders)
    (let* ((session (gethash (buffer-local-value 'rsr/agent-session-id buf)
                             rsr/agent-sessions))
           (repo (and session (rsr/agent-sessions--session-repo session)))
           (saved (gethash agent-sid rsr/agent-sessions--folder-assignments))
           (local (buffer-local-value 'rsr/agent-session--folder-id buf))
           (folder (rsr/agent-sessions--folder saved)))
      (cond
       ((and saved (equal (plist-get folder :repo) repo))
        (with-current-buffer buf
          (setq-local rsr/agent-session--folder-id saved)))
       ;; A legacy global assignment without a matching log row has no repo
       ;; until its agent appears.  Claim it for this repo at that point.
       ((and folder repo (equal (plist-get folder :repo) ""))
        (let ((target
               (or (seq-find (lambda (item)
                               (string-equal-ignore-case
                                (plist-get item :name) (plist-get folder :name)))
                             (rsr/agent-sessions--folders-for-repo repo))
                   (rsr/agent-sessions--folder-create
                    (plist-get folder :name) repo))))
          (rsr/agent-sessions--folder-set
           (append (list :buffer buf :agent-session-id agent-sid)
                   (list :repo-root repo))
           (plist-get target :id))))
       ((and local session
             (equal (plist-get (rsr/agent-sessions--folder local) :repo) repo))
        (rsr/agent-sessions--folder-set
         (append (list :buffer buf :agent-session-id agent-sid)
                 (list :repo-root repo))
         local))))))

(defun rsr/agent-sessions--folder-inherit (buf branched-from repo)
  "Put BUF in the folder of the session BRANCHED-FROM names, within REPO.
BRANCHED-FROM is the (PARENT-SID . LABEL) a fork records.  Only the
terminal's own choice is set, and only when it has none, so
`rsr/agent-sessions--folder-hydrate' persists it under the child's id.  Called
once, on a terminal's first hook, so a child the user later moves out of the
folder is not put back."
  (when (and (buffer-live-p buf) (car branched-from)
             (not (buffer-local-value 'rsr/agent-session--folder-id buf)))
    (rsr/agent-sessions--load-folders)
    (let ((parent-folder (gethash (car branched-from)
                                  rsr/agent-sessions--folder-assignments)))
      (when (and parent-folder
                 (equal (plist-get (rsr/agent-sessions--folder parent-folder)
                                   :repo)
                        repo))
        (with-current-buffer buf
          (setq-local rsr/agent-session--folder-id parent-folder))))))

(defun rsr/agent-sessions--folder-create (name repo)
  "Create or find a folder named NAME in canonical REPO."
  (rsr/agent-sessions--load-folders)
  (setq name (string-trim name))
  (when (or (string-empty-p name)
            (string-equal-ignore-case name "No folder"))
    (user-error "Choose a different folder name"))
  (unless repo (user-error "Select a repo to create a folder"))
  (let ((db (rsr/agent-sessions--db)))
    ;; SQLite is authoritative if another Emacs has created this folder since
    ;; we loaded our cache.  Return its existing id in that case.
    (sqlite-execute db "INSERT INTO folders (repo, name) VALUES (?, ?)
                        ON CONFLICT(repo, name) DO NOTHING"
                    (list repo name))
    (pcase-let* ((`(,id ,saved-name)
                  (car (sqlite-select db
                       "SELECT id, name FROM folders
                         WHERE repo = ? AND name = ? COLLATE NOCASE"
                       (list repo name))))
                 (folder (or (rsr/agent-sessions--folder id)
                             (list :id id :repo repo :name saved-name))))
      (plist-put folder :name saved-name)
      (unless (member folder rsr/agent-sessions--folders)
        (push folder rsr/agent-sessions--folders))
      folder)))

(defun rsr/agent-sessions--folder-rename (folder name)
  "Rename FOLDER to NAME."
  (setq name (string-trim name))
  (when (or (string-empty-p name)
            (string-equal-ignore-case name "No folder"))
    (user-error "Choose a different folder name"))
  (when (seq-find (lambda (other)
                    (and (not (equal (plist-get other :id) (plist-get folder :id)))
                         (equal (plist-get other :repo) (plist-get folder :repo))
                         (string-equal-ignore-case name (plist-get other :name))))
                  rsr/agent-sessions--folders)
    (user-error "Folder already exists: %s" name))
  (sqlite-execute (rsr/agent-sessions--db)
                  "UPDATE folders SET name = ? WHERE id = ?"
                  (list name (plist-get folder :id)))
  (plist-put folder :name name))

(defun rsr/agent-sessions--folder-delete (folder)
  "Delete FOLDER and move its sessions to No folder."
  (let ((id (plist-get folder :id))
        (db (rsr/agent-sessions--db)))
    (with-sqlite-transaction db
      (sqlite-execute db "DELETE FROM session_folders WHERE folder_id = ?" (list id))
      (sqlite-execute db "DELETE FROM folders WHERE id = ?" (list id)))
    (let (removed)
      (maphash (lambda (sid folder-id)
                 (when (equal folder-id id) (push sid removed)))
               rsr/agent-sessions--folder-assignments)
      (dolist (sid removed)
        (remhash sid rsr/agent-sessions--folder-assignments)))
    (setq rsr/agent-sessions--folders (delq folder rsr/agent-sessions--folders))
    (dolist (buf (buffer-list))
      (when (equal (buffer-local-value 'rsr/agent-session--folder-id buf) id)
        (with-current-buffer buf
          (setq-local rsr/agent-session--folder-id nil))))))

(defun rsr/agent-sessions--note-find (keys)
  "Return (KEY . NOTE) for the first of KEYS carrying a note, or nil."
  (let ((table (rsr/agent-sessions--notes-table)))
    (seq-some (lambda (key)
                (let ((note (gethash key table)))
                  (and (stringp note) (not (string-empty-p note))
                       (cons key note))))
              keys)))

(defun rsr/agent-sessions--note-set (keys note)
  "Store NOTE under the first of KEYS and save; an empty NOTE removes it.
Notes under the remaining (less durable) KEYS are dropped, so a session that
gains an agent session id ends up with its note under that id alone rather than
one note per identity it has had."
  (let ((table (rsr/agent-sessions--notes-table))
        (db (rsr/agent-sessions--db)))
    (with-sqlite-transaction db
      (dolist (key (cdr keys))
        (remhash key table)
        (sqlite-execute db "DELETE FROM notes WHERE kind = ? AND key = ?" key))
      (if (and note (not (string-empty-p note)))
          (progn
            (puthash (car keys) note table)
            (sqlite-execute db "INSERT INTO notes VALUES (?, ?, ?, ?)
                                ON CONFLICT(kind, key) DO UPDATE
                                  SET note = excluded.note,
                                      updated_at = excluded.updated_at"
                            (append (car keys)
                                    (list note (rsr/agent-sessions--now)))))
        (remhash (car keys) table)
        (sqlite-execute db "DELETE FROM notes WHERE kind = ? AND key = ?"
                        (car keys))))))

(defcustom rsr/agent-sessions-states
  '("TODO" "PLANNING" "PLAN-REVIEW" "IMPLEMENTING" "IMPL-REVIEW" "PR-OPEN"
    "AUTOFIX" "REVIEW" "DONE" "BLOCKED" "LEARN")
  "Workflow states a session can be in, in the order `t' cycles them.
`t' moves a session to the next one and off the end back to no state, so the
order is the only thing that decides how many presses a given state costs.  No
state is a state — a session nobody has triaged should not have to claim to be
anything.

PLANNING through DONE follow the phases of the issue-workflow skill, in its
order, so an agent running it can report where it is with `emacs-share
state'.  The *-REVIEW states and PR-OPEN are its gates: the agent has stopped
and the next move is the user's."
  :type '(repeat string))

(defface rsr/agent-session-state-todo '((t :inherit org-todo))
  "Face for the TODO state, borrowed from Org so it matches the agenda.")

(defface rsr/agent-session-state-done '((t :inherit org-done))
  "Face for the DONE state, borrowed from Org so it matches the agenda.")

(defface rsr/agent-session-state-review '((t :inherit bold :foreground "#7aa2f7"))
  "Face for the REVIEW state: waiting on someone else to look.")

(defface rsr/agent-session-state-plan-review
  '((t :inherit rsr/agent-session-state-review))
  "Face for the PLAN-REVIEW state: the plan is waiting on the user.")

(defface rsr/agent-session-state-impl-review
  '((t :inherit rsr/agent-session-state-review))
  "Face for the IMPL-REVIEW state: the implementation is waiting on the user.")

(defface rsr/agent-session-state-pr-open '((t :inherit bold :foreground "#73daca"))
  "Face for the PR-OPEN state: the PR is up and waiting on the user.")

;; The states in which the agent holds the work are plain; bold is kept for the
;; ones where the next move is the user's, so it reads as a call to act.
(defface rsr/agent-session-state-planning '((t :foreground "#7dcfff"))
  "Face for the PLANNING state.")

(defface rsr/agent-session-state-implementing '((t :foreground "#9ece6a"))
  "Face for the IMPLEMENTING state.")

(defface rsr/agent-session-state-autofix '((t :foreground "#ff9e64"))
  "Face for the AUTOFIX state.")

(defface rsr/agent-session-state-blocked '((t :inherit bold :foreground "#f7768e"))
  "Face for the BLOCKED state: nothing moves until the user unblocks it.")

(defface rsr/agent-session-state-learn '((t :inherit bold :foreground "#bb9af7"))
  "Face for the LEARN state: finished, but there is something here to take away.")

(defun rsr/agent-sessions--state-face (state)
  "Face for STATE, or nil for one this package has no opinion about.
Looked up by name rather than by position in `rsr/agent-sessions-states' so a
reordered or extended list keeps its colours; a state added by the user simply
renders unstyled until they define `rsr/agent-session-state-<name>'."
  (let ((face (intern (format "rsr/agent-session-state-%s" (downcase state)))))
    (and (facep face) face)))

(defun rsr/agent-sessions--states-table ()
  "Return the workflow-state table, loading it from the database once."
  (or rsr/agent-sessions--states
      (setq rsr/agent-sessions--states
            (let ((table (make-hash-table :test 'equal)))
              (pcase-dolist (`(,kind ,key ,state)
                             (sqlite-select (rsr/agent-sessions--db)
                                            "SELECT kind, key, state FROM session_states"))
                (puthash (list kind key) state table))
              table))))

(defun rsr/agent-sessions--session-state (session)
  "The workflow state recorded for SESSION, or nil.
Every identity the session has held is consulted, like a note, so a state set
on a bare terminal is still shown once `claude'/`codex' starts in it."
  (let ((table (rsr/agent-sessions--states-table)))
    (seq-some (lambda (key) (gethash key table))
              (rsr/agent-sessions--session-note-keys session))))

(defun rsr/agent-sessions--state-set (keys state)
  "Record STATE under the first of KEYS; a nil or empty STATE clears it.
Collapses the less durable KEYS onto the first exactly as `rsr/agent-sessions--
note-set' does, so a session that gains an agent session id carries one state
under that id rather than one per identity it has had."
  (let ((table (rsr/agent-sessions--states-table))
        (db (rsr/agent-sessions--db)))
    (with-sqlite-transaction db
      (dolist (key (cdr keys))
        (remhash key table)
        (sqlite-execute db "DELETE FROM session_states WHERE kind = ? AND key = ?" key))
      (if (and state (not (string-empty-p state)))
          (progn
            (puthash (car keys) state table)
            (sqlite-execute db "INSERT INTO session_states VALUES (?, ?, ?, ?)
                                ON CONFLICT(kind, key) DO UPDATE
                                  SET state      = excluded.state,
                                      updated_at = excluded.updated_at"
                            (append (car keys)
                                    (list state (rsr/agent-sessions--now)))))
        (remhash (car keys) table)
        (sqlite-execute db "DELETE FROM session_states WHERE kind = ? AND key = ?"
                        (car keys))))))

(defun rsr/agent-sessions--next-state (state)
  "The state after STATE in `rsr/agent-sessions-states', wrapping through nil."
  (let ((states rsr/agent-sessions-states))
    (cond ((null state) (car states))
          ((member state states)
           ;; Off the end is nil rather than the first state: the cycle has to
           ;; pass through "no state" or there would be no way back to it.
           (nth (1+ (seq-position states state)) states))
          (t (car states)))))

;;;###autoload
(defun rsr/agent-sessions-share-state (session-id state &optional
                                                 agent-session-id)
  "Set the workflow state of the session in terminal SESSION-ID to STATE.
The `emacs-share state' entry point: an agent reports where it is, writing the
same per-session state `t' sets, so whichever of the two wrote last wins.
STATE must be one of `rsr/agent-sessions-states'; an empty STATE clears it.
SESSION-ID and AGENT-SESSION-ID resolve as in `rsr/agent-sessions-share-link'.
Returns a printable status string, since emacsclient's value is the agent's
only channel back."
  (let ((session (rsr/agent-sessions--session-for-share
                  session-id agent-session-id))
        (state (and state (not (string-empty-p state)) state)))
    (cond
     ((null session)
      (if (and agent-session-id (not (string-empty-p agent-session-id)))
          (format "No Emacs agent session registered for agent id %s"
                  agent-session-id)
        (format "No Emacs terminal registered for session id %s" session-id)))
     ((and state (not (member state rsr/agent-sessions-states)))
      (format "Unknown state `%s'; expected one of %s"
              state (string-join rsr/agent-sessions-states ", ")))
     (t
      (rsr/agent-sessions--state-set
       (rsr/agent-sessions--session-note-keys session) state)
      (rsr/agent-sessions--refresh-if-visible)
      (if state (format "State: %s" state) "State cleared")))))

(defface rsr/agent-session-note
  '((t :inherit font-lock-comment-face))
  "Face for a note attached to a repo, worktree, or session row.")

(defun rsr/agent-sessions--insert-note (keys indent)
  "Insert the note for KEYS, if any, as a section indented by INDENT.
The note's first line is the section heading and the rest its body, so TAB
collapses a long note to one line and expands it again.  Fold state survives
the dashboard's re-render because magit caches it per section identity, and a
note's identity is its key — not its position or text."
  (when-let ((found (rsr/agent-sessions--note-find keys)))
    (let ((lines (split-string (cdr found) "\n")))
      (magit-insert-section (rsr/agent-session-note (car found))
        (magit-insert-heading
          (rsr/agent-sessions--dress
           (concat indent
                   (let ((icon (rsr/agent-sessions--icon 'note)))
                     (if (string-empty-p icon) "· " icon))
                   (car lines))
           'rsr/agent-session-note))
        (dolist (line (cdr lines))
          (insert (propertize (concat indent "  " line "\n")
                              'font-lock-face 'rsr/agent-session-note)))))))

(defun rsr/agent-sessions--note-target-at-point ()
  "Return (KEYS . LABEL) for the note-bearing thing at point, or nil.
Point may be on a repo heading, a worktree heading or a session row — or inside
a note already rendered under one of those, which resolves to its parent so `e'
re-edits the note point is sitting in."
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'rsr/agent-session-note))
      (setq section (oref section parent)))
    (pcase (and section (oref section type))
      ('rsr/agent-session-repo
       (let ((value (oref section value)))
         (cons (list (rsr/agent-sessions--repo-note-key value))
               (or (plist-get value :name) "repo"))))
      ('rsr/agent-session-file
       (let ((path (oref section value)))
         (cons (list (rsr/agent-sessions--file-note-key path))
               (file-name-nondirectory (directory-file-name path)))))
      ('rsr/agent-session-link
       (when-let* ((row (rsr/agent-sessions--enclosing-section
                         'rsr/agent-session-row))
                   (session (rsr/agent-sessions--session-for-id
                             (oref row value)))
                   (link (seq-find
                          (lambda (candidate)
                            (equal (plist-get candidate :url)
                                   (oref section value)))
                          (rsr/agent-sessions--session-links session))))
         (cons (list (rsr/agent-sessions--link-note-key
                      (plist-get link :url)))
               (or (plist-get link :label) (plist-get link :url)))))
      ('rsr/agent-session-row
       (when-let* ((session (rsr/agent-sessions--session-for-id
                             (oref section value)))
                   ;; No id and no buffer name means nothing durable to hang a
                   ;; note on (a registry entry whose buffer is already gone).
                   (keys (rsr/agent-sessions--session-note-keys session)))
         (cons keys (rsr/agent-sessions--session-short-label session)))))))

(defun rsr/agent-sessions-note-newline ()
  "Insert a line break into the note being read in the minibuffer."
  (interactive)
  (insert "\n"))

(defvar rsr/agent-sessions-note-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map minibuffer-local-map)
    (define-key map (kbd "C-j") #'rsr/agent-sessions-note-newline)
    map)
  "Keymap used while reading a note with `rsr/agent-sessions-edit-note'.
Notes are multi-line, but `minibuffer-local-map' binds \\`C-j' to
`exit-minibuffer' just like \\`RET', so it has to be rebound here; \\`RET'
still accepts the note.")

(defun rsr/agent-sessions-edit-note (&optional remove)
  "Attach or edit a note on the repo, worktree, or session at point.
The note is free-form text shown under that thing's heading, foldable with TAB,
and persisted in `rsr/agent-sessions-db-file'.  Insert a line break with
\\<rsr/agent-sessions-note-minibuffer-map>\\[rsr/agent-sessions-note-newline] and
accept with \\[exit-minibuffer]; an empty note removes it.  With a prefix
argument (REMOVE), delete the note without prompting — emptying a many-line
note by hand is tedious, since \\[kill-line] only kills the line point is on."
  (interactive "P")
  (pcase (rsr/agent-sessions--note-target-at-point)
    (`(,keys . ,label)
     (let* ((existing (cdr (rsr/agent-sessions--note-find keys)))
            (note (if remove
                      ""
                    (string-trim
                     (read-from-minibuffer
                      (format "Note for %s (C-j for newline): " label)
                      existing rsr/agent-sessions-note-minibuffer-map)))))
       (rsr/agent-sessions--note-set keys note)
       (rsr/agent-sessions--refresh)
       (message (if (string-empty-p note)
                    "Note cleared for %s."
                  "Note saved for %s.")
                label)))
    (_ (message "Point is not on a repo, worktree, session, file, or link."))))

;;; Shared files ------------------------------------------------------------
;;
;; An agent that wants the user to read something runs `emacs-share file FILE
;; ["why"]' (`bin/emacs-share-file' remains a compatibility symlink); the
;; file then hangs under that agent's row in the dashboard, highlighted until
;; the user opens it.  It exists because a terminal is a bad inbox: "look at
;; /tmp/plan.md" scrolls away, and is only seen at all if you are already in
;; that buffer.
;;
;; This is persisted for the same reason notes and the manual order are — it is
;; something someone *chose* to put there, not observed session state — and it
;; obeys the same rules: loaded into a hash table once, written on change, and
;; never queried from the render path.
;;
;; Two design points worth keeping:
;;
;; - **A file is attached to the session's most durable identity, not to its
;;   terminal.**  It reuses `rsr/agent-sessions--session-note-keys' verbatim: the
;;   agent's own session id when it has one, the terminal id otherwise, reading
;;   both and collapsing onto the first once the agent id is known.  So renaming a terminal keeps
;;   its files, a file shared into a bare shell survives `claude' starting in
;;   it, and a session brought back with `R' comes back with its files.  The
;;   caller passes the *terminal* id (that is what the shell env has), and this
;;   layer resolves it — the same split the hook path makes.
;;
;; - **Re-sharing a path means "I changed it, look again", not "add it twice".**
;;   The row's `visited_at' is cleared so it lights up exactly as it did the
;;   first time, but its `shared_at' — and therefore its position — is left
;;   alone.  That follows the ordering rule the dashboard already lives by: a
;;   row may move when something meaningful changes, and a re-share is not that;
;;   a row jumping to the bottom of the list is the thing the user is trying to
;;   aim at moving out from under them.
;;
;; - **Every share snapshots the file before returning to the agent.**  The
;;   cache retains the two most recently submitted contents for that session
;;   and path, independent of Git.  This is deliberately done in the share
;;   path rather than when `D' is pressed: by then the live file may have been
;;   edited again, and would no longer be the version the agent handed over.

(defcustom rsr/agent-sessions-file-snapshot-directory
  (expand-file-name ".cache/agent-sessions-file-snapshots/"
                    user-emacs-directory)
  "Directory containing the latest two submitted versions of shared files."
  :type 'directory)

(defvar rsr/agent-sessions--shared-files nil
  "Hash table KEY -> list of shared-file plists, or nil before first load.
A KEY is (\"session\" ID), exactly as in `rsr/agent-sessions--notes'.  Each
plist is (:path P :label L :shared-at TS :updated-at TS :visited-at TS-or-nil);
`:visited-at' nil is what makes a row render highlighted.  Backed by the
`shared_files' table.")

(defvar rsr/agent-sessions--shared-paths nil
  "Hash set of `file-truename's of every shared file, or nil when it is stale.
Consulted by the focus hook on every buffer switch, so it has to be a set
lookup rather than a scan; `rsr/agent-sessions--shared-paths-invalidate' drops
it whenever the file table changes.")

(defun rsr/agent-sessions--shared-files-table ()
  "Return the shared-files table, loading it from the database once."
  (or rsr/agent-sessions--shared-files
      (setq rsr/agent-sessions--shared-files
            (let ((table (make-hash-table :test 'equal)))
              (pcase-dolist (`(,kind ,key ,path ,label ,shared ,updated ,visited)
                             (sqlite-select
                              (rsr/agent-sessions--db)
                              "SELECT kind, key, path, label, shared_at,
                                      updated_at, visited_at
                                 FROM shared_files ORDER BY shared_at, path"))
                (let ((k (list kind key)))
                  (puthash k
                           (append (gethash k table)
                                   (list (list :path path :label label
                                               :shared-at shared
                                               :updated-at updated
                                               :visited-at visited)))
                           table)))
              table))))

(defun rsr/agent-sessions--shared-paths-invalidate ()
  "Drop the cached truename set; it is rebuilt on the next lookup."
  (setq rsr/agent-sessions--shared-paths nil))

(defun rsr/agent-sessions--shared-path-p (truename)
  "Non-nil when TRUENAME is the true name of some shared file."
  (and truename
       (gethash truename
                (or rsr/agent-sessions--shared-paths
                    (setq rsr/agent-sessions--shared-paths
                          (let ((set (make-hash-table :test 'equal)))
                            (maphash
                             (lambda (_key files)
                               (dolist (f files)
                                 (puthash (file-truename (plist-get f :path))
                                          t set)))
                             (rsr/agent-sessions--shared-files-table))
                            set))))))

(defun rsr/agent-sessions--file-note-key (path)
  "Note key for the shared file at PATH.
Keyed on the path alone, not on path-plus-session: the note is about the file,
and the same file handed to two sessions is still one thing to say something
about."
  (list "file" path))

(defun rsr/agent-sessions--files-scope (session)
  "Manual-order scope for SESSION's shared files.
Packed into the existing two scope columns as (\"files\" SESSION-KEY) rather
than needing a third: `kind' already separates it from every other scope, and
adding a column would mean a real migration, which `CREATE TABLE IF NOT
EXISTS' cannot do.  SESSION-KEY is the same durable identity the files
themselves are stored under, so an arrangement survives a terminal rename."
  (list "files" (or (cadr (car (rsr/agent-sessions--session-note-keys session)))
                    "?")))

(defun rsr/agent-sessions--session-files (session)
  "Files shared with SESSION, in display order.
First-shared first, with any manual order (`M-n' / `M-p') applied on top.
Every identity the session has had is read, not just the current one, so a
file attached before `claude' started in the terminal is not invisible in the
window between that and the next write (which collapses them)."
  (let ((table (rsr/agent-sessions--shared-files-table))
        files)
    (dolist (key (rsr/agent-sessions--session-note-keys session))
      ;; `append' shares the tail of its last argument, and `sort' is
      ;; destructive — without the copy this would reorder the stored list.
      (setq files (append files (copy-sequence (gethash key table)))))
    (rsr/agent-sessions--apply-manual-order
     (rsr/agent-sessions--files-scope session)
     (lambda (f) (plist-get f :path))
     (sort files (lambda (a b) (< (plist-get a :shared-at)
                                  (plist-get b :shared-at)))))))

(defun rsr/agent-sessions--shared-file-write (key file)
  "Upsert FILE under KEY in the database."
  (sqlite-execute
   (rsr/agent-sessions--db)
   "INSERT INTO shared_files
      (kind, key, path, label, shared_at, updated_at, visited_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(kind, key, path) DO UPDATE
      SET label      = excluded.label,
          updated_at = excluded.updated_at,
          visited_at = excluded.visited_at"
   (append key (list (plist-get file :path)
                     (plist-get file :label)
                     (plist-get file :shared-at)
                     (plist-get file :updated-at)
                     (plist-get file :visited-at)))))

(defun rsr/agent-sessions--file-snapshot-row (keys path)
  "Return the first snapshot row for PATH owned by one of KEYS.
KEYS are ordered from most to least durable.  The result is a plist containing
`:key', `:previous-path', `:current-path', and `:updated-at'."
  (let ((db (rsr/agent-sessions--db)))
    (seq-some
     (lambda (key)
       (when-let ((row
                   (car (sqlite-select
                         db
                         "SELECT previous_path, current_path, updated_at
                            FROM shared_file_snapshots
                           WHERE kind = ? AND key = ? AND path = ?"
                         (append key (list path))))))
         (list :key key
               :previous-path (nth 0 row)
               :current-path (nth 1 row)
               :updated-at (nth 2 row))))
     keys)))

(defun rsr/agent-sessions--file-snapshots-collapse (keys)
  "Move snapshot rows stored under the less durable KEYS onto (car KEYS).
An existing row under the primary key wins, matching the shared-file collapse
rule.  Snapshot files themselves need not move because their paths are stored
in the database."
  (when-let ((primary (car keys)))
    (let ((db (rsr/agent-sessions--db)))
      (dolist (key (cdr keys))
        (sqlite-execute
         db
         "INSERT OR IGNORE INTO shared_file_snapshots
            (kind, key, path, previous_path, current_path, updated_at)
          SELECT ?, ?, path, previous_path, current_path, updated_at
            FROM shared_file_snapshots WHERE kind = ? AND key = ?"
         (append primary key))
        (sqlite-execute
         db "DELETE FROM shared_file_snapshots WHERE kind = ? AND key = ?"
         key)))))

(defun rsr/agent-sessions--file-snapshot-cache-directory (key path)
  "Return the private cache directory for the shared PATH owned by KEY."
  (expand-file-name
   (secure-hash 'sha256 (prin1-to-string (append key (list path))))
   rsr/agent-sessions-file-snapshot-directory))

(defun rsr/agent-sessions--snapshot-file (key path)
  "Save PATH as the current submitted version owned by KEY.
The formerly current copy becomes the previous copy.  Return the new snapshot
row plist.  A missing cache file is treated like a first share, since a cache
may be cleared independently of the database."
  (let* ((existing (rsr/agent-sessions--file-snapshot-row (list key) path))
         (old-current (plist-get existing :current-path))
         (directory (rsr/agent-sessions--file-snapshot-cache-directory key path))
         (basename (file-name-nondirectory path))
         (previous (expand-file-name (concat "previous--" basename) directory))
         (current (expand-file-name (concat "current--" basename) directory))
         incoming)
    (make-directory directory t)
    (set-file-modes directory #o700)
    (unwind-protect
        (progn
          ;; Copy the new contents before rotating the old pair.  If this
          ;; fails, the last successful submission remains intact.
          (setq incoming
                (make-temp-file (expand-file-name ".incoming-" directory)))
          (copy-file path incoming t)
          (set-file-modes incoming #o600)
          (if (and old-current (file-exists-p old-current))
              (progn
                (copy-file old-current previous t)
                (set-file-modes previous #o600))
            (setq previous nil))
          (rename-file incoming current t)
          (setq incoming nil)
          (let ((now (rsr/agent-sessions--now)))
            (sqlite-execute
             (rsr/agent-sessions--db)
             "INSERT INTO shared_file_snapshots
                (kind, key, path, previous_path, current_path, updated_at)
              VALUES (?, ?, ?, ?, ?, ?)
              ON CONFLICT(kind, key, path) DO UPDATE
                SET previous_path = excluded.previous_path,
                    current_path  = excluded.current_path,
                    updated_at    = excluded.updated_at"
             (append key (list path previous current now)))
            (list :key key :previous-path previous :current-path current
                  :updated-at now)))
      (when (and incoming (file-exists-p incoming))
        (delete-file incoming)))))

(defun rsr/agent-sessions--files-collapse (keys)
  "Move file rows stored under the less durable KEYS onto (car KEYS).
The same tidying `rsr/agent-sessions--note-set' does, and for the same reason: a
session that gains an agent session id should end up with one file list under
that id rather than one per identity it has held.  A path already present under
the primary key wins, so this can never undo a newer share."
  (let* ((table (rsr/agent-sessions--shared-files-table))
         (primary (car keys))
         (db (rsr/agent-sessions--db))
         (kept (gethash primary table))
         (moved nil))
    (rsr/agent-sessions--file-snapshots-collapse keys)
    (dolist (key (cdr keys))
      (when-let ((files (gethash key table)))
        (dolist (f files)
          (unless (seq-find (lambda (k) (equal (plist-get k :path)
                                               (plist-get f :path)))
                            kept)
            (push f moved)))
        (remhash key table)
        (sqlite-execute db "DELETE FROM shared_files WHERE kind = ? AND key = ?"
                        key)))
    (when moved
      (setq moved (nreverse moved))
      (puthash primary (append kept moved) table)
      (dolist (f moved)
        (rsr/agent-sessions--shared-file-write primary f)))))

(defun rsr/agent-sessions--share-file (session path label)
  "Attach PATH to SESSION with LABEL, unvisited.  Return the file plist.
Re-sharing a path already attached updates it in place rather than adding a
second row: the label is refreshed (an empty LABEL keeps the old one, since an
agent re-sharing may have nothing to add beyond \"changed\"), `:visited-at' is
cleared so the row highlights again, and `:shared-at' — the sort key — is left
at the original share so the row does not move."
  (let ((keys (rsr/agent-sessions--session-note-keys session))
        (path (expand-file-name path))
        (now (rsr/agent-sessions--now)))
    (unless keys
      (error "Session has no durable identity to attach a file to"))
    (rsr/agent-sessions--files-collapse keys)
    (rsr/agent-sessions--snapshot-file (car keys) path)
    (let* ((table (rsr/agent-sessions--shared-files-table))
           (primary (car keys))
           (files (gethash primary table))
           (existing (seq-find (lambda (f) (equal (plist-get f :path) path))
                               files))
           (file (list :path path
                       :label (or (and label (not (string-empty-p label)) label)
                                  (and existing (plist-get existing :label)))
                       :shared-at (or (and existing (plist-get existing :shared-at))
                                      now)
                       :updated-at now
                       :visited-at nil)))
      (puthash primary
               (if existing
                   (mapcar (lambda (f) (if (eq f existing) file f)) files)
                 (append files (list file)))
               table)
      (rsr/agent-sessions--shared-file-write primary file)
      (rsr/agent-sessions--shared-paths-invalidate)
      file)))

(defun rsr/agent-sessions--detach-file (session path)
  "Remove PATH from SESSION's shared files; return non-nil if it was attached.
The file on disk is never touched — this drops the pointer to it, nothing more."
  (let ((table (rsr/agent-sessions--shared-files-table))
        (db (rsr/agent-sessions--db))
        (removed nil))
    (dolist (key (rsr/agent-sessions--session-note-keys session))
      (let ((files (gethash key table)))
        (when (seq-find (lambda (f) (equal (plist-get f :path) path)) files)
          (puthash key
                   (seq-remove (lambda (f) (equal (plist-get f :path) path))
                               files)
                   table)
          (sqlite-execute db "DELETE FROM shared_files
                               WHERE kind = ? AND key = ? AND path = ?"
                          (append key (list path)))
          (setq removed t))))
    (when removed (rsr/agent-sessions--shared-paths-invalidate))
    removed))

(defun rsr/agent-sessions--set-visited (match-fn visitedp)
  "Set the visited state of every shared file MATCH-FN accepts.
Returns non-nil when something actually changed, so callers can skip a render.
Matching is by predicate rather than by (session, path) because the two callers
want different tests — a dashboard command knows the exact stored path, while
the focus hook only knows the true name of a buffer's file — and because a file
shared with two sessions should stop nagging from both once it has been read."
  (let ((db (rsr/agent-sessions--db))
        (stamp (and visitedp (rsr/agent-sessions--now)))
        (changed nil))
    (maphash
     (lambda (key files)
       (dolist (f files)
         (when (and (funcall match-fn f)
                    (not (eq (null (plist-get f :visited-at)) (null stamp))))
           (plist-put f :visited-at stamp)
           (sqlite-execute db "UPDATE shared_files SET visited_at = ?
                                WHERE kind = ? AND key = ? AND path = ?"
                           (list stamp (car key) (cadr key)
                                 (plist-get f :path)))
           (setq changed t))))
     (rsr/agent-sessions--shared-files-table))
    changed))

(defun rsr/agent-sessions--revert-shared-file-buffer (path)
  "Refresh an unmodified buffer already visiting PATH from disk.
Do not create a buffer for PATH, and never replace unsaved buffer changes."
  (when-let ((buffer (find-buffer-visiting path)))
    (with-current-buffer buffer
      (unless (buffer-modified-p)
        (revert-buffer t t)))))

;;;###autoload
(defun rsr/agent-sessions-share-file (session-id path &optional label
                                                agent-session-id)
  "Attach PATH to the agent session running in terminal SESSION-ID.
The `emacs-share file' entry point calls over emacsclient, so SESSION-ID is
the terminal's EMACS_AGENT_SESSION_ID — the id the shell has.  When
AGENT-SESSION-ID is supplied, it is the agent's durable thread identity and
takes precedence because a shared daemon can retain another terminal's id.
If an unmodified buffer already visits PATH, refresh it from disk; modified
buffers are left alone so sharing can never discard unsaved work.
Returns a string for the caller to print: emacsclient is the agent's only
channel back, so a failure has to be reported in the value, not signalled."
  (let ((session (rsr/agent-sessions--session-for-share
                  session-id agent-session-id)))
    (cond
     ((null session)
      (if (and agent-session-id (not (string-empty-p agent-session-id)))
          (format "No Emacs agent session registered for agent id %s"
                  agent-session-id)
        (format "No Emacs terminal registered for session id %s" session-id)))
     ((not (file-exists-p path))
      (format "No such file: %s" path))
     (t
      (rsr/agent-sessions--revert-shared-file-buffer path)
      (rsr/agent-sessions--share-file session path label)
      (rsr/agent-sessions--refresh-if-visible)
      (format "Shared %s" (abbreviate-file-name (expand-file-name path)))))))

;;; Shared links ------------------------------------------------------------

(defconst rsr/agent-sessions--link-kind-labels
  '(("linear" . "Linear")
    ("pr" . "PR"))
  "Supported external link kinds and their dashboard labels.")

(defvar rsr/agent-sessions--shared-links nil
  "Hash table KEY -> list of shared-link plists, or nil before first load.
A KEY is the same durable session identity used by notes and shared files.
Each plist is (:kind K :url U :label L :shared-at TS :updated-at TS
:visited-at TS-or-nil).  A session can have multiple links of each kind;
the data is backed by the `shared_links' table.")

(defun rsr/agent-sessions--shared-links-table ()
  "Return the shared-links table, loading it from the database once."
  (or rsr/agent-sessions--shared-links
      (setq rsr/agent-sessions--shared-links
            (let ((table (make-hash-table :test 'equal)))
              (pcase-dolist
                  (`(,owner-kind ,owner-key ,link-kind ,url ,label
                                  ,shared ,updated ,visited)
                   (sqlite-select
                    (rsr/agent-sessions--db)
                    "SELECT owner_kind, owner_key, link_kind, url, label,
                            shared_at, updated_at, visited_at
                       FROM shared_links ORDER BY shared_at, link_kind"))
                (let ((key (list owner-kind owner-key)))
                  (puthash key
                           (append (gethash key table)
                                   (list (list :kind link-kind :url url
                                               :label label :shared-at shared
                                               :updated-at updated
                                               :visited-at visited)))
                           table)))
              table))))

(defun rsr/agent-sessions--link-note-key (url)
  "Note key for the shared external link at URL."
  (list "link" url))

(defun rsr/agent-sessions--links-scope (session)
  "Manual-order scope for SESSION's shared external links."
  (list "links" (or (cadr (car (rsr/agent-sessions--session-note-keys session)))
                    "?")))

(defun rsr/agent-sessions--session-links (session)
  "External links shared with SESSION, in display order."
  (let ((table (rsr/agent-sessions--shared-links-table))
        links)
    (dolist (key (rsr/agent-sessions--session-note-keys session))
      (setq links (append links (copy-sequence (gethash key table)))))
    (rsr/agent-sessions--apply-manual-order
     (rsr/agent-sessions--links-scope session)
     (lambda (link) (plist-get link :url))
     (sort links (lambda (a b) (< (plist-get a :shared-at)
                                  (plist-get b :shared-at)))))))

(defun rsr/agent-sessions--shared-link-write (key link)
  "Upsert LINK under durable session identity KEY in the database."
  (sqlite-execute
   (rsr/agent-sessions--db)
   "INSERT INTO shared_links
      (owner_kind, owner_key, link_kind, url, label,
       shared_at, updated_at, visited_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(owner_kind, owner_key, url) DO UPDATE
      SET link_kind  = excluded.link_kind,
          label      = excluded.label,
          updated_at = excluded.updated_at,
          visited_at = excluded.visited_at"
   (append key (list (plist-get link :kind)
                     (plist-get link :url)
                     (plist-get link :label)
                     (plist-get link :shared-at)
                     (plist-get link :updated-at)
                     (plist-get link :visited-at)))))

(defun rsr/agent-sessions--links-collapse (keys)
  "Move links stored under the less durable KEYS onto (car KEYS)."
  (let* ((table (rsr/agent-sessions--shared-links-table))
         (primary (car keys))
         (db (rsr/agent-sessions--db))
         (kept (gethash primary table))
         moved)
    (dolist (key (cdr keys))
      (when-let ((links (gethash key table)))
        (dolist (link links)
          (unless (seq-find
                   (lambda (candidate)
                     (equal (plist-get candidate :url)
                            (plist-get link :url)))
                   (append kept moved))
            (push link moved)))
        (remhash key table)
        (sqlite-execute
         db "DELETE FROM shared_links WHERE owner_kind = ? AND owner_key = ?"
         key)))
    (when moved
      (setq moved (nreverse moved))
      (puthash primary (append kept moved) table)
      (dolist (link moved)
        (rsr/agent-sessions--shared-link-write primary link)))))

(defun rsr/agent-sessions--share-link (session kind url label)
  "Attach KIND link URL with LABEL to SESSION.
An identical registration is a no-op, including preserving its visited state.
Changing the label updates that URL and marks it unvisited, while preserving
its original display position."
  (let ((keys (rsr/agent-sessions--session-note-keys session))
        (now (rsr/agent-sessions--now)))
    (unless keys
      (error "Session has no durable identity to attach a link to"))
    (rsr/agent-sessions--links-collapse keys)
    (let* ((table (rsr/agent-sessions--shared-links-table))
           (primary (car keys))
           (links (gethash primary table))
           (existing (seq-find
                      (lambda (link) (equal (plist-get link :url) url))
                      links))
           (label (or (and label (not (string-empty-p label)) label)
                      (and existing (plist-get existing :label)))))
      (if (and existing
               (equal kind (plist-get existing :kind))
               (equal label (plist-get existing :label)))
          existing
        (let ((link (list :kind kind :url url :label label
                          :shared-at (or (and existing
                                               (plist-get existing :shared-at))
                                         now)
                          :updated-at now
                          :visited-at nil)))
          (puthash primary
                   (if existing
                       (mapcar (lambda (candidate)
                                 (if (eq candidate existing) link candidate))
                               links)
                     (append links (list link)))
                   table)
          (rsr/agent-sessions--shared-link-write primary link)
          link)))))

(defun rsr/agent-sessions--detach-link (session url)
  "Remove the link at URL from SESSION; return non-nil if attached."
  (let ((table (rsr/agent-sessions--shared-links-table))
        (db (rsr/agent-sessions--db))
        removed)
    (dolist (key (rsr/agent-sessions--session-note-keys session))
      (let ((links (gethash key table)))
        (when (seq-find (lambda (link) (equal (plist-get link :url) url))
                        links)
          (puthash key
                   (seq-remove
                    (lambda (link) (equal (plist-get link :url) url))
                    links)
                   table)
          (sqlite-execute
           db
           "DELETE FROM shared_links
             WHERE owner_kind = ? AND owner_key = ? AND url = ?"
           (append key (list url)))
          (setq removed t))))
    removed))

(defun rsr/agent-sessions--set-link-visited (match-fn visitedp)
  "Set visited state of every shared link accepted by MATCH-FN."
  (let ((db (rsr/agent-sessions--db))
        (stamp (and visitedp (rsr/agent-sessions--now)))
        changed)
    (maphash
     (lambda (key links)
       (dolist (link links)
         (when (and (funcall match-fn link)
                    (not (eq (null (plist-get link :visited-at))
                             (null stamp))))
           (plist-put link :visited-at stamp)
           (sqlite-execute
            db
            "UPDATE shared_links SET visited_at = ?
              WHERE owner_kind = ? AND owner_key = ? AND url = ?"
            (list stamp (car key) (cadr key) (plist-get link :url)))
           (setq changed t))))
     (rsr/agent-sessions--shared-links-table))
    changed))

;;;###autoload
(defun rsr/agent-sessions-share-link (session-id kind url &optional label
                                                agent-session-id)
  "Attach a typed external link to the session in terminal SESSION-ID.
KIND is `linear' or `pr'; URL must be HTTP(S).  Re-registering the same value
is idempotent.  AGENT-SESSION-ID, when supplied, is the durable agent thread
identity and takes precedence over SESSION-ID.  Returns a printable status
string for `emacs-share link'."
  (let ((session (rsr/agent-sessions--session-for-share
                  session-id agent-session-id)))
    (cond
     ((null session)
      (if (and agent-session-id (not (string-empty-p agent-session-id)))
          (format "No Emacs agent session registered for agent id %s"
                  agent-session-id)
        (format "No Emacs terminal registered for session id %s" session-id)))
     ((not (assoc kind rsr/agent-sessions--link-kind-labels))
      (format "Unknown link kind `%s'; expected linear or pr" kind))
     ((not (string-match-p "\\`https?://[^[:space:]]+\\'" url))
      (format "Invalid link URL: %s" url))
     (t
      (rsr/agent-sessions--share-link session kind url label)
      (rsr/agent-sessions--refresh-if-visible)
      (format "Linked %s: %s" kind url)))))

;;;; Registered folders (`emacs-share folder plans|code PATH')

(defvar rsr/agent-sessions--registered-folders nil
  "Hash table (KEY . FOLDER-KIND) -> list of paths, or nil before first load.
KEY is the durable session identity used by notes and links; FOLDER-KIND is
\"plans\" or \"code\".  Backed by the `registered_folders' table.")

(defconst rsr/agent-sessions--folder-kinds '("plans" "code")
  "Folder kinds a session can register.")

(defun rsr/agent-sessions--registered-folders-table ()
  "Return the registered-folders table, loading it from the database once."
  (or rsr/agent-sessions--registered-folders
      (setq rsr/agent-sessions--registered-folders
            (let ((table (make-hash-table :test 'equal)))
              (pcase-dolist (`(,owner-kind ,owner-key ,kind ,path)
                             (sqlite-select
                              (rsr/agent-sessions--db)
                              "SELECT owner_kind, owner_key, folder_kind, path
                                 FROM registered_folders ORDER BY shared_at, rowid"))
                (let ((key (cons (list owner-kind owner-key) kind)))
                  (puthash key (append (gethash key table) (list path)) table)))
              table))))

(defun rsr/agent-sessions--session-folder-paths (session kind)
  "Folders of KIND (\"plans\" or \"code\") registered for SESSION, oldest first.
Every identity the session has held is read, like notes and links, so a
folder registered on a bare terminal is still found once the agent has an id."
  (let ((table (rsr/agent-sessions--registered-folders-table))
        paths)
    (dolist (key (rsr/agent-sessions--session-note-keys session))
      (dolist (path (gethash (cons key kind) table))
        (unless (member path paths)
          (setq paths (append paths (list path))))))
    paths))

(defun rsr/agent-sessions--register-folder (session kind path)
  "Register PATH as SESSION's folder of KIND.
A session works on one task, so a new Plans folder replaces the old one; a
task may span several repositories, so code folders accumulate, each once."
  (let ((keys (rsr/agent-sessions--session-note-keys session))
        (table (rsr/agent-sessions--registered-folders-table))
        (db (rsr/agent-sessions--db)))
    (unless keys
      (error "Session has no durable identity to register a folder on"))
    (let* ((primary (car keys))
           (slot (cons primary kind))
           (paths (gethash slot table)))
      (with-sqlite-transaction db
        (when (equal kind "plans")
          (sqlite-execute db "DELETE FROM registered_folders
                               WHERE owner_kind = ? AND owner_key = ?
                                 AND folder_kind = ?"
                          (append primary (list kind)))
          (setq paths nil))
        (unless (member path paths)
          (sqlite-execute db "INSERT OR IGNORE INTO registered_folders
                              VALUES (?, ?, ?, ?, ?)"
                          (append primary
                                  (list kind path (rsr/agent-sessions--now))))
          (setq paths (append paths (list path)))))
      (puthash slot paths table)
      paths)))

;;;###autoload
(defun rsr/agent-sessions-share-folder (session-id kind path &optional
                                                  agent-session-id)
  "Register PATH as the KIND folder of the session in terminal SESSION-ID.
The `emacs-share folder' entry point: a workflow stage tells the dashboard
where its task's Plans folder and code live, so `O' can open them without
guessing.  KIND is \"plans\" or \"code\".  SESSION-ID and AGENT-SESSION-ID
resolve as in `rsr/agent-sessions-share-link'.  Returns a printable status."
  (let ((session (rsr/agent-sessions--session-for-share
                  session-id agent-session-id))
        (path (and path (not (string-empty-p path))
                   (file-name-as-directory (expand-file-name path)))))
    (cond
     ((null session)
      (if (and agent-session-id (not (string-empty-p agent-session-id)))
          (format "No Emacs agent session registered for agent id %s"
                  agent-session-id)
        (format "No Emacs terminal registered for session id %s" session-id)))
     ((not (member kind rsr/agent-sessions--folder-kinds))
      (format "Unknown folder kind `%s'; expected plans or code" kind))
     ((or (null path) (not (file-directory-p path)))
      (format "No such directory: %s" (or path "")))
     (t
      (rsr/agent-sessions--register-folder session kind path)
      (rsr/agent-sessions--refresh-if-visible)
      (format "Folder %s: %s" kind path)))))

(defun rsr/agent-sessions--file-at-point ()
  "Return (SESSION PATH FILE) for the shared-file row at point, or nil.
Point may be on the row itself or inside a note rendered under it, which
resolves to the file the note is about — the same courtesy
`rsr/agent-sessions--note-target-at-point' extends."
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'rsr/agent-session-note))
      (setq section (oref section parent)))
    (when (and section (eq (oref section type) 'rsr/agent-session-file))
      (let* ((path (oref section value))
             (row (rsr/agent-sessions--enclosing-section 'rsr/agent-session-row))
             (session (and row (rsr/agent-sessions--session-for-id
                                (oref row value)))))
        (when session
          (list session path
                (seq-find (lambda (f) (equal (plist-get f :path) path))
                          (rsr/agent-sessions--session-files session))))))))

(defun rsr/agent-sessions--link-at-point ()
  "Return (SESSION KIND LINK) for the shared-link row at point, or nil.
Point may be on the link row or inside its note."
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'rsr/agent-session-note))
      (setq section (oref section parent)))
    (when (and section (eq (oref section type) 'rsr/agent-session-link))
      (let* ((url (oref section value))
             (row (rsr/agent-sessions--enclosing-section 'rsr/agent-session-row))
             (session (and row (rsr/agent-sessions--session-for-id
                                (oref row value)))))
        (when session
          (list session url
                (seq-find (lambda (link)
                            (equal (plist-get link :url) url))
                          (rsr/agent-sessions--session-links session))))))))

(defcustom rsr/agent-sessions-linear-org-file
  (expand-file-name "~/Stillness/Brain/output/linear.org")
  "Org file of pulled Linear issues, one heading per issue with ID-LINEAR.
RET on a Linear link row jumps to the issue's heading here.  nil, or a
missing file, sends every Linear link to `rsr/agent-sessions-linear-app'."
  :type '(choice file (const :tag "None" nil)))

(defcustom rsr/agent-sessions-linear-app "/Applications/Linear.app"
  "Linear desktop app that opens Linear links not found in Org.
nil, or an app that is not installed, opens them with `browse-url'."
  :type '(choice directory (const :tag "Browser" nil)))

(defun rsr/agent-sessions--linear-issue-id (url)
  "Return the issue identifier, such as \"STI-5\", in Linear URL, or nil."
  (when (string-match "/issue/\\([A-Za-z][A-Za-z0-9]*-[0-9]+\\)" url)
    (upcase (match-string 1 url))))

(defun rsr/agent-sessions--linear-heading (url)
  "Return a marker at the heading for Linear URL's issue, or nil.
The heading is the one in `rsr/agent-sessions-linear-org-file' whose
ID-LINEAR property is the issue identifier in URL.  This is a line search,
not `org-find-property': linear-emacs writes multi-line DESCRIPTION values
into the drawer, which Org then no longer parses as a property drawer."
  (let ((id (rsr/agent-sessions--linear-issue-id url))
        (file rsr/agent-sessions-linear-org-file))
    (when (and id file (file-readable-p file))
      (with-current-buffer (find-file-noselect file)
        (org-with-wide-buffer
         (goto-char (point-min))
         (let ((case-fold-search t))
           (when (re-search-forward
                  (concat "^[ \t]*:ID-LINEAR:[ \t]+" (regexp-quote id) "[ \t]*$")
                  nil t)
             (org-back-to-heading t)
             (point-marker))))))))

(defun rsr/agent-sessions--open-linear-app (url)
  "Open URL in `rsr/agent-sessions-linear-app', or the browser without it."
  (let ((app rsr/agent-sessions-linear-app))
    (if (and app (eq system-type 'darwin) (file-directory-p app))
        (call-process "open" nil 0 nil "-a" app url)
      (browse-url url))))

(defun rsr/agent-sessions--show-linear-heading (url display-fn)
  "Show Linear URL's Org heading with DISPLAY-FN, else open URL in the app."
  (let ((marker (rsr/agent-sessions--linear-heading url)))
    (if (not marker)
        (rsr/agent-sessions--open-linear-app url)
      (let* ((buf (marker-buffer marker))
             (shown (funcall display-fn buf))
             (window (if (windowp shown) shown (get-buffer-window buf))))
        (with-selected-window (or window (selected-window))
          (with-current-buffer buf
            (when (or (< marker (point-min)) (> marker (point-max)))
              (widen))
            (goto-char marker)
            (org-fold-show-context)
            (org-fold-show-entry)
            (when window (recenter 0)))))
      (set-marker marker nil))))

(defun rsr/agent-sessions--open-link-at-point (&optional linear-fn)
  "Open the shared external link at point and clear its highlight.
A Linear link goes to LINEAR-FN, called with its URL, when given; every
other link opens with `browse-url'."
  (pcase (rsr/agent-sessions--link-at-point)
    (`(,_session ,_kind ,link)
     (let ((url (plist-get link :url)))
       (when (rsr/agent-sessions--set-link-visited
              (lambda (candidate)
                (equal (plist-get candidate :url) url))
              t)
         (rsr/agent-sessions--refresh-if-visible))
       (if (and linear-fn (equal (plist-get link :kind) "linear"))
           (funcall linear-fn url)
         (browse-url url))))))

(defun rsr/agent-sessions--open-file-at-point (display-fn)
  "Open the shared file at point with DISPLAY-FN, clearing its highlight.
The refresh happens before DISPLAY-FN runs so the dashboard's point
restoration is not competing with whatever DISPLAY-FN does to the windows."
  (pcase (rsr/agent-sessions--file-at-point)
    (`(,_session ,path ,_file)
     (if (not (file-exists-p path))
         (message "File no longer exists: %s" (abbreviate-file-name path))
       (when (rsr/agent-sessions--set-visited
              (lambda (f) (equal (plist-get f :path) path)) t)
         (rsr/agent-sessions--refresh-if-visible))
       (funcall display-fn (find-file-noselect path))))))

(defun rsr/agent-sessions-show-file-diff ()
  "Show the latest committed diff for the shared file at point, then mark it read.
The Magit revision buffer is limited to that file.  If the file is outside a
Git repository or has no committed history, leave its unread state unchanged."
  (interactive)
  (pcase (rsr/agent-sessions--file-at-point)
    (`(,_session ,path ,_file)
     (let* ((root (magit-toplevel (file-name-directory path)))
            (relative (and root (file-relative-name path root)))
            (default-directory (or root default-directory))
            (commit (and root
                         (magit-git-string "log" "-1" "--format=%H"
                                           "--follow" "--" relative))))
       (unless root
         (user-error "File is not in a Git repository"))
       (unless commit
         (user-error "File has no committed diff"))
       ;; Magit shows a diff with `display-buffer''s default, which splits
       ;; the window beside the side-window dashboard; replace it instead.
       (let ((display-buffer-overriding-action rsr/agent-tmux-other-window-action))
         (magit-show-commit commit (car (magit-show-commit--arguments))
                            (list relative)))
       (when (rsr/agent-sessions--set-visited
              (lambda (file) (equal (plist-get file :path) path)) t)
         (rsr/agent-sessions--refresh-if-visible))))
    (_ (message "No shared file at point."))))

(defun rsr/agent-sessions-show-file-submission-diff ()
  "Show the diff between the latest two submissions of the file at point.
Unlike `rsr/agent-sessions-show-file-diff', this compares cached copies made at
share time and therefore works without Git and across uncommitted edits.  If
the file predates snapshot support, save its current contents as the first
snapshot instead.  Mark the file read only after a diff is successfully
produced."
  (interactive)
  (pcase (rsr/agent-sessions--file-at-point)
    (`(,session ,path ,_file)
     (let* ((keys (rsr/agent-sessions--session-note-keys session))
            (snapshot (rsr/agent-sessions--file-snapshot-row keys path)))
       (if (not snapshot)
           (progn
             (unless (file-exists-p path)
               (user-error "File no longer exists: %s"
                           (abbreviate-file-name path)))
             (rsr/agent-sessions--snapshot-file (car keys) path)
             (message "Saved current file as its first submitted snapshot"))
         (let ((previous (plist-get snapshot :previous-path))
               (current (plist-get snapshot :current-path)))
           (unless previous
             (user-error "File has only one submitted version"))
           (unless (and (file-exists-p previous) (file-exists-p current))
             (user-error "Submitted-version cache is incomplete"))
           (let* ((name (file-name-nondirectory path))
                  (buffer-name (format "*Agent submission diff: %s*" name))
                  (buffer (diff-no-select previous current "-u" t
                                          (get-buffer-create buffer-name))))
             (with-current-buffer buffer
               (setq-local header-line-format
                           (format "Submitted versions of %s"
                                   (abbreviate-file-name path))))
             (when (rsr/agent-sessions--set-visited
                    (lambda (file) (equal (plist-get file :path) path)) t)
               (rsr/agent-sessions--refresh-if-visible))
             (pop-to-buffer buffer rsr/agent-tmux-other-window-action))))))
    (_ (message "No shared file at point."))))

(defface rsr/agent-session-file-unvisited
  '((t :inherit rsr/agent-session-needs-attention))
  "Face for a shared file not opened since the agent last shared it.
Inherits the needs-attention face deliberately: an unread file and a waiting
session are the same claim on the user's attention, and the dashboard should
not make them learn two highlights for it.")

(defface rsr/agent-session-file
  '((t :inherit default))
  "Face for a shared file the user has already opened.")

(defface rsr/agent-session-link-unvisited
  '((t :inherit rsr/agent-session-needs-attention))
  "Face for an external link not opened since the agent registered it.")

(defface rsr/agent-session-link
  '((t :inherit link :underline nil))
  "Face for the URL of an external link the user has already opened.
Only the URL carries it, and without `link''s underline: spread over the whole
row, the underline ran from the left edge and read as a rule between rows.")

(defvar rsr/agent-sessions--attachment-width 28
  "Name column width for file and link rows; bound per session when rendering.")

(defun rsr/agent-sessions--link-kind-label (link)
  "The label naming LINK's kind on its row, e.g. `Linear'."
  (let ((kind (plist-get link :kind)))
    (or (cdr (assoc kind rsr/agent-sessions--link-kind-labels)) kind)))

(defun rsr/agent-sessions--attachment-name-width (session)
  "Width of the name column for SESSION's file and link rows.
Fits the longest name among them, so a short `Linear' or `brief.md' does not
push its URL or label off a narrow window."
  (apply #'max 1
         (append
          (mapcar (lambda (link)
                    (string-width (or (rsr/agent-sessions--link-kind-label link) "")))
                  (rsr/agent-sessions--session-links session))
          (mapcar (lambda (file)
                    (string-width (file-name-nondirectory
                                   (directory-file-name (plist-get file :path)))))
                  (rsr/agent-sessions--session-files session)))))

(defun rsr/agent-sessions--insert-link (link indent)
  "Insert a row for shared external LINK, indented by INDENT."
  (let* ((url (plist-get link :url))
         (unvisited (null (plist-get link :visited-at)))
         (kind-label (rsr/agent-sessions--link-kind-label link)))
    (push (cons (line-beginning-position)
                (if unvisited 'needs-attention 'idle))
          rsr/agent-sessions--row-status)
    (magit-insert-section (rsr/agent-session-link url t)
      (magit-insert-heading
       (rsr/agent-sessions--dress
        (concat indent (if unvisited "● " "  ")
                (rsr/agent-sessions--icon 'link)
                (propertize (format (format "%%-%ds " rsr/agent-sessions--attachment-width)
                                    kind-label)
                            'font-lock-face 'rsr/agent-session-link-kind)
                (propertize (or (plist-get link :label) url)
                            'font-lock-face 'rsr/agent-session-link)
                "\n")
        (if unvisited 'rsr/agent-session-link-unvisited 'default)))
      (rsr/agent-sessions--insert-note
       (list (rsr/agent-sessions--link-note-key url))
       (concat indent "    ")))))

(defun rsr/agent-sessions--insert-links (session indent)
  "Insert every external link shared with SESSION, indented by INDENT."
  (dolist (link (rsr/agent-sessions--session-links session))
    (rsr/agent-sessions--insert-link link indent)))

(defun rsr/agent-sessions--insert-file (file indent)
  "Insert a row for shared FILE, indented by INDENT.
INDENT puts the row at the same depth as the session's note — one level in
from the session row — so it reads as hanging off that session rather than as
another row beside it.  Its section value is the path:
stable across renders, unique within a session, and disambiguated from the
same path under another session by magit's parent chain."
  (let* ((path (plist-get file :path))
         (unvisited (null (plist-get file :visited-at)))
         ;; One stat per file per render.  Affordable at the scale this holds
         ;; (a handful of paths, all local) and worth it: a file an agent
         ;; wrote to /tmp and the reaper has since removed should say so
         ;; rather than fail on RET.
         (missing (not (file-exists-p path))))
    ;; Record what this row *shows*, for `N'/`P' — see the docstring of
    ;; `rsr/agent-sessions--row-status'.  An unopened file is reachable by the
    ;; attention keys for the same reason it is highlighted like one.
    (push (cons (line-beginning-position)
                (if unvisited 'needs-attention 'idle))
          rsr/agent-sessions--row-status)
    (magit-insert-section (rsr/agent-session-file path t)
      (magit-insert-heading
       (rsr/agent-sessions--dress
        (concat indent (if unvisited "● " "  ")
                (rsr/agent-sessions--icon 'file path)
                (propertize (format (format "%%-%ds " rsr/agent-sessions--attachment-width)
                                    (file-name-nondirectory (directory-file-name path)))
                            'font-lock-face 'rsr/agent-session-file-name)
                (propertize (or (plist-get file :label)
                                (abbreviate-file-name path))
                            'font-lock-face 'rsr/agent-session-file-label)
                (if missing "  (missing)" "")
                "\n")
        (if unvisited
                            'rsr/agent-session-file-unvisited
                          'rsr/agent-session-file)))
      (rsr/agent-sessions--insert-note
       (list (rsr/agent-sessions--file-note-key path))
       (concat indent "    ")))))

(defun rsr/agent-sessions--insert-files (session indent)
  "Insert a row for every file shared with SESSION, indented by INDENT."
  (dolist (file (rsr/agent-sessions--session-files session))
    (rsr/agent-sessions--insert-file file indent)))

(defun rsr/agent-sessions--entries-tmux-session (entries)
  "The tmux session of the repo ENTRIES belong to, or nil when none runs in tmux.
Each repository is meant to have one tmux session, named by the user and
started inside it, so a session started in the repo wins.  Agents of one repo
are often launched from another repo's session (a plan opening its implementer
from where the user happened to be), and before this they renamed the repo as
soon as they outnumbered its own agents.  Without a session started in the
repo, the one most of ENTRIES run in stands in."
  (let ((root (and entries (rsr/agent-sessions--session-repo
                            (plist-get (car entries) :session))))
        counts)
    (dolist (e entries)
      (let ((buf (plist-get (plist-get e :session) :buffer)))
        (when-let* (((buffer-live-p buf))
                    ((rsr/agent-tmux-proxy-p buf))
                    (name (buffer-local-value 'rsr/agent-tmux-session buf)))
          (setf (alist-get name counts 0 nil #'equal)
                (1+ (alist-get name counts 0 nil #'equal))))))
    (setq counts (sort counts (lambda (a b) (> (cdr a) (cdr b)))))
    (or (and root
             (car (seq-find (lambda (count)
                              (equal (plist-get (rsr/agent-sessions--tmux-session-home
                                                 (car count))
                                                :repo-root)
                                     root))
                            counts)))
        (car (car counts)))))

(defun rsr/agent-sessions--repo-heading-name (entries)
  "The name the heading of the repo ENTRIES belong to shows.
The tmux session started in the repo, when one of ENTRIES runs in it: the
user's name for the project, where a checkout folder may be called `main'.
Spelled as the repo when the session's name is only the repo's made safe for
tmux (`.emacs.d' for `-emacs-d').  A session started in another repo does not
name this one; the repo's own name does."
  (let* ((session (plist-get (car entries) :session))
         (repo (plist-get session :repo))
         (root (rsr/agent-sessions--session-repo session))
         (tmux (rsr/agent-sessions--entries-tmux-session entries))
         (home (and tmux (rsr/agent-sessions--tmux-session-home tmux))))
    (cond
     ((and tmux root (equal (plist-get home :repo-root) root))
      (if (and repo (equal tmux (rsr/agent-tmux-session-name repo))) repo tmux))
     (repo)
     (tmux)
     (t "?"))))

(defun rsr/agent-sessions--shared-at-label (entries)
  "The `@' label most of ENTRIES share, or nil when ENTRIES is empty.
A folder heading shows it, so its rows need repeat only a different one."
  (let (counts)
    (dolist (e entries)
      (let ((label (rsr/agent-sessions--session-at-label (plist-get e :session))))
        (setf (alist-get label counts 0 nil #'equal)
              (1+ (alist-get label counts 0 nil #'equal)))))
    (car (car (sort (nreverse counts) (lambda (a b) (> (cdr a) (cdr b))))))))

(defun rsr/agent-sessions--label-entries (entries)
  "ENTRIES, each carrying the `@' label its row shows as `:at-label'.
A row shows its label only when it differs from the one its heading shows:
its folder's, or for a row in no folder, its repo's."
  (let ((shared (mapcar (lambda (group)
                          (cons (car group)
                                (rsr/agent-sessions--shared-at-label
                                 (cdr group))))
                        (seq-group-by (lambda (e)
                                        (rsr/agent-sessions--folder-for-session
                                         (plist-get e :session)))
                                      entries))))
    (mapcar (lambda (e)
              (let* ((session (plist-get e :session))
                     (label (rsr/agent-sessions--session-at-label session))
                     (folder-label
                      (cdr (assoc (rsr/agent-sessions--folder-for-session session)
                                  shared))))
                (append (list :at-label (unless (equal label folder-label) label))
                        e)))
            entries)))

(defun rsr/agent-sessions--build-tree (entries)
  "Group live ENTRIES into repos, each named by `--repo-heading-name'.
The tmux session started in the repository is the user's name for it; the
git checkout's folder name is the fallback, since with worktrees kept together
inside a project folder the main checkout is often called `main'.  An agent outside
any git repository joins the repo its tmux session was started in (see
`rsr/agent-sessions--tmux-home')."
  (let* ((repos
          (mapcar
           (lambda (rentries)
             (let ((session (plist-get (car rentries) :session)))
               (list :name (rsr/agent-sessions--repo-heading-name rentries)
                     :root (rsr/agent-sessions--session-repo session)
                     :entries (rsr/agent-sessions--label-entries rentries))))
           (mapcar #'cdr
                   (seq-group-by
                    (lambda (e)
                      (rsr/agent-sessions--session-repo (plist-get e :session)))
                    (rsr/agent-sessions--adopt-tmux-entries entries)))))
         (sorted
          (mapcar
           (lambda (repo)
             (let ((items (plist-get repo :entries)))
               (plist-put repo :entries
                          (if rsr/agent-sessions-sort-by-activity
                              (rsr/agent-sessions--by-recency
                               #'rsr/agent-sessions--entry-time items)
                            (rsr/agent-sessions--apply-manual-order
                             (rsr/agent-sessions--sessions-scope
                              (rsr/agent-sessions--repo-key repo) "")
                             #'rsr/agent-sessions--entry-buffer-name
                             (rsr/agent-sessions--sort-entries items))))))
           repos)))
    (if rsr/agent-sessions-sort-by-activity
        (rsr/agent-sessions--by-recency
         (lambda (repo) (rsr/agent-sessions--entries-time
                         (plist-get repo :entries))) sorted)
      (rsr/agent-sessions--apply-manual-order
       rsr/agent-sessions--repos-scope #'rsr/agent-sessions--repo-key
       (sort sorted (lambda (a b) (string< (plist-get a :name)
                                          (plist-get b :name))))))))

(defun rsr/agent-sessions--insert-repo (repo)
  (magit-insert-section (rsr/agent-session-repo
                         (list :name (plist-get repo :name)
                               :root (plist-get repo :root)))
    (magit-insert-heading
      (rsr/agent-sessions--icon 'repo)
      (propertize (plist-get repo :name) 'font-lock-face 'rsr/agent-session-repo)
      ;; The worktree of the rows in no folder, which have no heading of
      ;; their own to name it.
      (if-let ((label (rsr/agent-sessions--shared-at-label
                       (rsr/agent-sessions--folder-entries
                        (list :id nil) (plist-get repo :entries)))))
          (propertize (concat "  " label)
                      'font-lock-face 'rsr/agent-session-worktree-name)
        ""))
    (rsr/agent-sessions--insert-note
     (list (rsr/agent-sessions--repo-note-key repo))
     "  ")
    ;; Sessions in no folder sit directly under the repo, before the folders:
    ;; after them they would read as the last folder's rows.
    (rsr/agent-sessions--insert-folder (list :id nil) (plist-get repo :entries))
    (dolist (folder (rsr/agent-sessions--apply-manual-order
                     (rsr/agent-sessions--folders-scope
                      (rsr/agent-sessions--repo-key repo))
                     #'rsr/agent-sessions--folder-key
                     (sort (copy-sequence
                            (rsr/agent-sessions--folders-for-repo
                             (rsr/agent-sessions--repo-key repo)))
                           (lambda (a b)
                             (string-lessp (plist-get a :name)
                                           (plist-get b :name))))))
      (rsr/agent-sessions--insert-folder folder (plist-get repo :entries)))
    (insert "\n")))

(defun rsr/agent-sessions--folder-entries (folder entries)
  "Return live ENTRIES assigned to FOLDER, including No folder."
  (seq-filter (lambda (entry)
                (equal (plist-get folder :id)
                       (rsr/agent-sessions--folder-for-session
                        (plist-get entry :session))))
              entries))

(defun rsr/agent-sessions--insert-folder (folder entries)
  "Render FOLDER containing live ENTRIES within its repo.
A folder no live session is in is skipped: it stays saved, offered by the
`+' and `F' pickers, and shows again once a session joins it.  The nil folder
(sessions in no folder) gets no heading; its section is kept so `+' and
reordering still find the group."
  (let* ((id (plist-get folder :id))
         (members (rsr/agent-sessions--folder-entries folder entries))
         (repo-key (rsr/agent-sessions--session-repo
                    (plist-get (car entries) :session))))
    (when members
      (magit-insert-section (rsr/agent-session-folder id)
        (when id
          (magit-insert-heading
            "  "
            (rsr/agent-sessions--icon 'folder)
            (propertize (format "%s (%d)" (plist-get folder :name)
                                (length members))
                        'font-lock-face 'magit-section-heading)
            (if-let ((label (rsr/agent-sessions--shared-at-label members)))
                (propertize (concat "  " label)
                            'font-lock-face 'rsr/agent-session-worktree-name)
              "")))
        (rsr/agent-sessions--insert-entries
         (if rsr/agent-sessions-sort-by-activity
             members
           (rsr/agent-sessions--apply-manual-order
            (rsr/agent-sessions--folder-sessions-scope repo-key id)
            #'rsr/agent-sessions--entry-buffer-name members)))))))

(defun rsr/agent-sessions--refresh ()
  (interactive)
  (rsr/agent-sessions--load-folders)
  (let* ((inhibit-read-only t)
         (win (get-buffer-window (current-buffer)))
         (saved-point (if win (window-point win) (point)))
         (section (save-excursion
                    (goto-char saved-point)
                    (magit-current-section)))
         ;; Remember the section at point by its stable identity, not by
         ;; absolute position: erase-buffer + rebuild (and sorting) shift and
         ;; reorder everything, so a char offset is meaningless.
         (ident (and section (magit-section-ident section)))
         ;; Keep point's position within that section as well.  Restoring only
         ;; IDENT puts point at the section's first column on every hook-driven
         ;; refresh, undoing ordinary horizontal motion such as `C-f'/`C-b'.
         (line-offset
          (and section
               (save-excursion
                 (goto-char saved-point)
                 (count-lines (oref section start) (line-beginning-position)))))
         (column (save-excursion
                   (goto-char saved-point)
                   (current-column)))
         (wstart (and win (window-start win))))
    (erase-buffer)
    (setq rsr/agent-sessions--row-status nil
          rsr/agent-sessions--row-buffers nil)
    (magit-insert-section (rsr/agent-sessions-root)
      (let ((entries (rsr/agent-sessions--live-entries)))
        (let ((repos (rsr/agent-sessions--build-tree entries)))
          (if (null repos)
              (insert "No active sessions.\n")
            (dolist (repo repos)
              (rsr/agent-sessions--insert-repo repo))))))
    (setq rsr/agent-sessions--row-status (nreverse rsr/agent-sessions--row-status))
    ;; Freshly inserted sections carry the visibility magit cached for them
    ;; (e.g. a note folded with TAB) in their `hidden' slot, but nothing has
    ;; applied it to the new text yet; this pass does, exactly as
    ;; `magit-refresh-buffer' does after its own inserters run.  Rebind the
    ;; cache off so re-showing doesn't record the state it is restoring.
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    ;; The Shift+TAB cycle caches its visibility choices, as does a manual
    ;; TAB on one session.  Reapplying the global level here would overwrite
    ;; that per-session choice on every hook-driven refresh.
    (when rsr/agent-sessions--overview-level
      (setq rsr/agent-sessions--overview-level
            (min rsr/agent-sessions--overview-level
                 (rsr/agent-sessions--overview-max-level))))
    (let ((target (and ident (magit-get-section ident))))
      (if (not target)
          (goto-char (point-min))
        (let ((start (oref target start))
              (end (oref target end)))
          (goto-char start)
          (forward-line line-offset)
          ;; The section may have become shorter during the refresh.  In that
          ;; case use its last line instead of wandering into the next section.
          (when (>= (point) end)
            (goto-char (max start (1- end)))
            (beginning-of-line))
          (move-to-column column))))
    (when win
      (set-window-point win (point))
      (when wstart
        (set-window-start win (min wstart (point-max)) t)))
    (rsr/agent-sessions--mark-on-screen (current-buffer))))

(defvar-local rsr/agent-sessions--overview-level nil
  "Current Shift+TAB level, from 0 (repos only) to the deepest open level.")

(defun rsr/agent-sessions--overview-depth (section parent-depth)
  "Return SECTION's hierarchy depth, inheriting it for auxiliary sections."
  (pcase (oref section type)
    ('rsr/agent-session-repo 0)
    ;; The headingless group of sessions in no folder has no line to fold to,
    ;; so it takes its repo's depth and its rows fold with the repo's other
    ;; children.
    ('rsr/agent-session-folder (if (oref section value) 1 parent-depth))
    ('rsr/agent-session-row 2)
    ((or 'rsr/agent-session-file 'rsr/agent-session-link) 3)
    (_ parent-depth)))

(defun rsr/agent-sessions--overview-max-level ()
  "Return the deepest hierarchy level in this dashboard's section tree."
  (let ((maximum 0))
    (cl-labels ((visit (section parent-depth)
                  (let ((depth (rsr/agent-sessions--overview-depth
                                section parent-depth)))
                    (setq maximum (max maximum depth))
                    (dolist (child (oref section children))
                      (visit child depth)))))
      (visit magit-root-section -1))
    maximum))

(defun rsr/agent-sessions--show-overview-level (level)
  "Show dashboard hierarchy to LEVEL, opening everything at its maximum."
  (let ((maximum (rsr/agent-sessions--overview-max-level)))
    (cl-labels ((set-visibility (section parent-depth)
                (let ((depth (rsr/agent-sessions--overview-depth
                              section parent-depth)))
                  (unless (eq section magit-root-section)
                    (oset section hidden
                          (and (< level maximum) (<= level depth)))
                    (magit-section-maybe-cache-visibility section))
                  (dolist (child (oref section children))
                    (set-visibility child depth)))))
      (set-visibility magit-root-section -1)))
  (magit-section-show magit-root-section))

(defun rsr/agent-sessions--visible-overview-level ()
  "Return the current uniform hierarchy level, or -1 for a mixed view."
  (let ((maximum (rsr/agent-sessions--overview-max-level)))
    (cl-labels ((matches (section parent-depth level)
                  (let* ((depth (rsr/agent-sessions--overview-depth
                                 section parent-depth))
                         (expected-hidden
                          (and (< level maximum) (<= level depth))))
                    (and (or (eq section magit-root-section)
                             (eq (not (null (oref section hidden)))
                                 (not (null expected-hidden))))
                         (or (and (not (eq section magit-root-section))
                                  expected-hidden)
                             (cl-every (lambda (child)
                                         (matches child depth level))
                                       (oref section children)))))))
      (or (seq-find (lambda (level)
                      (matches magit-root-section -1 level))
                    (number-sequence 0 maximum))
          -1))))

(defun rsr/agent-sessions-toggle-overview ()
  "Cycle repos, groups, sessions, and attachments with Shift+TAB."
  (interactive)
  (unless magit-root-section
    (user-error "No dashboard sections to toggle"))
  (setq rsr/agent-sessions--overview-level
        (mod (1+ (or rsr/agent-sessions--overview-level
                     (rsr/agent-sessions--visible-overview-level)))
             (1+ (rsr/agent-sessions--overview-max-level))))
  (rsr/agent-sessions--show-overview-level
   rsr/agent-sessions--overview-level))

(defun rsr/agent-sessions--reread-repo-info ()
  "Re-read repo/branch info from disk for every live session buffer.
The per-buffer `rsr/agent-sessions--repo-info-cache' is keyed only on the
buffer's directory, so it never notices a branch checkout in the same
directory; and a real agent session's `:worktree' label is frozen at its first
hook.  Both go stale when the branch changes.  Clear the per-buffer caches and
refresh each registered session's repo/worktree fields so `g' reflects the
current branch."
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'rsr/agent-sessions--repo-info-cache buf)
      (with-current-buffer buf
        (setq rsr/agent-sessions--repo-info-cache nil))))
  (maphash
   (lambda (id session)
     (let ((buf (plist-get session :buffer)))
       (when (buffer-live-p buf)
         (let ((info (rsr/agent-sessions--buffer-repo-info buf)))
           ;; Only overwrite when the buffer is still in a repo; a session that
           ;; has cd'd out keeps its last-known labels rather than going blank.
           (when (plist-get info :repo-root)
             (dolist (field '(:repo :repo-root :worktree :worktree-name
                              :branch :worktree-path))
               (plist-put session field (plist-get info field)))
             (puthash id session rsr/agent-sessions))))))
   rsr/agent-sessions))

(defun rsr/agent-sessions-refresh ()
  "Refresh the dashboard, re-reading git worktrees and branches from disk.
Unlike the internal re-render used by hooks and the sort toggle, this
invalidates the worktree cache and re-reads each session's repo/branch info."
  (interactive)
  (clrhash rsr/agent-sessions--worktrees-cache)
  (clrhash rsr/agent-sessions--tmux-home-cache)
  (when (boundp 'rsr/agent-tmux--session-paths)
    (clrhash rsr/agent-tmux--session-paths))
  (rsr/agent-sessions--reread-repo-info)
  (rsr/agent-sessions--refresh))

(defun rsr/agent-sessions--refresh-if-visible ()
  (let ((buf (get-buffer rsr/agent-sessions-buffer-name)))
    (when buf
      (with-current-buffer buf
        (rsr/agent-sessions--refresh)))))

(defun rsr/agent-sessions--on-screen-buffers ()
  "Buffers in a window of a visible frame, with the proxies tmux terminals show.
A tmux agent's row is keyed by its proxy, which is never itself on screen:
*tmux: S* standing for whichever window its client shows."
  (let ((shown (delete-dups (mapcar #'window-buffer
                                    (window-list-1 nil 'nomini 'visible)))))
    (append shown (rsr/agent-tmux-shown-proxies shown))))

(defun rsr/agent-sessions--mark-on-screen (dashboard)
  "Mark DASHBOARD's rows whose terminals are on screen, unmarking the rest.
Overlays over the rows the last render drew (`rsr/agent-sessions--row-buffers'),
so the mark moves without drawing the dashboard again.  The glyph replaces
the row's first indent column; the background covers the row's whole section,
its files, links and note included, and is left off a row whose status has a
background of its own."
  (with-current-buffer dashboard
    (remove-overlays (point-min) (point-max) 'rsr/agent-sessions-on-screen t)
    (when-let ((shown (and rsr/agent-sessions--row-buffers
                           (rsr/agent-sessions--on-screen-buffers))))
      (pcase-dolist (`(,pos . ,buf) rsr/agent-sessions--row-buffers)
        (when (and buf (memq buf shown) (eq (char-after pos) ?\s))
          (let ((glyph (make-overlay pos (1+ pos))))
            (overlay-put glyph 'rsr/agent-sessions-on-screen t)
            (overlay-put glyph 'display
                         (propertize rsr/agent-sessions-on-screen-glyph
                                     'face 'rsr/agent-session-on-screen-glyph)))
          (when (eq (rsr/agent-sessions--face-for
                     (cdr (assq pos rsr/agent-sessions--row-status)))
                    'default)
            ;; The whole section: its files, links and note belong to it.
            (let ((row (make-overlay pos (if-let ((section (get-text-property
                                                            pos 'magit-section)))
                                             (oref section end)
                                           (save-excursion
                                             (goto-char pos)
                                             (min (1+ (line-end-position))
                                                  (point-max)))))))
              (overlay-put row 'rsr/agent-sessions-on-screen t)
              (overlay-put row 'face 'rsr/agent-session-on-screen))))))))

(defvar rsr/agent-sessions--on-screen-timer nil
  "The pending `rsr/agent-sessions--mark-on-screen-soon' update, if any.")

(defun rsr/agent-sessions--mark-on-screen-soon (&rest _)
  "Move the dashboard's on-screen mark shortly, once for a burst of changes.
For `window-buffer-change-functions', which runs at every buffer switch in
any window, and `window-configuration-change-hook', the one that also runs
when a window is closed: nothing is scheduled unless the dashboard is on screen, and the
update reads the windows when it runs, so one serves the whole burst.  A
window change is when a tmux client moves, so the update asks tmux afresh
rather than trusting the snapshot renders share."
  (let ((dashboard (get-buffer rsr/agent-sessions-buffer-name)))
    (when (and dashboard
               (not rsr/agent-sessions--on-screen-timer)
               (get-buffer-window dashboard 'visible))
      ;; DASHBOARD goes to the timer as an argument: this file is dynamically
      ;; bound, so a lambda would no longer see it when the timer fires.
      (setq rsr/agent-sessions--on-screen-timer
            (run-at-time 0.1 nil #'rsr/agent-sessions--mark-on-screen-now
                         dashboard)))))

(defun rsr/agent-sessions--mark-on-screen-now (dashboard)
  "The update `rsr/agent-sessions--mark-on-screen-soon' schedules."
  (setq rsr/agent-sessions--on-screen-timer nil)
  (rsr/agent-tmux-forget-clients)
  (when (buffer-live-p dashboard)
    (rsr/agent-sessions--mark-on-screen dashboard)))

(defun rsr/agent-sessions--session-at-point ()
  (let ((section (magit-current-section)))
    (and section (eq (oref section type) 'rsr/agent-session-row)
         (rsr/agent-sessions--session-for-id (oref section value)))))

(defun rsr/agent-sessions--switch-project-read-command ()
  "Read one key from the `project-switch-commands' menu and return its command.
Returns `ignore' for anything unrecognised, so the menu closes instead of
re-prompting.  Built from project.el's own pieces (`project-prefix-map',
`project-switch-commands', `project--menu-prompt') so a user's customisation
of the dispatch menu still applies; the deprecated (KEY COMMAND LABEL) row
format is normalised the same way `project--switch-project-command' does.
Emacs 29 calls the prompt builder `project--keymap-prompt'; Emacs 30 renamed
it, so whichever this Emacs has is used."
  (let* ((menu (mapcar (lambda (row) (if (characterp (car row)) (reverse row) row))
                       project-switch-commands))
         (map (let ((temp (make-sparse-keymap)))
                (set-keymap-parent temp project-prefix-map)
                (dolist (row menu temp)
                  (when-let ((cmd (nth 0 row))
                             (keychar (nth 2 row)))
                    (define-key temp (vector keychar) cmd)))))
         (choice (let ((overriding-local-map map))
                   (read-key-sequence
                    (concat "Choose: "
                            (if (fboundp 'project--menu-prompt)
                                (project--menu-prompt)
                              (project--keymap-prompt))))))
         (command (lookup-key map choice)))
    (message nil)
    (if (and (commandp command)
             (or project-switch-use-entire-map (assq command menu)))
        command
      #'ignore)))

(defun rsr/agent-sessions--switch-project (dir)
  "`project-switch-project' in DIR, but dismissed by any unrecognised key.
`project--switch-project-command' loops until it reads a key it knows, so the
dispatch menu behaves like a mode you have to escape from.  Here RET on a
heading is a glance at what's available, so a stray key should just close the
menu rather than trap you in it.  The override is scoped to this call — the
looping behaviour everywhere else in Emacs is left alone."
  (cl-letf (((symbol-function 'project--switch-project-command)
             #'rsr/agent-sessions--switch-project-read-command))
    (project-switch-project dir)))

(defun rsr/agent-sessions-jump ()
  "Act on the thing at point.
On a session row, pop to its terminal.  Open a shared file or external link
and clear its highlight; a Linear link jumps to its issue's heading in
`rsr/agent-sessions-linear-org-file', or opens in the Linear app when the
issue is not there.  On a worktree or repo heading, open project.el's
dispatch menu in that directory (see `rsr/agent-sessions--switch-project').
With more than one window beside the dashboard, ace-window asks which one to
replace; see `rsr/agent-sessions--display-buffer-ace-if-several'."
  (interactive)
  (let ((display-buffer-overriding-action
         '(rsr/agent-sessions--display-buffer-ace-if-several)))
    (rsr/agent-sessions--jump)))

(defun rsr/agent-sessions--jump ()
  "The body of `rsr/agent-sessions-jump', in whatever window `display-buffer' picks."
  (cond
   ((rsr/agent-sessions--link-at-point)
    (rsr/agent-sessions--open-link-at-point
     (lambda (url)
       (rsr/agent-sessions--show-linear-heading
        url #'rsr/agent-sessions--pop-to-other-window))))
   ((rsr/agent-sessions--file-at-point)
    (rsr/agent-sessions--open-file-at-point
     #'rsr/agent-sessions--pop-to-other-window))
   (t
    (let ((section (magit-current-section)))
      (pcase (and section (oref section type))
        ('rsr/agent-session-row
         (let* ((session (rsr/agent-sessions--session-for-id (oref section value)))
                (buf (and session (plist-get session :buffer))))
           (if (buffer-live-p buf)
               (rsr/agent-sessions--show-terminal buf)
             (message "No session at point."))))
        ('rsr/agent-session-repo
         (let* ((value (oref section value))
                (dir (plist-get value :root)))
           (if (and dir (file-directory-p dir))
               (rsr/agent-sessions--switch-project dir)
             (message "No worktree directory at point."))))
        (_ (message "Nothing to do here.")))))))

(defun rsr/agent-sessions-display ()
  "Display or open the session attachment at point without selecting a terminal.
Files, sessions and a Linear link's Org heading use another window; other
external links open in the browser."
  (interactive)
  (cond
   ((rsr/agent-sessions--link-at-point)
    (rsr/agent-sessions--open-link-at-point
     (lambda (url)
       (rsr/agent-sessions--show-linear-heading
        url
        (lambda (buf) (display-buffer buf rsr/agent-tmux-other-window-action))))))
   ((rsr/agent-sessions--file-at-point)
    (rsr/agent-sessions--open-file-at-point
     (lambda (buf) (display-buffer buf rsr/agent-tmux-other-window-action))))
   (t
    (let* ((session (rsr/agent-sessions--session-at-point))
           (buf (and session (plist-get session :buffer))))
      (if (buffer-live-p buf)
          (rsr/agent-sessions--show-terminal buf t)
        (message "No session at point."))))))

(defun rsr/agent-sessions--show-terminal (buf &optional display)
  "Select session terminal BUF, or with DISPLAY only show it in another window.
A tmux proxy has no screen of its own: show its session's buffer with its
window selected, and count that as looking at the session.  Switching the
window of a *tmux: S* already on screen changes no Emacs window, so the
on-screen mark is moved here as well."
  (prog1
      (if (rsr/agent-tmux-proxy-p buf)
          (progn
            (rsr/agent-tmux-show-proxy buf display)
            (rsr/agent-session--clear-attention buf))
        (if display
            (display-buffer buf rsr/agent-tmux-other-window-action)
          (rsr/agent-sessions--pop-to-other-window buf)))
    (rsr/agent-sessions--mark-on-screen-soon)))

(defun rsr/agent-sessions--last-agent-buffer ()
  "The agent viewed before the one in front of the user, or nil.
Agents are the live buffers of `rsr/agent-sessions' entries, so plain shells
never count; recency is their `rsr/agent-session--viewed-at' stamp.  The newest is
skipped only when it is the agent in front, which the focus hook records in
`rsr/agent-sessions--last-focused-buffer' (for a *tmux: S*, the proxy of its
current window); a shell or other buffer in front skips nothing."
  (let* ((agents (delete-dups
                  (seq-filter #'buffer-live-p
                              (mapcar (lambda (session) (plist-get session :buffer))
                                      (hash-table-values rsr/agent-sessions)))))
         (viewed (sort (seq-filter (lambda (buf)
                                     (buffer-local-value 'rsr/agent-session--viewed-at buf))
                                   agents)
                       (lambda (a b)
                         (time-less-p (buffer-local-value 'rsr/agent-session--viewed-at b)
                                      (buffer-local-value 'rsr/agent-session--viewed-at a))))))
    (if (eq (car viewed) rsr/agent-sessions--last-focused-buffer)
        (cadr viewed)
      (car viewed))))

(defun rsr/agent-sessions-visit-last-agent ()
  "Show the agent viewed before the current one; again to toggle back.
Unlike `previous-buffer' this goes by agent, not Emacs buffer: agents of one
repository share a *tmux: S* buffer.  The agent replaces the selected window,
see `rsr/agent-sessions--display-buffer-here'."
  (interactive)
  (if-let ((buf (rsr/agent-sessions--last-agent-buffer)))
      (let ((display-buffer-overriding-action '(rsr/agent-sessions--display-buffer-here)))
        (rsr/agent-sessions--show-terminal buf))
    (message "No previous agent session")))

(defun rsr/agent-sessions--pop-to-other-window (buf)
  "Select BUF in another window, reusing one rather than splitting.
See `rsr/agent-tmux-other-window-action'."
  (pop-to-buffer buf rsr/agent-tmux-other-window-action))

(declare-function aw-select "ace-window")
(declare-function aw-window-list "ace-window")
(declare-function aw-split-window-fair "ace-window")
(defvar aw-ignored-buffers)
(defvar aw-ignore-on)

(defun rsr/agent-sessions--ace-pick (&optional split-lone)
  "A window picked with ace-window; the dashboard is never offered.
ace-window's dispatch keys still apply, so `b' then a letter splits that
window side by side (`v' one above the other) and returns the new half.
With one window to choose from there is no choice to make: split it when
SPLIT-LONE, else return nil, as also without ace-window installed.
Quitting the picker quits the command, rather than letting `display-buffer'
fall back to another window."
  (when (require 'ace-window nil t)
    (let* ((aw-ignore-on t)
           (aw-ignored-buffers (cons rsr/agent-sessions-buffer-name aw-ignored-buffers))
           (candidates (aw-window-list)))
      (cond
       ((cdr candidates)
        (let ((window (aw-select " Ace - Open" #'identity)))
          (if (window-live-p window) window (signal 'quit nil))))
       ((and candidates split-lone)
        (aw-split-window-fair (car candidates)))))))

(defun rsr/agent-sessions--display-buffer-ace-if-several (buffer alist)
  "`display-buffer' action for RET: ask with ace-window only given a choice.
A BUFFER already on screen, or a single window beside the dashboard, returns
nil, so the caller's action reuses that window without asking."
  (unless (get-buffer-window buffer)
    (let ((before (window-list)))
      (when-let ((window (rsr/agent-sessions--ace-pick)))
        (window--display-buffer buffer window
                                (if (memq window before) 'reuse 'window)
                                alist)))))

(defun rsr/agent-sessions--display-buffer-here (buffer alist)
  "`display-buffer' action for `C-c i l': BUFFER in the selected window.
It replaces that window's buffer, as `previous-buffer' would.  A BUFFER
already on screen keeps its window, since a second copy of the same terminal
is no use.  From a side, dedicated or minibuffer window (the dashboard)
return nil, so the caller's action picks a window instead."
  (let* ((selected (selected-window))
         (window (or (get-buffer-window buffer)
                     (and (not (window-parameter selected 'window-side))
                          (not (window-dedicated-p selected))
                          (not (window-minibuffer-p selected))
                          selected))))
    (when window
      (window--display-buffer buffer window 'reuse alist))))

(defun rsr/agent-sessions--display-buffer-in-ace-window (buffer alist)
  "`display-buffer' action for `o': show BUFFER in a window picked with ace-window.
Unlike RET it asks even between two windows, and a single window beside the
dashboard is split rather than replaced.  A window split for BUFFER is
deleted again by `q'.  A BUFFER already on screen returns nil, so the
caller's action selects it: a second copy of the same terminal is no use."
  (unless (get-buffer-window buffer)
    (let* ((before (window-list))
           (window (rsr/agent-sessions--ace-pick t)))
      (when window
        (window--display-buffer buffer window
                                (if (memq window before) 'reuse 'window)
                                alist)))))

(defun rsr/agent-sessions-jump-other-window ()
  "Like `rsr/agent-sessions-jump', but always in a window picked with ace-window.
RET replaces the only window beside the dashboard; this splits it instead, so
two sessions or a session and its file can sit side by side.  See
`rsr/agent-sessions--display-buffer-in-ace-window'.  A tmux agent whose
session's terminal is on screen showing another agent gets a terminal of its
own (`rsr/agent-tmux-own-view'), so both stay in view."
  (interactive)
  (let ((display-buffer-overriding-action
         '(rsr/agent-sessions--display-buffer-in-ace-window))
        (rsr/agent-tmux-own-view t))
    (rsr/agent-sessions--jump)))

(defun rsr/agent-sessions-display-or-browse ()
  "Display the thing at point, browsing links and shared HTML files.
A Linear link always opens in `rsr/agent-sessions-linear-app'.  For every
other shared file or dashboard row, behave exactly like
`rsr/agent-sessions-display'."
  (interactive)
  (if (rsr/agent-sessions--link-at-point)
      (rsr/agent-sessions--open-link-at-point
       #'rsr/agent-sessions--open-linear-app)
    (pcase (rsr/agent-sessions--file-at-point)
      (`(,_session ,path ,_file)
       (if (not (string-equal (downcase (or (file-name-extension path) ""))
                              "html"))
           (rsr/agent-sessions-display)
         (if (not (file-exists-p path))
             (message "File no longer exists: %s" (abbreviate-file-name path))
           (when (rsr/agent-sessions--set-visited
                  (lambda (file) (equal (plist-get file :path) path)) t)
             (rsr/agent-sessions--refresh-if-visible))
           (browse-url-of-file path))))
      (_ (rsr/agent-sessions-display)))))

(defun rsr/agent-sessions-copy-attachment ()
  "Copy the shared file path or external URL at point to the kill ring."
  (interactive)
  (let ((value (or (when-let ((link (rsr/agent-sessions--link-at-point)))
                     (plist-get (nth 2 link) :url))
                   (nth 1 (rsr/agent-sessions--file-at-point)))))
    (if value
        (progn
          (kill-new value)
          (message "Copied %s" value))
      (message "No shared file or link at point."))))

(defun rsr/agent-sessions--row-locations ()
  "Return (POSITION . ID) for each session row, in buffer order."
  (let (rows last-start)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((section (magit-current-section)))
          (when (and section
                     (eq (oref section type) 'rsr/agent-session-row)
                     (/= (oref section start) (or last-start -1)))
            (setq last-start (oref section start))
            (push (cons last-start (oref section value)) rows)))
        (forward-line 1)))
    (nreverse rows)))

(defun rsr/agent-sessions--nearby-session-id ()
  "Return the id of a session row next to the row at point.
Prefer the following row; when point is on the final row, return the previous
one.  Return nil when point is not on a session row or no other row exists."
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'rsr/agent-session-row))
      (let* ((start (oref section start))
             (rows (rsr/agent-sessions--row-locations))
             (next (seq-find (lambda (row) (> (car row) start)) rows))
             (previous (seq-find (lambda (row) (< (car row) start))
                                 (reverse rows))))
        (cdr (or next previous))))))

(defun rsr/agent-sessions--goto-session-id (id)
  "Move point to the dashboard row for session ID and return non-nil.
Return nil without moving point when ID is no longer displayed."
  (let ((row (seq-find (lambda (candidate) (equal (cdr candidate) id))
                       (rsr/agent-sessions--row-locations))))
    (when row
      (goto-char (car row))
      t)))

(defun rsr/agent-sessions--neighbour-ident (section)
  "Return the ident of the section to put point on once SECTION is gone.
The next sibling of the same type, else the previous one, else the parent — so
detaching a file lands on the next file, the last remaining file, or the
session they hang off, never back at the top of the buffer.

An *ident* rather than a position or a section object because the buffer is
erased and rebuilt in between, which is the same reason
`rsr/agent-sessions--refresh' restores point by ident; and the reason this is
needed at all is that the refresh's own restoration cannot help here — the
section point was on is precisely the one that no longer exists."
  (when-let* ((parent (and section (oref section parent)))
              (type (oref section type))
              (siblings (seq-filter (lambda (c) (eq (oref c type) type))
                                    (oref parent children)))
              (pos (seq-position siblings section)))
    (magit-section-ident (or (nth (1+ pos) siblings)
                             (and (> pos 0) (nth (1- pos) siblings))
                             parent))))

(defun rsr/agent-sessions--goto-ident (ident)
  "Move point to the section identified by IDENT, if it is still displayed."
  (when-let ((target (and ident (magit-get-section ident))))
    (goto-char (oref target start))
    t))

(defun rsr/agent-sessions--next-file-ident-at-point ()
  "Return the next shared-file section's identity within this session.
Return nil on the last file.  Point may be inside a file's note."
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'rsr/agent-session-note))
      (setq section (oref section parent)))
    (when (and section (eq (oref section type) 'rsr/agent-session-file))
      (let* ((siblings (seq-filter
                        (lambda (child)
                          (eq (oref child type) 'rsr/agent-session-file))
                        (oref (oref section parent) children)))
             (next (nth (1+ (seq-position siblings section)) siblings)))
        (and next (magit-section-ident next))))))

(defun rsr/agent-sessions-kill ()
  "Kill the session at point, or detach its shared file or link.
Detaching drops only the dashboard pointer; files on disk and external targets
are untouched."
  (interactive)
  (pcase (rsr/agent-sessions--link-at-point)
    (`(,session ,url ,link)
     (let ((ident (rsr/agent-sessions--neighbour-ident
                   (rsr/agent-sessions--enclosing-section
                    'rsr/agent-session-link))))
       (if (rsr/agent-sessions--detach-link session url)
           (progn
             (rsr/agent-sessions--refresh)
             (rsr/agent-sessions--goto-ident ident)
             (message "Detached %s link."
                      (or (plist-get link :label) (plist-get link :url))))
         (message "Not attached to this session."))))
    (_
     (pcase (rsr/agent-sessions--file-at-point)
       (`(,session ,path ,_file)
        ;; Resolve the neighbour *before* detaching, while the row is still on
        ;; screen to have neighbours at all.
        (let ((ident (rsr/agent-sessions--neighbour-ident
                      (rsr/agent-sessions--enclosing-section
                       'rsr/agent-session-file))))
          (if (rsr/agent-sessions--detach-file session path)
              (progn
                (rsr/agent-sessions--refresh)
                (rsr/agent-sessions--goto-ident ident)
                (message "Detached %s (the file on disk is untouched)."
                         (file-name-nondirectory (directory-file-name path))))
            (message "Not attached to this session."))))
       (_ (rsr/agent-sessions--kill-session))))))

(defun rsr/agent-sessions--kill-session ()
  "Kill the session at point and move to a neighboring session row."
  (let* ((session (rsr/agent-sessions--session-at-point))
         (buf (and session (plist-get session :buffer)))
         (nearby-id (and (buffer-live-p buf)
                         (rsr/agent-sessions--nearby-session-id))))
    (if (not (buffer-live-p buf))
        (message "No session at point.")
      (when (kill-buffer buf)
        ;; The terminal's kill-buffer hook refreshes the dashboard once, but
        ;; the deleted section cannot be restored and that refresh lands at
        ;; point-min.  Re-render defensively (for terminals without the hook),
        ;; then select the adjacent surviving row by its stable session id.
        (rsr/agent-sessions--refresh)
        (when nearby-id
          (rsr/agent-sessions--goto-session-id nearby-id))))))

(defun rsr/agent-sessions-mark-unread (&optional unmark)
  "Mark the session at point as unread — i.e. needing attention.
Gives the row the same highlight, `●' marker, sort priority and `N'/`P'
reachability a hook-reported needs-attention has, for sessions you want to
come back to yourself.  With a prefix argument (UNMARK), clear the mark.
The mark also clears on its own once you focus the session's buffer.

On a shared-file or external-link row this toggles the unopened highlight
instead.  After marking an unread file read, move to the next file in the
same session if there is one.  UNMARK always clears."
  (interactive "P")
  (pcase (rsr/agent-sessions--link-at-point)
    (`(,_session ,_kind ,link)
     (let ((visited (or (and unmark t) (null (plist-get link :visited-at))))
           (url (plist-get link :url)))
       (rsr/agent-sessions--set-link-visited
        (lambda (candidate) (equal (plist-get candidate :url) url)) visited)
       (rsr/agent-sessions--refresh)
       (message (if visited "Marked as read." "Marked as unread."))))
    (_
     (pcase (rsr/agent-sessions--file-at-point)
       (`(,_session ,path ,file)
        (let ((visited (or (and unmark t)
                           (null (plist-get file :visited-at))))
              (next-ident (rsr/agent-sessions--next-file-ident-at-point)))
          (let ((changed (rsr/agent-sessions--set-visited
                          (lambda (f) (equal (plist-get f :path) path))
                          visited)))
            (rsr/agent-sessions--refresh)
            (when (and changed visited next-ident)
              (rsr/agent-sessions--goto-ident next-ident)))
          (message (if visited "Marked as read." "Marked as unread."))))
       (_ (rsr/agent-sessions--mark-session-unread unmark))))))

(defun rsr/agent-sessions--mark-session-unread (unmark)
  "Set or clear the unread mark on the session row at point."
  (let* ((session (rsr/agent-sessions--session-at-point))
         (buf (and session (plist-get session :buffer))))
    (if (not (buffer-live-p buf))
        (message "No session at point.")
      (with-current-buffer buf
        (setq-local rsr/agent-session--marked-unread (not unmark)))
      (rsr/agent-sessions--refresh)
      (message (if unmark "Unread mark cleared." "Marked as needing attention.")))))

(defun rsr/agent-sessions-branch ()
  "Branch (fork) the agent session at point into a new session.
Opens a new terminal in the same worktree and forks the conversation, so the
new session shares its parent's history but gets its own session id
\(`claude --fork-session' / `codex fork').  The new session is tagged as
branched from the one at point, shown as `↳ from …' in the dashboard."
  (interactive)
  (let* ((session (rsr/agent-sessions--session-at-point))
         (agent (and session (plist-get session :agent-type)))
         (sid (and session (plist-get session :agent-session-id)))
         (path (and session
                    (or (plist-get session :worktree-path)
                        (let ((buf (plist-get session :buffer)))
                          (and (buffer-live-p buf)
                               (buffer-local-value 'default-directory buf)))))))
    (cond
     ((null session) (message "No session at point."))
     ((null sid) (message "Session at point has no resumable session id yet."))
     ((null path) (message "Session at point has no worktree to branch in."))
     (t (rsr/agent-session--spawn
         path agent sid rsr/agent-session-branch-commands
         (cons sid (rsr/agent-sessions--session-short-label session)))))))

(defun rsr/agent-sessions-mark-parent ()
  "Record that the session at point was branched from another session.
Prompts for the parent among the live sessions.  Use this to track a fork you
made outside the `b' command (e.g. running `claude --resume … --fork-session'
or `codex fork' by hand)."
  (interactive)
  (let* ((section (magit-current-section))
         (id (and section (eq (oref section type) 'rsr/agent-session-row)
                  (oref section value)))
         (session (and id (rsr/agent-sessions--session-for-id id))))
    (if (null session)
        (message "Point is not on a session row.")
      (let* ((self-sid (plist-get session :agent-session-id))
             (cands
              (delq nil
                    (mapcar (lambda (e)
                              (let ((es (plist-get e :session)))
                                ;; Exclude the target itself and any terminal
                                ;; running the *same* session (same conversation
                                ;; can't be its own parent — that would cycle).
                                (unless (or (equal (plist-get e :id) id)
                                            (and self-sid
                                                 (equal (plist-get es :agent-session-id)
                                                        self-sid)))
                                  (cons (rsr/agent-sessions--session-label es) es))))
                            (rsr/agent-sessions--live-entries))))
             (choice (and cands
                          (completing-read "Branched from: "
                                           (mapcar #'car cands) nil t)))
             (parent (and choice (cdr (assoc choice cands)))))
        (cond
         ((null cands) (message "No other sessions to branch from."))
         ((null parent) (message "No parent selected."))
         (t
          (let ((bf (cons (plist-get parent :agent-session-id)
                          (rsr/agent-sessions--session-short-label parent)))
                (buf (plist-get session :buffer))
                (real (gethash id rsr/agent-sessions)))
            ;; Set on the buffer so it survives future hook rebuilds, and on the
            ;; live registry entry (if any) so it shows immediately.
            (when (buffer-live-p buf)
              (with-current-buffer buf
                (setq-local rsr/agent-session--branched-from bf)))
            (when real
              (puthash id (plist-put real :branched-from bf) rsr/agent-sessions))
            (rsr/agent-sessions--refresh)
            (message "Marked as branched from %s" (cdr bf)))))))))

(defun rsr/agent-sessions-detach-parent ()
  "Detach the child session at point from its recorded fork parent."
  (interactive)
  (let* ((session (rsr/agent-sessions--session-at-point))
         (parent (and session (plist-get session :branched-from)))
         (buf (and session (plist-get session :buffer)))
         (id (and (buffer-live-p buf)
                  (buffer-local-value 'rsr/agent-session-id buf)))
         (real (and id (gethash id rsr/agent-sessions))))
    (cond
     ((null session) (message "Point is not on a session row."))
     ((null parent) (message "Session is not attached to a parent."))
     ((not (buffer-live-p buf)) (message "Session has no live buffer."))
     (t
      (with-current-buffer buf
        (setq-local rsr/agent-session--branched-from nil)
        (setq-local rsr/agent-session--parent-detached-p t))
      (when real
        (puthash id (plist-put (copy-sequence real) :branched-from nil)
                 rsr/agent-sessions))
      (rsr/agent-sessions--refresh)
      (message "Detached from %s." (cdr parent))))))

(defun rsr/agent-sessions-submission-diff-or-detach-parent ()
  "Diff submitted file versions at point, or detach a session's fork parent.
This keeps `D' contextual: file rows use the submitted-version history, while
the existing session-row action remains available on every other row."
  (interactive)
  (if (rsr/agent-sessions--file-at-point)
      (rsr/agent-sessions-show-file-submission-diff)
    (rsr/agent-sessions-detach-parent)))

(defun rsr/agent-sessions-edit-title ()
  "Edit the title of the session at point.
The chosen title is stored as a user override on the session's buffer, so it
takes precedence over — and survives — the agent's own OSC title updates.
Clearing it (entering an empty string) restores the agent's live title."
  (interactive)
  (let* ((session (rsr/agent-sessions--session-at-point))
         (buf (and session (plist-get session :buffer))))
    (if (not (buffer-live-p buf))
        (message "No session at point.")
      (let* ((initial (with-current-buffer buf
                        (or rsr/agent-session-title-override
                            rsr/agent-session-title)))
             (new (string-trim (read-string "Session title: " initial))))
        (with-current-buffer buf
          (setq-local rsr/agent-session-title-override
                      (unless (string-empty-p new) new)))
        (rsr/agent-sessions--log-title buf)
        (rsr/agent-sessions--refresh)
        (message (if (string-empty-p new)
                     "Title override cleared."
                   (format "Title set to %s" new)))))))

(defun rsr/agent-sessions-cycle-state ()
  "Move the session at point to the next workflow state.
Cycles through `rsr/agent-sessions-states' and off the end back to no state.
With a prefix argument, pick a state directly instead — with this many of
them, a cycle is a poor way to reach a particular one."
  (interactive)
  (let* ((session (rsr/agent-sessions--session-at-point))
         (keys (and session (rsr/agent-sessions--session-note-keys session))))
    (if (not keys)
        (message "No session at point.")
      (let* ((current (rsr/agent-sessions--session-state session))
             (new (if current-prefix-arg
                      (let ((choice (completing-read
                                     "State (empty to clear): "
                                     rsr/agent-sessions-states nil t)))
                        (and (not (string-empty-p choice)) choice))
                    (rsr/agent-sessions--next-state current))))
        (rsr/agent-sessions--state-set keys new)
        (rsr/agent-sessions--refresh)
        (message (if new
                     (format "State: %s" new)
                   "State cleared."))))))

(defun rsr/agent-sessions--context-at-point ()
  "Return (:path DIR :name NAME) for the session or repo at point."
  (let ((section (magit-current-section)))
    (catch 'found
      (while section
        (let ((value (oref section value)))
          (pcase (oref section type)
            ('rsr/agent-session-row
             (when-let* ((session (rsr/agent-sessions--session-for-id value))
                         (path (plist-get session :worktree-path)))
               (throw 'found (list :path path
                                   :name (plist-get session :worktree)))))
            ('rsr/agent-session-repo
             (throw 'found (list :path (plist-get value :root)
                                 :name (plist-get value :name))))))
        (setq section (oref section parent)))
      nil)))

;; Shared by `F' and `+', so moving a session and placing a new one offer the
;; same choices.
(defun rsr/agent-sessions--folder-occupancy (folders)
  "Return an alist of FOLDERS' names to their live session counts."
  (let ((entries (rsr/agent-sessions--live-entries)))
    (mapcar (lambda (folder)
              (cons (plist-get folder :name)
                    (length (rsr/agent-sessions--folder-entries folder entries))))
            folders)))

(defun rsr/agent-sessions--folder-annotation (occupancy)
  "Return a completion annotation function reading counts from OCCUPANCY.
`apply-partially', not a `lambda': this file is dynamically bound, so a lambda
would not keep OCCUPANCY once this returns, and the minibuffer calls it later."
  (apply-partially #'rsr/agent-sessions--folder-annotate occupancy))

(defun rsr/agent-sessions--folder-annotate (occupancy name)
  "The annotation for folder NAME: its live session count from OCCUPANCY."
  (when-let ((cell (assoc name occupancy)))
    (propertize (pcase (cdr cell)
                  (0 "  empty")
                  (1 "  1 session")
                  (n (format "  %d sessions" n)))
                'face 'completions-annotations)))

(defun rsr/agent-sessions--read-folder (repo prompt)
  "Read one of REPO's folders with PROMPT; return it, or nil for \"No folder\".
A name matching no folder creates one in REPO.  Each folder is annotated with
its live session count, `empty' for none, as the dashboard hides those."
  (let* ((folders (rsr/agent-sessions--folders-for-repo repo))
         (completion-extra-properties
          (list :annotation-function
                (rsr/agent-sessions--folder-annotation
                 (rsr/agent-sessions--folder-occupancy folders))))
         (choice (completing-read
                  prompt
                  (append (mapcar (lambda (item) (plist-get item :name)) folders)
                          '("No folder")))))
    (cond ((string-equal-ignore-case choice "No folder") nil)
          ((string-empty-p (string-trim choice))
           (user-error "Enter a folder name"))
          (t (or (seq-find (lambda (item)
                             (string-equal-ignore-case choice (plist-get item :name)))
                           folders)
                 (rsr/agent-sessions--folder-create choice repo))))))

(defconst rsr/agent-sessions--new-folder-candidate "+ New folder"
  "The first entry of a repo's folder list, which creates a folder.")

(defvar rsr/agent-sessions-folder-list-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-k") #'rsr/agent-sessions-folder-list-delete)
    map)
  "Keys added to the minibuffer while a repo's folder list is open.")

(defun rsr/agent-sessions-folder-list-delete ()
  "Leave the folder list to delete the folder highlighted in it."
  (interactive)
  (throw 'rsr/agent-sessions--folder-list
         (cons 'delete (if (fboundp 'vertico--candidate)
                           (vertico--candidate)
                         (minibuffer-contents)))))

(defun rsr/agent-sessions--folder-list-read (repo-name folders)
  "Show REPO-NAME's FOLDERS with a new-folder entry first; return the choice.
The value is (select . NAME) for RET and (delete . NAME) for \\<rsr/agent-sessions-folder-list-map>\\[rsr/agent-sessions-folder-list-delete].
Folders no live session is in are dimmed, since the dashboard hides them."
  (let* ((occupancy (rsr/agent-sessions--folder-occupancy folders))
         (candidates
          (cons rsr/agent-sessions--new-folder-candidate
                (mapcar (lambda (cell)
                          (if (zerop (cdr cell))
                              (propertize (car cell) 'face 'shadow)
                            (car cell)))
                        occupancy)))
         (completion-extra-properties
          (list :annotation-function
                (rsr/agent-sessions--folder-annotation occupancy)
                :display-sort-function #'identity
                :cycle-sort-function #'identity)))
    (catch 'rsr/agent-sessions--folder-list
      (minibuffer-with-setup-hook
          (lambda ()
            (use-local-map (make-composed-keymap rsr/agent-sessions-folder-list-map
                                                 (current-local-map))))
        (cons 'select
              (completing-read
               (format "Folders of %s (%s delete): " repo-name
                       (substitute-command-keys
                        "\\<rsr/agent-sessions-folder-list-map>\\[rsr/agent-sessions-folder-list-delete]"))
               candidates nil t))))))

(defun rsr/agent-sessions--folder-list (repo repo-name)
  "Manage REPO's folders from one list: create one, or rename and delete them.
The list shows every folder, the empty ones dimmed; deleting returns to it so
several can be cleaned up in a row.  Return non-nil when anything changed."
  (let (changed done)
    (while (not done)
      (let* ((folders (sort (copy-sequence (rsr/agent-sessions--folders-for-repo repo))
                            (lambda (a b)
                              (string-lessp (plist-get a :name)
                                            (plist-get b :name)))))
             (choice (rsr/agent-sessions--folder-list-read repo-name folders))
             (name (substring-no-properties (or (cdr choice) "")))
             (folder (seq-find (lambda (item)
                                 (string-equal-ignore-case name (plist-get item :name)))
                               folders)))
        (cond
         ((equal name rsr/agent-sessions--new-folder-candidate)
          (if (eq (car choice) 'delete)
              (message "Highlight a folder to delete")
            (rsr/agent-sessions--folder-create (read-string "New folder name: ") repo)
            (setq changed t done t)))
         ((null folder)
          (when (eq (car choice) 'select) (setq done t)))
         ((eq (car choice) 'delete)
          (when (rsr/agent-sessions--folder-confirm-delete folder)
            (setq changed t)
            (unless (rsr/agent-sessions--folders-for-repo repo) (setq done t))))
         (t
          (pcase (completing-read (format "%s: " (plist-get folder :name))
                                  '("Rename folder" "Delete folder") nil t)
            ("Rename folder"
             (rsr/agent-sessions--folder-rename
              folder (read-string "Folder name: " (plist-get folder :name)))
             (setq changed t done t))
            ("Delete folder"
             (when (rsr/agent-sessions--folder-confirm-delete folder)
               (setq changed t)
               (unless (rsr/agent-sessions--folders-for-repo repo)
                 (setq done t)))))))))
    changed))

(defun rsr/agent-sessions--folder-confirm-delete (folder)
  "Ask, then delete FOLDER; return non-nil when it was deleted."
  (let ((members (seq-count (lambda (cell) (> (cdr cell) 0))
                            (rsr/agent-sessions--folder-occupancy (list folder)))))
    (when (y-or-n-p
           (format (if (zerop members)
                       "Delete folder %s? "
                     "Delete folder %s and unassign its sessions? ")
                   (plist-get folder :name)))
      (rsr/agent-sessions--folder-delete folder)
      t)))

(defun rsr/agent-sessions-folder-action ()
  "Move the session at point, manage a folder heading, or list a repo's folders.
On a repo heading the list has every folder, the empty ones the dashboard
hides dimmed, with a new-folder entry first; see
`rsr/agent-sessions--folder-list'."
  (interactive)
  (rsr/agent-sessions--load-folders)
  (let* ((row (rsr/agent-sessions--enclosing-section 'rsr/agent-session-row))
         (session (and row (rsr/agent-sessions--session-for-id
                            (oref row value))))
         (section (magit-current-section))
         (repo-section (rsr/agent-sessions--enclosing-section
                        'rsr/agent-session-repo))
         (repo (and repo-section
                    (rsr/agent-sessions--repo-key (oref repo-section value))))
         (folder (and section
                      (eq (oref section type) 'rsr/agent-session-folder)
                      (rsr/agent-sessions--folder (oref section value)))))
    (cond
     (session
      (let* ((row-id (oref row value))
             (nearby (save-excursion
                       (goto-char (oref row start))
                       (rsr/agent-sessions--nearby-session-id)))
             (destination (rsr/agent-sessions--read-folder
                           (rsr/agent-sessions--session-repo session)
                           "Move session to folder: ")))
        (rsr/agent-sessions--folder-set session (plist-get destination :id))
        (rsr/agent-sessions--refresh)
        (or (and nearby (rsr/agent-sessions--goto-session-id nearby))
            (rsr/agent-sessions--goto-session-id row-id))))
     (folder
      (pcase (completing-read
              (format "%s: " (plist-get folder :name))
              '("Rename folder" "Delete folder") nil t)
        ("Rename folder"
         (rsr/agent-sessions--folder-rename
          folder (read-string "Folder name: " (plist-get folder :name)))
         (rsr/agent-sessions--refresh))
        ("Delete folder"
         (when (rsr/agent-sessions--folder-confirm-delete folder)
           (rsr/agent-sessions--refresh)))))
     (t
      (unless repo (user-error "Select a repo to manage its folders"))
      (when (rsr/agent-sessions--folder-list
             repo (plist-get (oref repo-section value) :name))
        (rsr/agent-sessions--refresh))))))

(defun rsr/agent-sessions--terminal-open (dir bufname)
  "Open the configured terminal in DIR in another window; return the buffer.
BUFNAME is the desired buffer name.  Loads the backend package lazily."
  (let ((default-directory (file-name-as-directory dir)))
    (pcase rsr/agent-sessions-terminal
      ('vterm (require 'vterm) (vterm-other-window bufname))
      ('eat (require 'eat)
            (let ((eat-buffer-name bufname))
              ;; arg non-nil, non-number => eat--1 uses `generate-new-buffer'.
              (eat-other-window nil t)))
      ('ghostel (require 'ghostel)
                (ghostel-create bufname rsr/agent-tmux-other-window-action))
      ('tmux (rsr/agent-sessions--tmux-open default-directory bufname))
      (_ (error "Unknown `rsr/agent-sessions-terminal': %S"
                rsr/agent-sessions-terminal)))))

(defun rsr/agent-sessions--tmux-open (dir bufname)
  "Open a window in DIR's tmux session and register a proxy buffer BUFNAME.
The window gets the same environment the other backends inject, so hooks and
`emacs-share' find this session; the proxy carries its dashboard state.  A
session created here starts in the repo's main checkout even when DIR is a
linked worktree: its start directory names the repo it belongs to, and must
outlive the worktree."
  (pcase-let* ((`(,session . ,_root) (rsr/agent-tmux-target dir))
               (options rsr/agent-sessions--tmux-window-options)
               (id (format "%d-%d" (emacs-pid) (cl-incf rsr/agent-session-counter)))
               (home (or (nth 3 (rsr/agent-tmux-checkout dir)) dir))
               (created (rsr/agent-tmux-ensure-session session home))
               (window (and created
                            (rsr/agent-tmux-new-window
                             session dir (rsr/agent-sessions--terminal-environment id)
                             (plist-get options :name)
                             (plist-get options :detached)))))
    ;; A new session's own window is a placeholder; the agent's window replaces
    ;; it, so the session ends with its last agent.
    (when (stringp created)
      (rsr/agent-tmux-kill-window created))
    (unless window
      (error "Could not open a tmux window in session %s" session))
    (rsr/agent-tmux-tag-window window id)
    (rsr/agent-tmux-forget-panes)
    (let ((buf (rsr/agent-tmux-make-proxy bufname session window dir)))
      (puthash id buf rsr/agent-session-id->buffer)
      (with-current-buffer buf
        (setq-local rsr/agent-session-id id)
        (setq-local rsr/agent-session--created-at (current-time))
        (add-hook 'kill-buffer-hook #'rsr/agent-session--cleanup nil t))
      (rsr/agent-sessions--log-open buf)
      ;; Like the other backends, select the new terminal: show the session,
      ;; whose current window `new-window' has just made this one.  A caller
      ;; acting for an agent rather than the user asks for `:silent' instead.
      (unless (plist-get options :silent)
        (rsr/agent-tmux-show session dir))
      (rsr/agent-sessions--refresh-if-visible)
      buf)))

;;;###autoload
(defun rsr/agent-sessions-tmux-reattach ()
  "Give a proxy back to each tmux agent a previous Emacs left running.
Quitting Emacs leaves tmux windows open (no `kill-buffer-hook' runs), and the
log has closed their sessions as `emacs-exit'.  For every window tagged with a
terminal id that this database logged, and whose Emacs is gone, make a proxy
under a fresh id, keep the old id as an alias so the agent's hooks and
`emacs-share' still reach it, and open a new log row carrying the last known
agent identity.  That identity also makes `rsr/agent-sessions-restore-previous'
see the session as live, so it is not started a second time.  Windows of a
still-running Emacs, such as a test bed on the same server, are left alone.
Returns the new proxies."
  (interactive)
  (let ((proxied (mapcar (lambda (b) (buffer-local-value 'rsr/agent-tmux-window b))
                         (rsr/agent-tmux-proxies)))
        adopted)
    (dolist (w (rsr/agent-tmux-agent-windows))
      (let* ((old-id (plist-get w :id))
             (log-id (plist-get w :log-id))
             (row (and (not (member (plist-get w :window) proxied))
                       (not (gethash old-id rsr/agent-session-id->buffer))
                       (not (rsr/agent-sessions--emacs-alive-p log-id))
                       (car (sqlite-select
                             (rsr/agent-sessions--db)
                             "SELECT agent_sid, agent_type, worktree, title
                                FROM sessions WHERE emacs_sid = ?
                               ORDER BY id DESC LIMIT 1"
                             (list log-id))))))
        (when (and row (plist-get w :restored) (car row)
                   (rsr/agent-sessions--buffer-for-agent-session (car row)))
          ;; A window tmux-resurrect restored, for a conversation already
          ;; resumed elsewhere (restored before tmux was): it is a bare shell
          ;; that would only stand beside the agent as a stray.
          (rsr/agent-tmux-kill-window (plist-get w :window))
          (setq row nil))
        (when row
          (pcase-let* ((`(,agent-sid ,agent-type ,worktree ,title) row)
                       (dir (if (and worktree (file-directory-p worktree))
                                worktree
                              (plist-get w :dir)))
                       (id (format "%d-%d" (emacs-pid)
                                   (cl-incf rsr/agent-session-counter)))
                       (buf (rsr/agent-tmux-make-proxy
                             (format "%s-tmux" (file-name-nondirectory
                                                (directory-file-name dir)))
                             (plist-get w :session) (plist-get w :window) dir)))
            (rsr/agent-tmux-tag-window (plist-get w :window) old-id id)
            (puthash id buf rsr/agent-session-id->buffer)
            (puthash old-id buf rsr/agent-session-id->buffer)
            (with-current-buffer buf
              (setq-local rsr/agent-session-id id)
              (setq-local rsr/agent-session--previous-id old-id)
              (setq-local rsr/agent-session--created-at (current-time))
              (setq-local rsr/agent-session-title title)
              (add-hook 'kill-buffer-hook #'rsr/agent-session--cleanup nil t))
            (rsr/agent-sessions--log-open buf)
            (when agent-sid
              (let ((info (rsr/agent-sessions--buffer-repo-info buf)))
                ;; What a hook event would have recorded.  The status is a
                ;; guess until the agent's next event corrects it.
                (puthash id (list :buffer buf
                                  :agent-type agent-type
                                  :agent-session-id agent-sid
                                  :status 'stopped
                                  :last-event "reattach"
                                  :updated-at (current-time)
                                  :repo (plist-get info :repo)
                                  :repo-root (plist-get info :repo-root)
                                  :worktree (plist-get info :worktree)
                                  :worktree-name (plist-get info :worktree-name)
                                  :branch (plist-get info :branch)
                                  :worktree-path (plist-get info :worktree-path))
                         rsr/agent-sessions))
              (rsr/agent-sessions--log-update buf agent-type agent-sid)
              (rsr/agent-sessions--folder-hydrate buf agent-sid)
              (rsr/agent-orchestration--hydrate id))
            (when (plist-get w :restored)
              (rsr/agent-sessions--tmux-resume-restored buf agent-type agent-sid))
            (push buf adopted)))))
    (rsr/agent-tmux-forget-panes)
    (when adopted (rsr/agent-sessions--refresh-if-visible))
    (when (called-interactively-p 'interactive)
      (message "Reattached %d tmux session%s" (length adopted)
               (if (= 1 (length adopted)) "" "s")))
    (nreverse adopted)))

(defun rsr/agent-sessions--tmux-resume-restored (buf agent-type agent-sid)
  "Start the agent again in BUF's window, which tmux-resurrect restored.
The restored shell lacks the environment that lets the agent's hooks reach
Emacs, so it is replaced by one that has it, in the same window; then the
conversation AGENT-SID of AGENT-TYPE, when there is one, is resumed there."
  (with-current-buffer buf
    (let ((window rsr/agent-tmux-window)
          (template (and agent-sid agent-type
                         (alist-get (intern agent-type)
                                    rsr/agent-session-resume-commands))))
      (rsr/agent-tmux-respawn window default-directory
                              (rsr/agent-sessions--terminal-environment
                               rsr/agent-session-id))
      ;; The new shell carries this proxy's id, so the window is tagged with it.
      (rsr/agent-tmux-tag-window window rsr/agent-session-id)
      (rsr/agent-tmux--ok "set-option" "-w" "-u" "-t" window
                          rsr/agent-tmux--restored-option)
      (when template
        (setq-local rsr/agent-session--resuming-session-id agent-sid)
        (rsr/agent-sessions--terminal-send buf (format template agent-sid))))))

(defun rsr/agent-sessions--terminal-send (buf string)
  "Send STRING followed by Enter to the terminal in BUF."
  (with-current-buffer buf
    (pcase (if (derived-mode-p 'rsr/agent-tmux-mode) 'tmux rsr/agent-sessions-terminal)
      ('tmux (rsr/agent-tmux-send-text rsr/agent-tmux-window string)
             (rsr/agent-tmux-send-enter rsr/agent-tmux-window))
      ('vterm (vterm-send-string string) (vterm-send-return))
      ('eat (eat-term-send-string eat-terminal string)
            (eat-term-send-string eat-terminal "\r"))
      ('ghostel (ghostel-send-string string)
                (ghostel-send-string "\r")))))

(defun rsr/agent-sessions--terminal-paste (buf string)
  "Bracket-paste STRING into the terminal in BUF without submitting it."
  (with-current-buffer buf
    (cond
     ((derived-mode-p 'vterm-mode) (vterm-send-string string t))
     ((derived-mode-p 'eat-mode)
      (eat-term-send-string-as-yank eat-terminal string))
     ((derived-mode-p 'ghostel-mode) (ghostel-paste-string string))
     ((derived-mode-p 'rsr/agent-tmux-mode)
      (rsr/agent-tmux-paste rsr/agent-tmux-window string))
     (t (user-error "Current buffer is not an Eat, vterm, ghostel or tmux terminal")))))

(defun rsr/agent-session-insert-org-link ()
  "Prompt for an Org link and paste it into the current terminal input."
  (interactive)
  (let ((terminal (current-buffer))
        (link (with-temp-buffer
                (org-mode)
                (call-interactively #'org-insert-link)
                (buffer-substring-no-properties (point-min) (point-max)))))
    (rsr/agent-sessions--terminal-paste terminal link)))

(defun rsr/agent-sessions--create-terminal (dir &optional name)
  "Open a new terminal in DIR named <NAME>-<backend>.
NAME defaults to DIR's basename (typically the worktree name).  The backend
is `rsr/agent-sessions-terminal'."
  (let* ((base (or name (file-name-nondirectory (directory-file-name dir))))
         (bufname (format "%s-%s" base rsr/agent-sessions-terminal)))
    (rsr/agent-sessions--terminal-open dir bufname)))

(defun rsr/agent-sessions--goto-terminal-row (buf)
  "Move the dashboard's point to the row for terminal BUF, if it has one.
Creating a terminal re-renders the dashboard, and that render restores point
to the section it was on — the worktree or repo heading `+' was pressed on —
so a row that did not exist before it has to be sought out afterwards.  The
window points are set explicitly because the dashboard is no longer the
selected buffer by then (the new terminal is), and an unselected window
displays its own point, not the buffer's."
  (when-let* ((id (and (buffer-live-p buf)
                       (buffer-local-value 'rsr/agent-session-id buf)))
              (dashboard (get-buffer rsr/agent-sessions-buffer-name)))
    (with-current-buffer dashboard
      (when (rsr/agent-sessions--goto-session-id id)
        (dolist (win (get-buffer-window-list dashboard nil t))
          (set-window-point win (point)))))))

(defun rsr/agent-sessions--section-sessions (section)
  "The sessions of every row under SECTION, at any depth."
  (let (sessions)
    (cl-labels ((walk (s)
                  (if (eq (oref s type) 'rsr/agent-session-row)
                      (when-let ((session (rsr/agent-sessions--session-for-id
                                           (oref s value))))
                        (push session sessions))
                    (mapc #'walk (oref s children)))))
      (walk section))
    (nreverse sessions)))

(defun rsr/agent-sessions--section-tmux-session (section)
  "The tmux session the rows under SECTION run in, as its heading names it.
Read from the rows rather than kept in the section's value, which is also
its identity for the fold state a refresh restores."
  (rsr/agent-sessions--entries-tmux-session
   (mapcar (lambda (session) (list :session session))
           (rsr/agent-sessions--section-sessions section))))

(defun rsr/agent-sessions--section-worktrees (section worktrees)
  "Those of WORKTREES that a row under SECTION runs in, in WORKTREES' order.
A row outside every listed worktree (an agent outside git) counts for none."
  (let ((paths (delete-dups
                (mapcar (lambda (session)
                          (rsr/agent-sessions--canonical-path
                           (plist-get session :worktree-path)))
                        (rsr/agent-sessions--section-sessions section)))))
    (seq-filter (lambda (wt)
                  (member (rsr/agent-sessions--canonical-path
                           (plist-get wt :path))
                          paths))
                worktrees)))

(defun rsr/agent-sessions-new-vterm (&optional ask)
  "Create a new vterm in the worktree at point.
Leaves the dashboard's point on the new terminal's row, so the thing just
created is what `k', `t', `e' and `n'/`p' act from.  On a repo heading,
choose among that repo's worktrees; on a folder heading, the worktree its
sessions share, or a choice when they span several.  With a prefix argument
ASK, always choose.  Where it lands comes from point; see
`rsr/agent-sessions--new-terminal-at-point'."
  (interactive "P")
  (when-let ((buf (rsr/agent-sessions--new-terminal-at-point ask)))
    (rsr/agent-sessions--goto-terminal-row buf)))

(defun rsr/agent-sessions--new-terminal-at-point (&optional ask)
  "Open a terminal for the dashboard section at point; return it, or nil.
The tmux window opens in the tmux session of the row at point, or else of the
repo heading, rather than one asked for or derived from the checkout's folder
name.  The terminal joins the folder of the row or folder heading at point;
on a repo heading it asks which folder.  The worktree is the row's; on a
folder heading, the one its sessions share, asked for only when they span
several or ASK is non-nil; on a repo heading, asked for when it has several."
  (let* ((row (rsr/agent-sessions--enclosing-section 'rsr/agent-session-row))
         (row-session (and row (rsr/agent-sessions--session-for-id
                                (oref row value))))
         (row-buf (plist-get row-session :buffer))
         (ctx (rsr/agent-sessions--context-at-point))
         (folder-section (rsr/agent-sessions--enclosing-section
                          'rsr/agent-session-folder))
         (repo-section (rsr/agent-sessions--enclosing-section
                        'rsr/agent-session-repo))
         (repo (and repo-section (oref repo-section value)))
         (repo-root (plist-get repo :root))
         (tmux-session (or (and (buffer-live-p row-buf)
                                (rsr/agent-tmux-proxy-p row-buf)
                                (buffer-local-value 'rsr/agent-tmux-session
                                                    row-buf))
                           (and repo-section
                                (rsr/agent-sessions--section-tmux-session
                                 repo-section))))
         (worktrees (and (not row) repo-root
                         (rsr/agent-sessions--all-worktrees repo-root)))
         (folder-worktrees (and folder-section worktrees (not ask)
                                (rsr/agent-sessions--section-worktrees
                                 folder-section worktrees)))
         (selected (cond ((null worktrees) nil)
                         ((= (length worktrees) 1) (car worktrees))
                         ((= (length folder-worktrees) 1)
                          (car folder-worktrees))
                         (t (let* ((labels (mapcar (lambda (wt)
                                                     (plist-get wt :label))
                                                   worktrees))
                                   (choice (completing-read "Worktree: " labels
                                                            nil t)))
                              (seq-find (lambda (wt)
                                          (equal choice (plist-get wt :label)))
                                        worktrees)))))
         (dir (or (plist-get selected :path) (plist-get ctx :path)))
         (name (or (plist-get selected :label) (plist-get ctx :name))))
    (if (or (null dir) (not (file-directory-p dir)))
        (progn (message "No worktree at point.") nil)
      (let* ((folder-id
              (cond (row-session
                     ;; Judged against the heading's repo: an agent outside
                     ;; git listed under it carries its own directory.
                     (rsr/agent-sessions--folder-for-session
                      (plist-put (copy-sequence row-session)
                                 :repo-root repo-root)))
                    (folder-section (oref folder-section value))
                    (repo-root
                     (plist-get (rsr/agent-sessions--read-folder
                                 (rsr/agent-sessions--canonical-path repo-root)
                                 "Folder for the new agent: ")
                                :id))))
             (rsr/agent-tmux--target (if tmux-session
                                         (cons tmux-session dir)
                                       rsr/agent-tmux--target))
             (buf (rsr/agent-sessions--create-terminal dir name)))
        (when folder-id
          (rsr/agent-sessions--folder-set
           (list :buffer buf :repo-root repo-root) folder-id)
          (rsr/agent-sessions--refresh-if-visible))
        buf))))

(defun rsr/agent-sessions--ask-folder-for (buf)
  "Ask which folder of BUF's repo the new terminal BUF joins, and file it.
For a terminal opened outside the dashboard, where there is no point to read
the folder from.  The repo is the one the dashboard lists BUF under: an agent
outside git belongs to the repo its tmux session started in."
  (let* ((session (rsr/agent-sessions--terminal-session buf))
         (repo (rsr/agent-sessions--canonical-path
                (or (plist-get (rsr/agent-sessions--tmux-home session) :repo-root)
                    (rsr/agent-sessions--session-repo session)))))
    (when repo
      (when-let ((folder (rsr/agent-sessions--read-folder
                          repo "Folder for the new agent: ")))
        (rsr/agent-sessions--folder-set (list :buffer buf :repo-root repo)
                                        (plist-get folder :id))
        (rsr/agent-sessions--refresh-if-visible)))))

;;;###autoload
(defun rsr/agent-session-switch-or-new ()
  "Switch to an agent session of the current project, or start a new one.
Prompts to pick among the sessions running in the current project's
worktree; choosing nothing (empty input) opens a new vterm in the project
root, like `+' in the dashboard.  With no sessions at all, goes straight to
creating one."
  (interactive)
  (let* ((root (or (ignore-errors (project-root (project-current)))
                   default-directory))
         (sessions
          (seq-filter
           (lambda (entry)
             (let* ((s (plist-get entry :session))
                    (wp (or (plist-get s :worktree-path)
                            (let ((b (plist-get s :buffer)))
                              (and (buffer-live-p b)
                                   (buffer-local-value 'default-directory b))))))
               (and wp (file-equal-p wp root))))
           (rsr/agent-sessions--live-entries)))
         (cands
          (mapcar (lambda (entry)
                    (let* ((s (plist-get entry :session))
                           (buf (plist-get s :buffer)))
                      (cons (format "%s [%s %s]"
                                    (buffer-name buf)
                                    (plist-get s :agent-type)
                                    (plist-get s :status))
                            buf)))
                  sessions))
         (choice (and cands
                      (completing-read
                       (format "Agent session in %s (empty for new): "
                               (file-name-nondirectory (directory-file-name root)))
                       (mapcar #'car cands) nil nil)))
         (buf (and choice (cdr (assoc choice cands)))))
    (if (buffer-live-p buf)
        (rsr/agent-sessions--show-terminal buf)
      (rsr/agent-sessions--create-terminal
       root (plist-get (rsr/agent-session--repo-info root) :worktree)))))

(defun rsr/agent-sessions--rows ()
  "Return (LINE-POS . STATUS) for each session and attachment row, in order.
This is what the last render drew (`rsr/agent-sessions--row-status'), never a
fresh lookup: only the render path knows the displayed status."
  rsr/agent-sessions--row-status)

(defun rsr/agent-sessions--hidden-file-row-p (row)
  "Return non-nil when ROW belongs to a hidden file or external-link section."
  (let ((position (car row)))
    (and (invisible-p position)
         (save-excursion
           (goto-char position)
           (let ((section (magit-current-section)))
             (and section
                  (memq (oref section type)
                        '(rsr/agent-session-file rsr/agent-session-link))))))))

(defun rsr/agent-sessions--goto-row (direction predicate)
  "Move point to the next/previous row (DIRECTION is `next' or `prev').
When PREDICATE is non-nil, only rows whose status satisfies it are considered.
Hidden attachment rows are excluded from filtered navigation; hidden session
rows remain candidates."
  (let* ((cur (line-beginning-position))
         (positions (mapcar #'car
                            (if predicate
                                (seq-filter (lambda (r)
                                              (and (funcall predicate (cdr r))
                                                   (not (rsr/agent-sessions--hidden-file-row-p
                                                         r))))
                                            (rsr/agent-sessions--rows))
                              (rsr/agent-sessions--rows))))
         (target (pcase direction
                   ('next (seq-find (lambda (p) (> p cur)) positions))
                   ('prev (seq-find (lambda (p) (< p cur)) (reverse positions))))))
    (cond (target (goto-char target))
          ((null positions) (message "No matching row."))
          (t (message "No %s row." (if (eq direction 'next) "next" "previous"))))))

(defun rsr/agent-sessions-next ()
  "Move to the next session row."
  (interactive)
  (rsr/agent-sessions--goto-row 'next nil))

(defun rsr/agent-sessions-prev ()
  "Move to the previous session row."
  (interactive)
  (rsr/agent-sessions--goto-row 'prev nil))

(defun rsr/agent-sessions-toggle-sort ()
  "Toggle the dashboard between activity order and the stable order.
Activity order reorders on every hook event, so concurrently busy sessions
trade places constantly; the stable order is the default for that reason."
  (interactive)
  (setq rsr/agent-sessions-sort-by-activity
        (not rsr/agent-sessions-sort-by-activity))
  (rsr/agent-sessions--refresh)
  (message "Sorting by %s"
           (if rsr/agent-sessions-sort-by-activity
               "most recent activity"
             (if rsr/agent-sessions-sort-by-attention
                 "attention, then session age"
               "session age"))))

(defun rsr/agent-sessions-toggle-attention-sort ()
  "Toggle whether rows that need attention move to the top of their group.
Off, rows stay in creation order whatever their status."
  (interactive)
  (setq rsr/agent-sessions-sort-by-attention
        (not rsr/agent-sessions-sort-by-attention))
  (rsr/agent-sessions--refresh)
  (message (if rsr/agent-sessions-sort-by-attention
               "Rows needing attention move to the top"
             "Rows keep a fixed order")))

(defun rsr/agent-sessions--attention-p (status)
  (memq status '(needs-attention error)))

(defun rsr/agent-sessions-next-attention ()
  "Move to the next session or visible attachment that needs attention."
  (interactive)
  (rsr/agent-sessions--goto-row 'next #'rsr/agent-sessions--attention-p))

(defun rsr/agent-sessions-prev-attention ()
  "Move to the previous session or visible attachment that needs attention."
  (interactive)
  (rsr/agent-sessions--goto-row 'prev #'rsr/agent-sessions--attention-p))

(defun rsr/agent-sessions--enclosing-section (type)
  "Return the innermost section of TYPE at or above point, or nil."
  (let ((section (magit-current-section)))
    (while (and section (not (eq (oref section type) type)))
      (setq section (oref section parent)))
    section))

(defun rsr/agent-sessions--group-at-point ()
  "Return (SCOPE KEYS KEY) for the reorderable thing at point, or nil.
SCOPE is its manual-order scope, KEYS the manual-order keys of every sibling
in its group in current display order, and KEY its own key.  The group is
re-derived from the live tree rather than scraped from the buffer, so the keys
are exactly what the next render will order."
  (let* ((section (magit-current-section))
         (repos (rsr/agent-sessions--build-tree (rsr/agent-sessions--live-entries)))
         (repo-sec (rsr/agent-sessions--enclosing-section 'rsr/agent-session-repo))
         (rkey (and repo-sec (rsr/agent-sessions--repo-key (oref repo-sec value))))
         (repo (and rkey (seq-find (lambda (r)
                                     (equal rkey (rsr/agent-sessions--repo-key r)))
                                   repos))))
    (pcase (and section (oref section type))
      ('rsr/agent-session-repo
       (list rsr/agent-sessions--repos-scope
             (mapcar #'rsr/agent-sessions--repo-key repos)
             rkey))
      ('rsr/agent-session-folder
       (when repo
         (let ((folders (rsr/agent-sessions--apply-manual-order
                         (rsr/agent-sessions--folders-scope rkey)
                         #'rsr/agent-sessions--folder-key
                         ;; Only the folders on screen: an empty one is
                         ;; hidden, and swapping with it would look like no
                         ;; move.  Its saved slot survives the splice.
                         (sort (seq-filter
                                (lambda (folder)
                                  (rsr/agent-sessions--folder-entries
                                   folder (plist-get repo :entries)))
                                (rsr/agent-sessions--folders-for-repo rkey))
                               (lambda (a b)
                                 (string-lessp (plist-get a :name)
                                               (plist-get b :name)))))))
           (list (rsr/agent-sessions--folders-scope rkey)
                 (mapcar #'rsr/agent-sessions--folder-key folders)
                 (format "%s" (or (oref section value) "none"))))))
      ('rsr/agent-session-row
       (let ((session (rsr/agent-sessions--session-for-id (oref section value))))
         (when (and repo session)
           (let* ((folder-id (rsr/agent-sessions--folder-for-session session))
                  (folder (or (rsr/agent-sessions--folder folder-id)
                              (list :id nil :name "No folder")))
                  (members (rsr/agent-sessions--folder-entries
                            folder (plist-get repo :entries))))
             (list (rsr/agent-sessions--folder-sessions-scope rkey folder-id)
                   (mapcar #'rsr/agent-sessions--entry-buffer-name
                           (if rsr/agent-sessions-sort-by-activity
                               members
                             (rsr/agent-sessions--apply-manual-order
                              (rsr/agent-sessions--folder-sessions-scope
                               rkey folder-id)
                              #'rsr/agent-sessions--entry-buffer-name
                              members)))
                   (rsr/agent-sessions--session-buffer-name session))))))
      ('rsr/agent-session-file
       (let* ((row (rsr/agent-sessions--enclosing-section 'rsr/agent-session-row))
              (session (and row (rsr/agent-sessions--session-for-id
                                 (oref row value)))))
         (when session
           (list (rsr/agent-sessions--files-scope session)
                 (mapcar (lambda (f) (plist-get f :path))
                         (rsr/agent-sessions--session-files session))
                 (oref section value)))))
      ('rsr/agent-session-link
       (let* ((row (rsr/agent-sessions--enclosing-section 'rsr/agent-session-row))
              (session (and row (rsr/agent-sessions--session-for-id
                                 (oref row value)))))
         (when session
           (list (rsr/agent-sessions--links-scope session)
                 (mapcar (lambda (link) (plist-get link :url))
                         (rsr/agent-sessions--session-links session))
                 (oref section value))))))))

(defun rsr/agent-sessions--merge-order (saved visible)
  "Splice the VISIBLE key order into SAVED, keeping absent keys in place.
Each slot in SAVED held by a currently visible key is refilled from VISIBLE in
order, and visible keys SAVED doesn't know about are appended.  Rewriting a
group therefore never discards the remembered slot of a repo, worktree, or
session that simply isn't on screen right now (all its terminals closed, say)."
  (let ((queue visible)
        (vis (let ((h (make-hash-table :test 'equal)))
               (dolist (k visible) (puthash k t h))
               h))
        result)
    (dolist (k saved)
      (if (gethash k vis)
          (when queue (push (pop queue) result))
        (push k result)))
    (append (nreverse result) queue)))

(defun rsr/agent-sessions--persist-move (scope keys key delta)
  "Record KEY shifted by DELTA among KEYS within SCOPE, and save.
Returns non-nil when the order changed; messages and returns nil when KEY is
already at the end it is being moved towards."
  (let* ((pos (seq-position keys key))
         (dest (and pos (+ pos delta))))
    (cond
     ((null pos) (message "Nothing to reorder at point.") nil)
     ((or (< dest 0) (>= dest (length keys)))
      (message "Already %s in its group." (if (< delta 0) "first" "last"))
      nil)
     (t
      (let* ((swapped (copy-sequence keys))
             (table (rsr/agent-sessions--order-table))
             (old (gethash scope table))
             new)
        (setf (nth pos swapped) (nth dest keys)
              (nth dest swapped) key)
        (setq new (rsr/agent-sessions--merge-order old swapped))
        (puthash scope new table)
        ;; Hand both lists over so only the rows that actually moved are
        ;; written — for a transposition that is two of them.
        (rsr/agent-sessions--order-write-group scope old new)
        t)))))

(defun rsr/agent-sessions--move (delta)
  "Move the repo, folder, worktree, or session at point within its group."
  (if rsr/agent-sessions-sort-by-activity
      (message "Manual order is ignored while sorting by activity (press `s').")
      (pcase (rsr/agent-sessions--group-at-point)
        (`(,scope ,keys ,key)
         (when (rsr/agent-sessions--persist-move scope keys key delta)
           (rsr/agent-sessions--refresh)))
        (_ (message "Nothing to reorder at point.")))))

(defun rsr/agent-sessions-move-down ()
  "Move the repo, folder, worktree, or session down within its group.
Only the enclosing group is affected: a session moves among sessions of its
worktree or folder, and a folder or worktree moves within its repo.
The chosen order is written to `rsr/agent-sessions-db-file', so it survives
both the session and Emacs itself; a session is remembered by its buffer name,
so renaming one forgets its place.  Unavailable while sorting by activity
\(`s'), which reorders by recency on every event.  `C-c C-o' clears it again."
  (interactive)
  (rsr/agent-sessions--move 1))

(defun rsr/agent-sessions-move-up ()
  "Move the repo, worktree, or session at point one place up its group.
See `rsr/agent-sessions-move-down'."
  (interactive)
  (rsr/agent-sessions--move -1))

(defun rsr/agent-sessions-clear-manual-order ()
  "Forget the manual order (`M-n' / `M-p') and return to the automatic one.
With point inside a repo, folder, worktree, or on a session row, clears just that
item's group; with a prefix argument, clears every group."
  (interactive)
  (let ((table (rsr/agent-sessions--order-table)))
      (if current-prefix-arg
          (progn (clrhash table)
                 (rsr/agent-sessions--order-delete-all)
                 (rsr/agent-sessions--refresh)
                 (message "Manual order cleared everywhere."))
        (pcase (rsr/agent-sessions--group-at-point)
          (`(,scope ,_ ,_)
           (remhash scope table)
           (rsr/agent-sessions--order-delete-group scope)
           (rsr/agent-sessions--refresh)
           (message "Manual order cleared for this group."))
          (_ (message "Point is not in a reorderable group."))))))

;;;###autoload
(defun rsr/agent-session-rename-to-title ()
  "Rename the current vterm buffer to its agent session title.
The title captured from the terminal (`rsr/agent-session-title') is offered
as the editable default so it can be tweaked before confirming."
  (interactive)
  (let* ((initial (or rsr/agent-session-title (buffer-name)))
         (new (string-trim (read-string "Rename buffer to: " initial))))
    (unless (string-empty-p new)
      (rename-buffer new t)
      (message "Renamed to %s" new))))

(defcustom rsr/agent-session-resume-commands
  '((claude . "claude --resume %s")
    (codex  . "codex resume %s")
    (pi     . "pi --session %s")
    (agy    . "agy --conversation %s"))
  "Alist mapping AGENT-TYPE symbol to a shell command that resumes a session.
The %s is replaced with the agent's own session id."
  :type '(alist :key-type symbol :value-type string))

(defcustom rsr/agent-session-branch-commands
  '((claude . "claude --resume %s --fork-session")
    (codex  . "codex fork %s")
    (pi     . "pi --fork %s"))
  "Alist mapping AGENT-TYPE symbol to a shell command that branches a session.
Branching forks the conversation into a new session that shares the parent's
history but gets its own session id (`claude --fork-session' / `codex fork').
The %s is replaced with the parent's own session id."
  :type '(alist :key-type symbol :value-type string))

(defun rsr/agent-session--spawn (worktree-path agent-type session-id commands
                                              &optional branched-from initial-prompt)
  "Open a terminal in WORKTREE-PATH and run COMMANDS's template for AGENT-TYPE.
COMMANDS is an alist like `rsr/agent-session-resume-commands'; its template's
%s is filled with SESSION-ID.  When BRANCHED-FROM is non-nil (a cons
\(PARENT-SID . LABEL)), tag the new terminal so the session it starts records
that it was branched from that parent.  When INITIAL-PROMPT is non-nil, append
it as a shell-quoted argument to the launch command.  Returns the new terminal
buffer."
  (let* ((agent (if (symbolp agent-type) agent-type (intern agent-type)))
         (template (alist-get agent commands))
         (default-directory (file-name-as-directory worktree-path)))
    (unless template
      (error "No command configured for agent type `%s'" agent))
    (unless (file-directory-p default-directory)
      (error "Worktree no longer exists: %s" worktree-path))
    (let ((buf (rsr/agent-sessions--create-terminal
                default-directory
                (plist-get (rsr/agent-session--repo-info default-directory) :worktree))))
      (when (and branched-from (buffer-live-p buf))
        (with-current-buffer buf
          (setq-local rsr/agent-session--branched-from branched-from)))
      (rsr/agent-sessions--terminal-send
       buf (concat (format template session-id)
                   (if initial-prompt
                       (concat " " (shell-quote-argument initial-prompt))
                     "")))
      buf)))

;;;###autoload
(defun rsr/agent-session-start (worktree-path agent-type session-id
                                             &optional initial-prompt)
  "Open a vterm in WORKTREE-PATH and resume AGENT-TYPE's SESSION-ID.
AGENT-TYPE is a symbol such as `claude' or `codex'.  This is the target of
the `elisp:' links produced by `org-store-link' on a session row.  When
INITIAL-PROMPT is non-nil, submit it as the resumed session's first prompt."
  (let ((buf (rsr/agent-session--spawn
              worktree-path agent-type session-id
              rsr/agent-session-resume-commands nil initial-prompt)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq-local rsr/agent-session--resuming-session-id session-id)))
    buf))

(defun rsr/agent-sessions--buffer-for-agent-session (session-id)
  "Return the live buffer running the agent session SESSION-ID, or nil.
Prefer an identity confirmed by an agent hook in `rsr/agent-sessions'.  During
startup, before Codex's first hook, also recognize the resume identity recorded
on its terminal buffer in `rsr/agent-session--resuming-session-id'."
  (catch 'found
    (maphash
     (lambda (_id session)
       (when (equal (plist-get session :agent-session-id) session-id)
         (let ((buf (plist-get session :buffer)))
           (when (buffer-live-p buf)
             (throw 'found buf)))))
     rsr/agent-sessions)
    (maphash
     (lambda (_id buf)
       (when (and (buffer-live-p buf)
                  (equal (buffer-local-value
                          'rsr/agent-session--resuming-session-id buf)
                         session-id))
         (throw 'found buf)))
     rsr/agent-session-id->buffer)
    nil))

;;;###autoload
(defun rsr/agent-session-open (worktree-path agent-type session-id)
  "Jump to the running AGENT-TYPE session SESSION-ID, or resume it if not open.
If a live terminal is already running SESSION-ID (matched by the agent's own
session id), switch to it; otherwise open a new terminal in WORKTREE-PATH and
resume it via `rsr/agent-session-start'.  This is the target of the
`agent-session' `elisp:' links produced by `org-store-link'."
  (let ((buf (rsr/agent-sessions--buffer-for-agent-session session-id)))
    (if (buffer-live-p buf)
        (rsr/agent-sessions--show-terminal buf)
      (rsr/agent-session-start worktree-path agent-type session-id))))

;;; Restoring sessions from the log -----------------------------------------

(defun rsr/agent-sessions--log-rows (where &optional args)
  "Return session-log rows matching WHERE as plists, newest ending first.
Deduplicated by agent session id, keeping each id's most recent row: the fork
transient can leave a second row carrying a parent's id, and one entry per
resumable session is what the caller wants either way.  Rows with no agent
session id are skipped — a bare terminal has nothing to resume, and `+' opens
one anyway."
  (mapcar
   (lambda (r)
     (pcase-let ((`(,sid ,type ,worktree ,repo ,label ,title ,closed ,reason) r))
       (list :agent-sid sid :agent-type type :worktree worktree :repo repo
             :label label :title title :closed-at closed :reason reason)))
   (sqlite-select
    (rsr/agent-sessions--db)
    (concat "SELECT agent_sid, agent_type, worktree, repo, label, title,
                    MAX(closed_at) AS closed_at, close_reason
               FROM sessions
              WHERE agent_sid IS NOT NULL AND agent_type IS NOT NULL AND "
            where
            " GROUP BY agent_sid ORDER BY closed_at DESC")
    args)))

(defface rsr/agent-session-restore-plans
  '((t :foreground "#e0af68"))
  "Face for a session's Plans folder in the `R' picker.")

(defface rsr/agent-session-restore-code
  '((t :foreground "#2ac3de"))
  "Face for a session's code folders in the `R' picker.")

(defun rsr/agent-sessions--log-row-session (row)
  "A stand-in session for session-log ROW, for the per-session lookups.
Notes, states and registered folders are keyed by `--session-note-keys', which
for a session with no buffer is its agent session id alone — the key those
were filed under while it ran."
  (list :agent-session-id (plist-get row :agent-sid)))

(defun rsr/agent-sessions--log-describe (row &optional label-width)
  "A one-line label for session-log ROW, for completion or confirmation.
LABEL-WIDTH pads the label column, default 28; see `--log-label-width'.
Ends with the start of the agent session id, which both names an untitled
session and keeps two sessions with the same label and title apart: the
picker looks a choice up by this string, so a duplicate would hide one."
  (let* ((sid (or (plist-get row :agent-sid) "?"))
         (state (rsr/agent-sessions--session-state
                 (rsr/agent-sessions--log-row-session row)))
         (title (plist-get row :title)))
    (concat (string-pad (or (plist-get row :label) "?") (or label-width 28))
            " "
            (format "%-7s " (or (plist-get row :agent-type) "?"))
            (string-pad (if state
                            (propertize state 'face
                                        (rsr/agent-sessions--state-face state))
                          "")
                        13)
            (or title (propertize "(no title)" 'face 'shadow))
            "  "
            (propertize (substring sid 0 (min 8 (length sid))) 'face 'shadow))))

(defun rsr/agent-sessions--log-label-width (rows)
  "The label column width that lines ROWS up: the longest label, at most 40."
  (min 40 (apply #'max 1 (mapcar (lambda (r) (length (or (plist-get r :label) "?")))
                                 rows))))

(defun rsr/agent-sessions--log-details (row)
  "What ROW's session was about: its Plans and code folders and its note.
Each folder is shown by its last path component, Plans and code in their own
faces; the note by its first line.  Empty when the session has none."
  (let* ((session (rsr/agent-sessions--log-row-session row))
         (name (lambda (path) (file-name-nondirectory (directory-file-name path))))
         (plans (rsr/agent-sessions--session-folder-paths session "plans"))
         (code (rsr/agent-sessions--session-folder-paths session "code"))
         (note (cdr (rsr/agent-sessions--note-find
                     (rsr/agent-sessions--session-note-keys session)))))
    (mapconcat
     #'identity
     (delq nil
           (list (and plans
                      (propertize (concat "plans:" (funcall name (car (last plans))))
                                  'face 'rsr/agent-session-restore-plans))
                 (and code
                      (propertize (concat "code:" (mapconcat name code ","))
                                  'face 'rsr/agent-session-restore-code))
                 (and note
                      (propertize (car (split-string note "\n"))
                                  'face 'rsr/agent-session-note))))
     "  ")))

(defun rsr/agent-sessions--log-annotate (row)
  "The trailing annotation for session-log ROW: when it ended, and how."
  (let ((at (plist-get row :closed-at)))
    (format "  %s, %s"
            (if at
                (format-time-string "%b %e %H:%M" (seconds-to-time at))
              "?")
            (pcase (plist-get row :reason)
              ("killed" "you closed it")
              ("agent-exit" "agent exited")
              ("superseded" "replaced in its terminal")
              ("emacs-exit" "Emacs quit")
              ("crash" "Emacs died")
              (other (or other "?"))))))

(defun rsr/agent-sessions--restore-title (buf row)
  "Restore session-log ROW's saved title as a user override on BUF.
The log records the title that labelled the old terminal.  Making it an
override preserves that label when the resumed agent emits fresh OSC titles."
  (when (buffer-live-p buf)
    (when-let ((title (plist-get row :title)))
      (with-current-buffer buf
        (setq-local rsr/agent-session-title-override title))
      (rsr/agent-sessions--refresh-if-visible)))
  buf)

(defun rsr/agent-sessions--never-saved-p (row)
  "Non-nil when ROW is a Claude or pi session with no saved conversation.
Both report a session id when the TUI opens but write the session file only
with the first prompt, so a session that was opened and never used is logged
yet cannot be resumed: `claude --resume' just fails with \"No conversation
found\".  Pi is only judged when its sessions directory exists, so a pi that
keeps its sessions somewhere else is never mistaken for an unused one.  Codex
is left alone: it reports its id on the first prompt, by which time its
rollout file exists."
  (let ((sid (plist-get row :agent-sid)))
    (pcase (plist-get row :agent-type)
      ("claude"
       (null (file-expand-wildcards
              (expand-file-name (format "projects/*/%s.jsonl" sid)
                                (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude")))))
      ("pi"
       (let ((dir (expand-file-name "sessions"
                                    (or (getenv "PI_CODING_AGENT_DIR")
                                        "~/.pi/agent"))))
         (and (file-directory-p dir)
              (null (file-expand-wildcards
                     (expand-file-name (format "*/*_%s.jsonl" sid) dir)))))))))

(defun rsr/agent-sessions--restore-row (row)
  "Resume the session described by ROW, or jump to it if it is already open."
  (let* ((wt (plist-get row :worktree))
         (sid (plist-get row :agent-sid))
         (type (intern (plist-get row :agent-type)))
         (live (rsr/agent-sessions--buffer-for-agent-session sid)))
    (cond
     (live
      (rsr/agent-sessions--restore-title live row)
      (rsr/agent-sessions--show-terminal live)
      (message "That session is already open."))
     ((not (file-directory-p wt))
      (message "Worktree is gone: %s" wt))
     ((rsr/agent-sessions--never-saved-p row)
      (message "Nothing to resume: that %s session was never used."
               (plist-get row :agent-type)))
     (t
      ;; A tmux session outside git can't be derived from the folder; its
      ;; name is the row's label (see `rsr/agent-sessions--buffer-repo-info'),
      ;; so resume into it rather than asking.
      (let ((rsr/agent-tmux--target
             (and (not (rsr/agent-tmux-checkout wt))
                  (plist-get row :label)
                  (cons (plist-get row :label) wt))))
        (rsr/agent-sessions--restore-title
         (rsr/agent-session-start wt type sid) row))))))

;;; The `R' picker

(defvar rsr/agent-sessions--restore-filter-requested nil
  "Non-nil when the `R' picker was left to change its repo filter.")

(defun rsr/agent-sessions-restore-filter-repo ()
  "Leave the `R' picker to narrow it to one repo, or to widen it again."
  (interactive)
  (setq rsr/agent-sessions--restore-filter-requested t)
  (exit-minibuffer))

(defvar rsr/agent-sessions-restore-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-r") #'rsr/agent-sessions-restore-filter-repo)
    map)
  "Keys added to the minibuffer while `rsr/agent-sessions-restore' is reading.
Layered over whatever map the completion UI installs, so it works under the
default minibuffer and under Vertico alike.")

(defun rsr/agent-sessions--log-row-repo (row)
  "The repo name ROW is filed under in the `R' picker's repo filter.
The repo root's name when the log has one; otherwise the label, which for a
tmux session outside git is that session's name."
  (let ((repo (plist-get row :repo)))
    (if repo
        (rsr/agent-sessions--repo-name repo)
      (or (plist-get row :label) "?"))))

(defun rsr/agent-sessions--restore-candidate (row &optional label-width)
  "The `R' picker's line for ROW: dimmed when there is nothing to resume.
A never-used session stays listed rather than hidden, so the list still
accounts for every session the log knows; choosing one says why it is empty."
  (let ((line (rsr/agent-sessions--log-describe row label-width)))
    (if (rsr/agent-sessions--never-saved-p row)
        (propertize (substring-no-properties line) 'face 'shadow
                    'rsr/agent-sessions-never-used t)
      line)))

(defun rsr/agent-sessions--restore-annotation (row never-used)
  "The `R' picker's annotation for ROW: what it was about, then its ending."
  (let ((details (rsr/agent-sessions--log-details row)))
    (concat (if (string-empty-p details) "" (concat "  " details))
            (rsr/agent-sessions--log-annotate row)
            (if never-used (propertize ", never used" 'face 'shadow) ""))))

(defun rsr/agent-sessions--restore-read (rows repo)
  "Read one of ROWS in the minibuffer; REPO names an active filter, or nil.
Returns the chosen row, the symbol `filter' when the user asked to change the
repo filter, or nil.  Candidates keep the log's newest-first order: the table
declares an identity sort, or a completion UI that sorts by history or length
would scatter them."
  (let* ((width (rsr/agent-sessions--log-label-width rows))
         (table (mapcar (lambda (r)
                          (cons (rsr/agent-sessions--restore-candidate r width) r))
                        rows))
         (collection
          (lambda (string pred action)
            (if (eq action 'metadata)
                `(metadata
                  (display-sort-function . identity)
                  (cycle-sort-function . identity)
                  (annotation-function
                   . ,(lambda (k)
                        (when-let ((cell (assoc k table)))
                          (rsr/agent-sessions--restore-annotation
                           (cdr cell)
                           (get-text-property 0 'rsr/agent-sessions-never-used
                                              (car cell)))))))
              (complete-with-action action table string pred))))
         (filter-key (substitute-command-keys
                      "\\<rsr/agent-sessions-restore-minibuffer-map>\\[rsr/agent-sessions-restore-filter-repo]"))
         (prompt (if repo
                     (format "Restore session in %s (%s: all repos): " repo filter-key)
                   (format "Restore session (%s: one repo): " filter-key)))
         (choice
          (progn
            (setq rsr/agent-sessions--restore-filter-requested nil)
            (minibuffer-with-setup-hook
                (lambda ()
                  (use-local-map (make-composed-keymap
                                  rsr/agent-sessions-restore-minibuffer-map
                                  (current-local-map))))
              (completing-read prompt collection nil t)))))
    (if rsr/agent-sessions--restore-filter-requested
        'filter
      (cdr (assoc choice table)))))

;;;###autoload
(defun rsr/agent-sessions-restore ()
  "Resume a session that has ended, picked from the log.
Lists every session the log knows the end of, most recently ended first.  Each
line shows the session's workflow state, title and the start of its agent
session id; the annotation adds its Plans and code folders, its note, and when
and how it ended.  Sessions with nothing to resume are dimmed.

\\<rsr/agent-sessions-restore-minibuffer-map>\\[rsr/agent-sessions-restore-filter-repo] \
narrows the list to one repo, and pressed again lists every
repo; the list starts unfiltered.  A session whose terminal is
somehow still open is switched to rather than resumed twice, and one whose
worktree has since been deleted says so instead of failing in a shell."
  (interactive)
  (let ((rows (rsr/agent-sessions--log-rows "closed_at IS NOT NULL"))
        repo choice)
    (if (null rows)
        (message "No ended sessions in the log yet.")
      (while (eq 'filter
                 (setq choice
                       (rsr/agent-sessions--restore-read
                        (if repo
                            (seq-filter (lambda (r)
                                          (equal repo (rsr/agent-sessions--log-row-repo r)))
                                        rows)
                          rows)
                        repo)))
        (setq repo
              (unless repo
                (completing-read
                 "Only sessions from repo: "
                 (seq-uniq (mapcar #'rsr/agent-sessions--log-row-repo rows))
                 nil t))))
      (when choice
        (rsr/agent-sessions--restore-row choice)))))

;;;###autoload
(defun rsr/agent-sessions-restore-previous ()
  "Reopen the sessions that were running when Emacs last stopped.
Covers both an Emacs that crashed and one that was quit while sessions were
still going — from here those are the same thing, and each closes its batch of
rows with a single timestamp, which is how the last batch is identified.

Deliberately not bound to a key: it is a recovery command, wanted rarely and
never by accident.  Sessions already open are skipped, as are worktrees that
no longer exist, and what is left is shown for confirmation before anything
is spawned."
  (interactive)
  ;; Agents still running in tmux would otherwise be offered for a second
  ;; copy; reattaching first makes them count as open.
  (when (eq rsr/agent-sessions-terminal 'tmux)
    (rsr/agent-sessions-tmux-reattach))
  (let* ((rows (rsr/agent-sessions--log-rows
                "close_reason IN ('crash', 'emacs-exit')
                 AND closed_at = (SELECT MAX(closed_at) FROM sessions
                                   WHERE close_reason IN ('crash', 'emacs-exit'))"))
         (live (seq-filter (lambda (r)
                             (rsr/agent-sessions--buffer-for-agent-session
                              (plist-get r :agent-sid)))
                           rows))
         (gone (seq-filter (lambda (r)
                             (not (file-directory-p (plist-get r :worktree))))
                           rows))
         (unused (seq-filter #'rsr/agent-sessions--never-saved-p
                             (seq-difference rows (append live gone))))
         (todo (seq-difference rows (append live gone unused))))
    (cond
     ((null rows) (message "No sessions were lost — nothing to restore."))
     ((null todo)
      (message "Nothing to restore: %d already open, %d worktree(s) gone, %d never used."
               (length live) (length gone) (length unused)))
     (t
      (with-output-to-temp-buffer "*Agent Sessions Restore*"
        (princ (format "Sessions from the last Emacs (%s):\n\n"
                       (rsr/agent-sessions--log-annotate (car todo))))
        (let ((width (rsr/agent-sessions--log-label-width todo)))
          (dolist (r todo)
            (princ (concat "  " (rsr/agent-sessions--log-describe r width) "\n"))))
        (when live
          (princ (format "\nAlready open, will be skipped: %d\n" (length live))))
        (dolist (r gone)
          (princ (format "\nWorktree gone, cannot restore: %s\n"
                         (plist-get r :worktree))))
        (when unused
          (princ (format "\nNever used, nothing to resume: %d\n" (length unused)))))
      (when (y-or-n-p (format "Restore %d session(s)? " (length todo)))
        ;; Staggered: each spawns a terminal and types into it, and firing them
        ;; all in one go leaves the shells racing their own startup.
        (let ((n 0))
          (dolist (row todo)
            (run-at-time (* n 1.0) nil
                         (lambda (r)
                           (condition-case err
                               (save-window-excursion
                                 (rsr/agent-sessions--restore-row r))
                             (error (message "agent-sessions: %s"
                                             (error-message-string err)))))
                         row)
            (setq n (1+ n))))
        (message "Restoring %d session(s)…" (length todo)))))))

(defun rsr/agent-sessions--store-link-for (session)
  "Store an `elisp:' resume link for SESSION via `org-link-store-props'.
Return non-nil on success, nil when SESSION lacks the info to build a link."
  (when session
    (let* ((path (or (plist-get session :worktree-path)
                     (let ((buf (plist-get session :buffer)))
                       (and (buffer-live-p buf)
                            (buffer-local-value 'default-directory buf)))))
           (agent (plist-get session :agent-type))
           (sid (plist-get session :agent-session-id))
           (branch (and path
                        (ignore-errors
                          (let ((default-directory path))
                            (magit-get-current-branch)))))
           (title (rsr/agent-sessions--session-title session)))
      (when (and path sid)
        (org-link-store-props
         :type "agent-session"
         :link (format "agent-session:%s::%s::%s"
                       agent sid (file-name-as-directory path))
         :description (if branch
                          (format "%s %s %s" branch agent (or title sid))
                        (format "%s %s" agent (or title sid))))
        t))))

(defun rsr/agent-sessions--store-file-link (path)
  "Store an Org `file:' link to PATH, described by its bare file name.
Return non-nil on success.  A shared-file row is a pointer to a file, so the
useful link is the ordinary one any other buffer would produce — not something
that goes through this package.  The description is the file name alone,
extension included: the row already sits under the session that shared it, and
the path it came from is rarely what the surrounding prose wants to read."
  (when (and path (not (string-empty-p path)))
    (org-link-store-props
     :type "file"
     :link (concat "file:" (abbreviate-file-name path))
     :description (file-name-nondirectory (directory-file-name path)))
    t))

(defun rsr/agent-sessions--store-external-link (link)
  "Store shared external LINK as an ordinary HTTP(S) Org link."
  (let ((url (plist-get link :url)))
    (when (and url (not (string-empty-p url)))
      (org-link-store-props
       :type (if (string-prefix-p "https://" url) "https" "http")
       :link url
       :description (or (plist-get link :label) url))
      t)))

(defun rsr/agent-sessions--parse-session-link (link)
  "Return (AGENT SESSION-ID WORKTREE) parsed from LINK, or nil.
LINK may include the `agent-session:' prefix or only its Org handler payload."
  (let ((payload (if (string-prefix-p "agent-session:" link)
                     (substring link (length "agent-session:"))
                   link)))
    (when (string-match "\\`\\([^:]+\\)::\\([^:]+\\)::\\(.*\\)\\'" payload)
      (list (match-string 1 payload)
            (match-string 2 payload)
            (match-string 3 payload)))))

(defun rsr/agent-sessions--org-follow-link (link &optional _arg)
  "Follow an `agent-session:' LINK, jumping to or resuming the session.
LINK is AGENT::SESSION-ID::WORKTREE-PATH, as produced by the `:store'
handler.  Using a dedicated link type (rather than an `elisp:' link) avoids
the confirmation prompt Org shows before running arbitrary elisp."
  (pcase (rsr/agent-sessions--parse-session-link link)
    (`(,agent ,session-id ,worktree)
     (rsr/agent-session-open worktree agent session-id))
    (_ (error "Malformed agent-session link: %s" link))))

(defun rsr/agent-sessions--org-store-link (&optional _interactive)
  "Store a link for the dashboard row at point, or for the session around point.
A shared file or external URL stores its ordinary link; a session row (or a
terminal buffer with a live session) stores an `agent-session:' resume link."
  (cond
   ((and (derived-mode-p 'rsr/agent-sessions-mode)
         (rsr/agent-sessions--link-at-point))
    (rsr/agent-sessions--store-external-link
     (nth 2 (rsr/agent-sessions--link-at-point))))
   ((and (derived-mode-p 'rsr/agent-sessions-mode)
         (rsr/agent-sessions--file-at-point))
    ;; Attachments are nested inside a session row, so resolve them first.
    (rsr/agent-sessions--store-file-link
     (nth 1 (rsr/agent-sessions--file-at-point))))
   (t
    (let ((terminal (rsr/agent-tmux-window-of (current-buffer))))
      (rsr/agent-sessions--store-link-for
       (cond ((derived-mode-p 'rsr/agent-sessions-mode)
              (rsr/agent-sessions--session-at-point))
             ((buffer-local-value 'rsr/agent-session-id terminal)
              (gethash (buffer-local-value 'rsr/agent-session-id terminal)
                       rsr/agent-sessions))))))))

(defun rsr/agent-sessions--sync-default-directory ()
  "Track the worktree/repo at point in `default-directory'.
This makes `C-x p' project commands (and anything else keyed off
`default-directory') operate on the worktree under the cursor."
  (let* ((ctx (rsr/agent-sessions--context-at-point))
         (dir (and ctx (plist-get ctx :path))))
    (when (and dir (file-directory-p dir))
      (setq default-directory (file-name-as-directory dir)))))

(define-derived-mode rsr/agent-sessions-mode magit-section-mode "Agent-Sessions"
  "Major mode listing Claude/Codex sessions running in vterm, as a
repo > worktree > session tree, or repo > folder > session with `f'.
Sections fold with TAB; Shift+TAB toggles overview; `F' manages folders."
  ;; Cut long titles at the window edge rather than wrapping them: the
  ;; dashboard is meant to fit a narrow side window, one line per row.
  (setq-local truncate-lines t)
  (add-hook 'post-command-hook
            #'rsr/agent-sessions--sync-default-directory nil t))

;; `define-derived-mode' sets the parent keymap only when the map has none, and
;; the map itself is a `defvar' that survives reloading this file.  An Emacs
;; that loaded a version of this mode deriving from something else therefore
;; keeps that old parent forever — which cost us TAB: `tabulated-list-mode-map'
;; inherits `button-buffer-map', whose `forward-button' shadowed
;; `magit-section-toggle' ("No button").  Re-point it on every load.
(set-keymap-parent rsr/agent-sessions-mode-map magit-section-mode-map)


;;; Orchestration ------------------------------------------------------------
;;
;; An agent spawning other agents and talking to them.  Everything here is
;; reached from `bin/emacs-agent' over emacsclient, so every entry point
;; *returns* its failures as a string: emacsclient's printed value is the
;; agent's only channel back, exactly as for `rsr/agent-sessions-share-file'.
;;
;; What this deliberately is not: there are no task rows, no dependency graph
;; and no scheduler.  The orchestrator is an agent with a context window; that
;; context *is* the plan, and duplicating it in a table would mean keeping two
;; plans honest.  What Emacs owns is the part an agent cannot do for itself —
;; starting a terminal, addressing another live one, and blocking until it
;; answers.

(defcustom rsr/agent-orchestration-launch-commands
  '((claude . "claude %m \"$(cat %b)\"")
    (codex  . "codex %m \"$(cat %b)\"")
    (pi     . "pi %m \"$(cat %b)\"")
    (agy    . "agy %m -i \"$(cat %b)\""))
  "Shell command per agent type that starts a worker on a task brief.
Rendered with `format-spec':

  %b  path of the brief file `rsr/agent-orchestration-spawn' wrote, quoted
  %m  the model flag for this spawn, or nothing when it named no model
      (spelled by `rsr/agent-orchestration-model-flags')

The brief is read by the shell instead of being passed as a literal argument
because it is a two-kilobyte multi-line prompt, and typing that into a terminal
as one quoted argument is exactly the sort of line a TUI mangles.  `cat' keeps
the typed line short whichever agent is launched, and passing the task at
launch avoids the race that sending it afterwards would have: a TUI that is
still starting silently drops input.

A template written before `%m' existed — one bare `%s' for the brief — still
launches; it just has nowhere to put a model, so a spawn that names one against
that type is refused rather than quietly run on the default model."
  :type '(alist :key-type symbol :value-type string))

(defcustom rsr/agent-orchestration-model-flags
  '((claude . "--model %s")
    (codex  . "--model %s")
    (pi     . "--model %s")
    (agy    . "--model %s"))
  "How each agent type spells \"run on this model\", with %s for the model name.
This is what `%m' in `rsr/agent-orchestration-launch-commands' expands to when a
spawn names a model.  A type with no entry here takes no model, and a spawn
naming one for it is refused: guessing a flag for a CLI we know nothing about
would produce a worker that dies on its own usage message, which reaches the
orchestrator as a worker that simply never reports.

Model *names* are passed through unchecked — they are the agent CLI\='s
vocabulary, not ours, and a list here would be wrong within a release."
  :type '(alist :key-type symbol :value-type string))

(defcustom rsr/agent-orchestration-push-when-idle t
  "When non-nil, automatically hand queued mail to a recipient agent.
Codex mail uses its native session queue, whether the conversation is running
or resting, so it never shares the human's terminal composer.  Claude mail uses
Claude Code's queue-submit action only when its composer is known to be safe.
Mail that arrives while the human is drafting stays unread until the human
submits that prompt, then queues behind it.  Claude's composer safety decides
delivery regardless of message type or stale hook status; Codex retains its
native-queue steering policy.  `emacs-agent wait' remains the explicit way for
an agent to collect its own mail."
  :type 'boolean)

(defcustom rsr/agent-orchestration-claude-queue-submit-key "\C-x\r"
  "Terminal bytes bound to Claude Code's `chat:queueSubmit' action.
The default is Claude Code's default Ctrl+X Enter chord.  Keep this synchronized
with `~/.claude/keybindings.json' if that action is rebound."
  :type 'string)

(defconst rsr/agent-orchestration--submit-delay 0.5
  "Seconds between pasting a message into a TUI and pressing Enter.
The pasted block only becomes the TUI's composed input after it has processed
it; submitting in the same breath submits an empty prompt.")

(defconst rsr/agent-orchestration--native-queue-timeout 5
  "Seconds to wait for an agent's native queue command to acknowledge mail.")

(defcustom rsr/agent-orchestration-codex-empty-prompt-regexp
  "^›[[:blank:]]+Ask Codex to do anything[[:blank:]]*$"
  "Regexp matching Codex's empty idle composer.
This is the one terminal state where delivering mail through the composer is
safe even when the last hook still says the session is running.  In
particular, Codex does not emit a Stop hook when a turn is interrupted, and
its native queue deliberately leaves messages pending while the thread has
that internal state."
  :type 'regexp)

(defvar rsr/agent-orchestration--brief-dir
  (expand-file-name "emacs-agent-briefs/" temporary-file-directory)
  "Where task briefs are written.  Kept after the worker starts, on purpose:
it is the only record of what a worker was actually told, and it is what makes
a launch reproducible by hand (`claude \"$(cat …)\"').")

;;;; Ids and labels

(defun rsr/agent-orchestration--next-id (prefix)
  "An id unique across Emacs restarts, not just within one.
The pid is in it for the same reason it is in a terminal id: stored mail
outlives the Emacs that minted its ids, and a fresh counter would otherwise
hand a new message the id of a stored one."
  (format "%s-%d-%d" prefix (emacs-pid) (cl-incf rsr/agent-orchestration--counter)))

(defun rsr/agent-orchestration--task-title (task)
  "A short label for TASK: its first line, truncated."
  (let* ((line (car (split-string (string-trim task) "\n" t)))
         (line (or line "task")))
    (if (> (length line) 48) (concat (substring line 0 45) "…") line)))

(defun rsr/agent-orchestration--mail-key (id session)
  "The durable identity mail for SESSION in terminal ID is filed under.
The agent's own session id when it has one: that is what `R' resumes, so mail
filed under it comes back attached to the conversation it belongs to.  Failing
that the terminal id, which carries this Emacs's pid — unique for the life of
the terminal and never minted again, so a bare terminal's mail can never be
inherited by an unrelated one that happens to reuse its buffer name.  (Which is
also why mail under a terminal key is not restorable: nothing can resume a bare
shell, so there would be nothing to restore it to.)"
  (let ((sid (plist-get session :agent-session-id)))
    (if sid (list "session" sid) (list "terminal" id))))

(defun rsr/agent-orchestration--mail-insert (msg)
  "Record MSG in the database.  Reported, not raised, on failure: a message
already queued in memory should still be delivered when the record fails."
  (condition-case err
      (sqlite-execute
       (rsr/agent-sessions--db)
       "INSERT OR REPLACE INTO mail
          (id, from_kind, from_key, from_label, to_kind, to_key,
           type, subject, body, files, report, sent_at, read_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)"
       (append (list (plist-get msg :id))
               (plist-get msg :from-key)
               (list (plist-get msg :from-label))
               (plist-get msg :to-key)
               (list (plist-get msg :type)
                     (plist-get msg :subject)
                     (plist-get msg :body)
                     (plist-get msg :files)
                     (plist-get msg :report)
                     (plist-get msg :sent-at))))
    (error (message "agent-sessions: could not record mail (%s)"
                    (error-message-string err)))))

(defun rsr/agent-orchestration--hydrate (id)
  "Load ID's unread mail from the database into its in-memory inbox.
Called when a session's identity becomes known (a hook event) and when an agent
reads its inbox — never from the render path, which must not query the
database.  Safe to call repeatedly: messages already present are skipped by id,
and ids carry the pid of the Emacs that minted them, so one restored from a
previous run cannot collide with one from this one."
  (let* ((session (rsr/agent-sessions--session-for-id id))
         (key (and session (rsr/agent-orchestration--mail-key id session))))
    (when key
      (condition-case err
          (let* ((existing (rsr/agent-orchestration--messages id))
                 (known (mapcar (lambda (m) (plist-get m :id)) existing))
                 (rows (sqlite-select
                        (rsr/agent-sessions--db)
                        "SELECT id, from_kind, from_key, from_label, type, subject,
                                body, files, report, sent_at
                           FROM mail
                          WHERE to_kind = ? AND to_key = ? AND read_at IS NULL
                          ORDER BY sent_at, rowid"
                        key))
                 (fresh nil))
            (pcase-dolist (`(,mid ,fkind ,fkey ,flabel ,type ,subject
                                  ,body ,files ,report ,sent)
                           rows)
              (unless (member mid known)
                (push (list :id mid
                            ;; No `:from': the terminal that sent this belonged
                            ;; to a previous Emacs.  `:from-key' is how a live
                            ;; one is found again, if it was restored too.
                            :from nil :from-key (list fkind fkey) :from-label flabel
                            :to id :to-key key :type type :subject subject
                            :body body :files files :report report
                            :sent-at sent :read nil)
                      fresh)))
            (when fresh
              (puthash id (append existing (nreverse fresh))
                       rsr/agent-orchestration--mail)))
        (error (message "agent-sessions: could not read stored mail (%s)"
                        (error-message-string err)))))))

(defun rsr/agent-orchestration--live-id-for-key (key)
  "Terminal id of the live session filed under durable KEY, or nil.
How a restored conversation is found again: the id it had when it sent a
message is gone, but the identity it was filed under is not."
  (seq-some (lambda (entry)
              (let ((eid (plist-get entry :id)))
                (and (equal key (rsr/agent-orchestration--mail-key
                                 eid (plist-get entry :session)))
                     eid)))
            (rsr/agent-sessions--live-entries)))

(defun rsr/agent-orchestration--sender-terminal (msg)
  "The live terminal id MSG can be answered at, or nil when its sender is gone."
  (let ((from (plist-get msg :from))
        (key (plist-get msg :from-key)))
    (cond ((and from (rsr/agent-sessions--session-for-id from)) from)
          (key (rsr/agent-orchestration--live-id-for-key key)))))

(defun rsr/agent-orchestration--sender-address (msg)
  "The durable address for replying to MSG, or its live terminal id."
  (pcase (plist-get msg :from-key)
    (`("session" ,session-id) session-id)
    (_ (rsr/agent-orchestration--sender-terminal msg))))

;;;; Message rendering

(defun rsr/agent-orchestration--describe-sender (id)
  "How a message from ID is introduced: its agent type and worktree, if live."
  (let ((session (rsr/agent-sessions--session-for-id id)))
    (if (null session)
        " (terminal gone)"
      (format " (%s%s)"
              (plist-get session :agent-type)
              (let ((wt (plist-get session :worktree)))
                (if wt (concat ", " wt) ""))))))

(defun rsr/agent-orchestration--format-message (msg)
  "Render MSG for an agent to read, ending with the command that answers it.
A message restored from the database may have outlived the terminal that sent
it, so the sender is resolved through its durable key: answerable when that
conversation is live again, named but not addressable when it is not."
  (let* ((live (rsr/agent-orchestration--sender-terminal msg))
         (reply-to (rsr/agent-orchestration--sender-address msg))
         (label (or (plist-get msg :from-label) (plist-get msg :from) "unknown")))
    (concat (format "--- $orca (/orca) message from %s%s [%s]\n"
                    (or live label)
                    (if live
                        (rsr/agent-orchestration--describe-sender live)
                      (format " (%s — that terminal is gone)" label))
                    (plist-get msg :type))
            (format "Subject: %s\n" (plist-get msg :subject))
            (let ((body (plist-get msg :body)))
              (if (and body (not (string-empty-p body))) (concat body "\n") ""))
            (let ((files (plist-get msg :files)))
              (if (and files (not (string-empty-p files)))
                  (format "Files: %s\n" files) ""))
            (let ((report (plist-get msg :report)))
              (if (and report (not (string-empty-p report)))
                  (format "Report: %s\n" report) ""))
            (if reply-to
                (format "Reply: emacs-agent send --to %s --type answer --subject \"...\"\n"
                        reply-to)
              "Reply: the sender's terminal is not live here; nothing to reply to.\n"))))

(defun rsr/agent-orchestration--format-messages (messages)
  (concat (format "messages: %d\n" (length messages))
          (mapconcat #'rsr/agent-orchestration--format-message messages "\n")))

;;;; Delivery into a resting terminal

(defun rsr/agent-orchestration--receptive-p (session)
  "Non-nil when SESSION can be handed a message right now.

Two conditions, and both are stated as what they exclude, because the
alternative — enumerating the states that are fine — has already been wrong
once: `needs-attention' becomes `stopped' as soon as the user looks at the
terminal (`rsr/agent-session--clear-attention-on-focus'), which silently ended
delivery to exactly the session an orchestrator is most likely to be watching.

- Not mid-turn.  `running' is the only status that means a turn is in progress;
  anything else is an agent sitting at its prompt, however it got there.
- Something holds the terminal's foreground.  Nil there means the shell's own
  prompt is in front, and a paste plus Enter would not reach a TUI at all — the
  *shell* would run the message as a command line.  That is not merely untidy:
  a message body is written by another agent, and executing it is a hazard the
  queue does not have.  Mail for a bare shell therefore stays queued for
  `emacs-agent check', which is the right way to read it anyway."
  (let ((buf (plist-get session :buffer)))
    (and (not (eq (plist-get session :status) 'running))
         (buffer-live-p buf)
         (rsr/agent-sessions--foreground-command buf)
         t)))

(defun rsr/agent-orchestration--codex-session-p (session)
  "Non-nil when SESSION is a Codex conversation with a durable id."
  (and (equal (downcase (format "%s" (plist-get session :agent-type))) "codex")
       (let ((sid (plist-get session :agent-session-id)))
         (and (stringp sid) (not (string-empty-p sid))))))

(defun rsr/agent-orchestration--codex-empty-prompt-p (session)
  "Non-nil when SESSION visibly has Codex's empty idle composer.
Only inspect the bottom four buffer lines.  An older prompt in terminal
scrollback must not make a running conversation look receptive, and a nonempty
human draft deliberately does not match."
  (let ((buf (plist-get session :buffer)))
    (and (buffer-live-p buf)
         (rsr/agent-sessions--sync-screen buf)
         (with-current-buffer buf
           (save-restriction
             (widen)
             (goto-char (point-max))
             (when (re-search-backward
                    rsr/agent-orchestration-codex-empty-prompt-regexp nil t)
               (<= (count-lines (line-beginning-position) (point-max)) 4)))))))

(defun rsr/agent-orchestration--claude-session-p (session)
  "Non-nil when SESSION is a Claude conversation."
  (equal (downcase (format "%s" (plist-get session :agent-type))) "claude"))

(defun rsr/agent-orchestration--claude-normalize-prompt (text)
  "Normalize Claude prompt TEXT for rendered-versus-submitted comparison."
  (string-trim
   (replace-regexp-in-string "[[:space:]\u00a0]+" " " text)))

(defun rsr/agent-orchestration--face-inherits-p (face parent)
  "Non-nil when FACE names or inherits from PARENT."
  (cond
   ((eq face parent) t)
   ((and (listp face) (keywordp (car face)))
    (rsr/agent-orchestration--face-inherits-p
     (plist-get face :inherit) parent))
   ((listp face)
    (seq-some (lambda (item)
                (rsr/agent-orchestration--face-inherits-p item parent))
              face))))

(defun rsr/agent-orchestration--claude-ghost-completion-p (text)
  "Non-nil when every non-whitespace character in TEXT is Claude ghost text.
Claude renders its Tab completion with the terminal's ANSI faint face.  A
typed prefix is not faint, so a partially accepted or edited completion remains
a real draft rather than becoming eligible for mail delivery.
ghostel draws faint text as a blended `:foreground' with no face to inherit,
so there a pending completion reads as a draft and mail waits for the next
`UserPromptSubmit' — the safe direction to be wrong in.  A tmux proxy's
screen marks faint runs with `rsr/agent-tmux-faint' (see
`rsr/agent-tmux-faint-text'), so tmux keeps the distinction."
  (let ((pos 0)
        (end (length text))
        saw-text
        (all-faint t))
    (while (and all-faint (< pos end))
      (let* ((next (next-property-change pos text end))
             (chunk (substring-no-properties text pos next)))
        (unless (string-match-p "\\`[[:space:]\u00a0]*\\'" chunk)
          (setq saw-text t)
          (unless (seq-some
                   (lambda (faint)
                     (or (rsr/agent-orchestration--face-inherits-p
                          (get-text-property pos 'face text) faint)
                         (rsr/agent-orchestration--face-inherits-p
                          (get-text-property pos 'font-lock-face text) faint)))
                   '(eat-term-faint rsr/agent-tmux-faint))
            (setq all-faint nil)))
        (setq pos next)))
    (and saw-text all-faint)))

(defun rsr/agent-sessions--sync-screen (buf)
  "Make BUF's text the terminal's current screen; return non-nil if usable.
Terminal buffers are their screen already.  A tmux proxy reads its window's;
when that fails it returns nil, so callers treat the screen as unknown."
  (if (rsr/agent-tmux-proxy-p buf)
      (rsr/agent-tmux-refresh-screen buf)
    t))

(defun rsr/agent-orchestration--claude-composer-text (session)
  "Return SESSION's visibly rendered Claude composer text, or nil if unknown.
Claude renders the current input between a line beginning with its `❯' prompt
and a horizontal separator.  Inspect only the most recent prompt near the end
of the terminal buffer."
  (let ((buf (plist-get session :buffer)))
    (and (buffer-live-p buf)
         (rsr/agent-sessions--sync-screen buf)
         (with-current-buffer buf
           (save-restriction
             (widen)
             (goto-char (point-max))
             (when (re-search-backward
                    "^❯[ \t\u00a0]*" (max (point-min) (- (point-max) 4000)) t)
               (let ((input-start (match-end 0)))
                 (and (re-search-forward "^─+[ \t]*$" nil t)
                      ;; Preserve terminal faces: Claude's inline completion is
                      ;; distinguishable from typed input by its ANSI faint
                      ;; styling even though both occupy the composer visually.
                      (buffer-substring
                       input-start (match-beginning 0))))))))))

(defun rsr/agent-orchestration--claude-receptive-composer-p (session)
  "Non-nil when SESSION's Claude composer can safely receive agent mail.
An empty composer is receptive, as is an all-faint inline completion that has
not been accepted.  Claude also retains the last submitted text in the input
box during redraws and sometimes after a turn; that exact text is receptive too
because `UserPromptSubmit' proves it is no longer a draft.  Anything
unrecognized, non-faint, or changed from the submitted prompt is treated as a
live human draft and left untouched."
  (let* ((visible (rsr/agent-orchestration--claude-composer-text session))
         (submitted (plist-get session :submitted-prompt))
         (normalized-visible
          (and (stringp visible)
               (rsr/agent-orchestration--claude-normalize-prompt visible))))
    (and normalized-visible
         (or (string-empty-p normalized-visible)
             (rsr/agent-orchestration--claude-ghost-completion-p visible)
             (and (stringp submitted)
                  (equal normalized-visible
                         (rsr/agent-orchestration--claude-normalize-prompt
                          submitted)))))))

(defun rsr/agent-orchestration--terminal-input (buf string)
  "Send raw terminal input STRING to BUF without paste handling or Enter."
  (with-current-buffer buf
    (cond
     ((derived-mode-p 'vterm-mode) (vterm-send-string string))
     ((derived-mode-p 'eat-mode) (eat-term-send-string eat-terminal string))
     ((derived-mode-p 'ghostel-mode) (ghostel-send-string string))
     ((derived-mode-p 'rsr/agent-tmux-mode)
      (rsr/agent-tmux-send-text rsr/agent-tmux-window string))
     (t (user-error "Current buffer is not an Eat, vterm, ghostel or tmux terminal")))))

(defun rsr/agent-orchestration--call-with-timeout (program args timeout)
  "Run PROGRAM with ARGS, returning its exit status within TIMEOUT seconds.
Process output goes to the current buffer.  Return nil after an error or
timeout, inserting the diagnostic into that buffer.  Unlike `process-file',
this cannot freeze Emacs indefinitely if a native queue client gets stuck."
  (let (process timed-out)
    (condition-case err
        (unwind-protect
            (progn
              (setq process
                    (make-process
                     :name (generate-new-buffer-name "agent-sessions-native-queue")
                     :buffer (current-buffer)
                     :command (cons program args)
                     :connection-type 'pipe
                     :noquery t))
              (let ((deadline (+ (float-time) timeout)))
                (while (and (process-live-p process)
                            (< (float-time) deadline))
                  (accept-process-output
                   process (min 0.1 (max 0 (- deadline (float-time))))))
                (when (process-live-p process)
                  (setq timed-out t)
                  (delete-process process)))
              (if timed-out
                  (progn (insert (format "timed out after %ss" timeout)) nil)
                (process-exit-status process)))
          (when (and process (process-live-p process))
            (delete-process process)))
      (error
       (insert (error-message-string err))
       nil))))

(defun rsr/agent-orchestration--codex-queue (session messages)
  "Queue MESSAGES into running Codex SESSION; return non-nil when accepted.
Use Codex's session-aware command rather than writing into a busy terminal.
Failure deliberately leaves the messages unread for idle delivery or an
explicit inbox check."
  (let ((program (executable-find "codex"))
        (sid (plist-get session :agent-session-id)))
    (when (and program sid)
      (with-temp-buffer
        (let* ((text
                (concat "$orca (/orca) agent mail arrived.\n\n"
                        (rsr/agent-orchestration--format-messages messages)))
               (status
                (rsr/agent-orchestration--call-with-timeout
                 program (list "queue" "--thread" sid "--message" text)
                 rsr/agent-orchestration--native-queue-timeout)))
          (if (and (integerp status) (zerop status))
              t
            (message "agent-sessions: could not queue Codex mail for %s%s"
                     sid
                     (let ((detail (string-trim (buffer-string))))
                       (if (string-empty-p detail) "" (format " (%s)" detail))))
            nil))))))

(defun rsr/agent-orchestration--claude-submit-mail (buf)
  "Queue the prepared agent-mail prompt in Claude BUF."
  (when (buffer-live-p buf)
    (rsr/agent-orchestration--terminal-input
     buf rsr/agent-orchestration-claude-queue-submit-key)))

(defun rsr/agent-orchestration--claude-paste-mail (buf text)
  "Paste agent-mail TEXT into the now-empty composer in Claude BUF."
  (when (buffer-live-p buf)
    (rsr/agent-sessions--terminal-paste buf text)
    (run-at-time rsr/agent-orchestration--submit-delay nil
                 #'rsr/agent-orchestration--claude-submit-mail buf)))

(defun rsr/agent-orchestration--claude-queue (session messages)
  "Queue MESSAGES in Claude SESSION after its composer becomes available.
Claude Code has no session-addressed queue command.  The caller must establish
that the composer is empty, or that `UserPromptSubmit' has just reported the
human's draft submitted.  Delay the paste once so Claude can clear a freshly
submitted prompt, then use its `chat:queueSubmit' action."
  (let ((buf (plist-get session :buffer)))
    (when (buffer-live-p buf)
      (run-at-time
       rsr/agent-orchestration--submit-delay nil
       #'rsr/agent-orchestration--claude-paste-mail buf
       (concat "$orca (/orca) agent mail arrived.\n\n"
               (rsr/agent-orchestration--format-messages messages)))
      t)))

(defun rsr/agent-orchestration--paste (buf text)
  "Paste TEXT into BUF's terminal as one bracketed paste, then submit it.
Bracketed paste rather than plain input because a TUI submits on every newline
it is *typed*, which would fire the agent's turn on the message's first line and
feed it the rest as separate prompts."
  (rsr/agent-sessions--terminal-paste buf text)
  ;; The buffer travels as a timer argument, not in a closure: this file is
  ;; loaded with dynamic binding, so a lambda over `buf' would find it void
  ;; when the timer fires (the same reason `rsr/agent-sessions-restore' passes
  ;; its row this way).
  (run-at-time
   rsr/agent-orchestration--submit-delay nil
   (lambda (target)
     (when (buffer-live-p target)
       (with-current-buffer target
         (pcase (if (derived-mode-p 'rsr/agent-tmux-mode) 'tmux rsr/agent-sessions-terminal)
           ('vterm (vterm-send-return))
           ('eat (eat-term-send-string eat-terminal "\r"))
           ('ghostel (ghostel-send-string "\r"))
           ('tmux (rsr/agent-tmux-send-enter rsr/agent-tmux-window))))))
   buf))

;;; Sending selected text to an agent

(defun rsr/agent-sessions--prompt-agent-p (entry)
  "Non-nil when ENTRY names a live Claude or Codex terminal.
The foreground-process check is important: a registry row survives an agent
exiting back to its shell, where submitting prose would execute it as a shell
command instead of sending it to an agent."
  (let* ((session (plist-get entry :session))
         (buf (plist-get session :buffer))
         (agent (downcase (format "%s" (plist-get session :agent-type))))
         (foreground (and (buffer-live-p buf)
                          (rsr/agent-sessions--foreground-command buf))))
    (and foreground
         (not (equal (plist-get session :last-event) "SessionEnd"))
         (or (member agent '("claude" "codex" "pi" "agy"))
             (member (downcase foreground) '("claude" "codex" "pi" "agy"))))))

(defun rsr/agent-sessions--prompt-entry-viewed-at (entry)
  "Return when ENTRY's terminal was most recently selected, or nil."
  (let ((buf (plist-get (plist-get entry :session) :buffer)))
    (and (buffer-live-p buf)
         (buffer-local-value 'rsr/agent-session--viewed-at buf))))

(defun rsr/agent-sessions--sort-prompt-entries (entries)
  "Return promptable ENTRIES ordered by most recently viewed terminal."
  (sort (copy-sequence entries)
        (lambda (a b)
          (let ((ta (rsr/agent-sessions--prompt-entry-viewed-at a))
                (tb (rsr/agent-sessions--prompt-entry-viewed-at b)))
            (cond ((and ta tb (not (time-equal-p ta tb))) (time-less-p tb ta))
                  (ta t)
                  ((rsr/agent-sessions--entry-created a)
                   (if (rsr/agent-sessions--entry-created b)
                       (time-less-p (rsr/agent-sessions--entry-created b)
                                    (rsr/agent-sessions--entry-created a))
                     t))
                  ((rsr/agent-sessions--entry-created b) nil)
                  (t (string< (rsr/agent-sessions--entry-buffer-name a)
                              (rsr/agent-sessions--entry-buffer-name b))))))))

(defun rsr/agent-sessions--entry-shared-file (entry truename)
  "Return ENTRY's shared-file record for TRUENAME, or nil."
  (seq-find
   (lambda (file)
     (equal (ignore-errors (file-truename (plist-get file :path))) truename))
   (rsr/agent-sessions--session-files (plist-get entry :session))))

(defun rsr/agent-sessions--prompt-entries (source-file)
  "Return live agent entries in picker order for SOURCE-FILE.
The agent that most recently shared SOURCE-FILE comes first.  Every remaining
agent is ordered by when the user last viewed its terminal."
  (let* ((entries (rsr/agent-sessions--sort-prompt-entries
                   (seq-filter #'rsr/agent-sessions--prompt-agent-p
                               (rsr/agent-sessions--live-entries))))
         (truename (and source-file (file-truename source-file)))
         owner owner-updated)
    (when truename
      (dolist (entry entries)
        (when-let ((file (rsr/agent-sessions--entry-shared-file entry truename)))
          (let ((updated (plist-get file :updated-at)))
            (when (or (null owner)
                      (> (or updated 0) (or owner-updated 0)))
              (setq owner entry owner-updated updated))))))
    (if owner
        (cons owner (delq owner entries))
      entries)))

(defun rsr/agent-sessions--prompt-entry-label (entry)
  "Return a unique, human-readable completion label for ENTRY."
  (let* ((session (plist-get entry :session))
         (buf (plist-get session :buffer)))
    (format "%s — %s"
            (buffer-name buf)
            (rsr/agent-sessions--session-label session))))

(defun rsr/agent-sessions--region-prompt (remark selection source beg end)
  "Combine REMARK and SELECTION with their SOURCE location.
BEG and END are the selected buffer positions."
  (let ((where (if source
                   (format "%s, lines %d-%d"
                           (abbreviate-file-name source)
                           (line-number-at-pos beg)
                           (line-number-at-pos (max beg (1- end))))
                 (format "buffer %s, lines %d-%d"
                         (buffer-name)
                         (line-number-at-pos beg)
                         (line-number-at-pos (max beg (1- end)))))))
    (concat (unless (string-empty-p remark) (concat remark "\n\n"))
            (format "Selected text from %s:\n\n" where)
            selection)))

;;;###autoload
(defun rsr/agent-sessions-send-region (beg end)
  "Prompt for a remark and send it with the active region to an agent.
When the current file was shared through the agent dashboard, its sharing
agent is the default choice.  Other live Claude/Codex agents are offered in
most-recently-viewed order."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (user-error "Select some text first")))
  (let* ((source buffer-file-name)
         (selection (buffer-substring-no-properties beg end))
         (entries (rsr/agent-sessions--prompt-entries source)))
    (unless entries
      (user-error "No live Claude or Codex agents are available"))
    (let* ((candidates
            (mapcar (lambda (entry)
                      (cons (rsr/agent-sessions--prompt-entry-label entry) entry))
                    entries))
           ;; Keep the ownership/recency ordering in completion UIs that honor
           ;; standard completion metadata.
           (completion-extra-properties
            '(:display-sort-function identity :cycle-sort-function identity))
           (choice (completing-read "Send region to agent: "
                                    (mapcar #'car candidates) nil t nil nil
                                    (caar candidates)))
           (entry (cdr (assoc choice candidates)))
           (remark (read-string "Question or remark: "))
           (text (rsr/agent-sessions--region-prompt
                  remark selection source beg end))
           (buf (plist-get (plist-get entry :session) :buffer)))
      (unless (and (buffer-live-p buf)
                   (rsr/agent-sessions--foreground-command buf))
        (user-error "The selected agent is no longer running"))
      (rsr/agent-orchestration--paste buf text)
      (message "Sent selected text to %s" (buffer-name buf)))))

(defun rsr/agent-orchestration-deliver (id &optional user-prompt-submitted)
  "Hand ID's pending mail to its agent when safe; return the delivery method.
The result is `delivered' for a generic idle-terminal paste, `queued' for an
agent-specific queue, and nil when mail remains unread.  Called both on arrival
and from the hook path.  USER-PROMPT-SUBMITTED means this call handles a
`UserPromptSubmit' event, so Claude mail withheld behind a human draft can now
be queued.  Terminal delivery consumes before its asynchronous keystrokes to
stay idempotent; Codex consumes only after its CLI acknowledges ownership."
  (when rsr/agent-orchestration-push-when-idle
    (let* ((session (rsr/agent-sessions--session-for-id id))
           (buf (and session (plist-get session :buffer)))
           (pending (and session (rsr/agent-orchestration--pending id))))
      (cond
       ;; An interrupted Codex turn does not fire Stop, so our hook status can
       ;; still say `running' while the TUI is visibly back at its empty prompt.
       ;; Codex accepts native queue writes in that state but intentionally does
       ;; not dispatch them.  Bypass the native queue only for the empty
       ;; composer: a human draft must remain untouched.
       ((and pending
             (rsr/agent-orchestration--codex-session-p session)
             (rsr/agent-orchestration--codex-empty-prompt-p session))
        (rsr/agent-orchestration--consume pending)
        (rsr/agent-orchestration--paste
         buf (concat "$orca (/orca) agent mail arrived while you were idle.\n\n"
                     (rsr/agent-orchestration--format-messages pending)))
        (rsr/agent-sessions--refresh-if-visible)
        'delivered)
       ((and pending
             (rsr/agent-orchestration--codex-session-p session)
             (or (not (eq (plist-get session :status) 'running))
                 (seq-some
                  (lambda (message)
                    (member (plist-get message :type)
                            rsr/agent-orchestration-actionable-message-types))
                  pending)))
        ;; This branch owns Codex delivery even when the command fails.  Do not
        ;; fall through to terminal paste: preserving the human's draft is more
        ;; important than immediate delivery, and the unread record is safe.
        (when (rsr/agent-orchestration--codex-queue session pending)
          (rsr/agent-orchestration--consume pending)
          (rsr/agent-sessions--refresh-if-visible)
          'queued))
       ((and pending
             (rsr/agent-orchestration--claude-session-p session)
             (buffer-live-p buf)
             (rsr/agent-sessions--foreground-command buf))
        ;; This branch owns Claude delivery even when it deliberately waits,
        ;; preventing the generic idle paste below from absorbing a draft.
        (when (and
               (or user-prompt-submitted
                   (rsr/agent-orchestration--claude-receptive-composer-p session))
               (rsr/agent-orchestration--claude-queue session pending))
          (rsr/agent-orchestration--consume pending)
          (rsr/agent-sessions--refresh-if-visible)
          'queued))
       ((and pending (buffer-live-p buf)
             (rsr/agent-orchestration--receptive-p session))
        (rsr/agent-orchestration--consume pending)
        (rsr/agent-orchestration--paste
         buf (concat "$orca (/orca) agent mail arrived while you were idle.\n\n"
                     (rsr/agent-orchestration--format-messages pending)))
        (rsr/agent-sessions--refresh-if-visible)
        'delivered)))))

;;;; The worker brief

(defun rsr/agent-orchestration--worker-preamble (coordinator-id task)
  "The protocol a spawned worker is launched with, followed by TASK."
  (format "You are a worker agent in an Emacs-managed terminal, dispatched by another
agent — your coordinator.  You were started with this file as your prompt.

  Your terminal id   $EMACS_AGENT_SESSION_ID   (`emacs-agent' reads it for you)
  Your coordinator   %s                        (also $EMACS_AGENT_COORDINATOR)
  Your worktree      the directory this shell started in

=== HOW YOU REPORT ===

`emacs-agent' is on your PATH; `emacs-agent guide' prints the full reference.
It is your only channel to the coordinator — do not try to reach a human
through Slack, a PR comment, or anything else during the run.

  # REQUIRED when you finish, including when you fail or give up.  Send it
  # exactly once.  --summary is three sentences: what you did, what you found,
  # what is left.
  emacs-agent done --summary \"...\" [--files a.el,b.el] [--report path/to/notes.md]

  # Blocked on a decision only the coordinator can make.  Blocks until it
  # answers and prints the answer.
  emacs-agent ask --question \"...\" [--timeout 600]

  # A progress note, when there is something worth knowing mid-task.  Optional.
  emacs-agent send --type status --subject \"...\" --body \"...\"

RULES

- Never ask a question through an interactive prompt (no AskUserQuestion, no
  reading stdin).  Your coordinator is another agent and cannot see a TUI
  prompt; your turn would hang until a human noticed.  Use `emacs-agent ask'.
- Failure is still a `done', with a subject that says so.  Never exit silently.
- After `done', end your turn and sit at your prompt.  Do not poll for more
  work and do not start something unrelated; further work arrives as new input.
  Reply to that later mail with the `Reply:' command it includes, which sends an
  `answer' rather than a second `done'.
- You may be sharing this worktree with other workers.  Touch only the files
  your task names, and leave git state alone — no `git add', `commit',
  `checkout', `rebase' or `stash' — unless the task says this worktree is
  yours.  The index and HEAD are shared by everyone in a worktree, so staging
  anything would clobber a co-tenant's work in progress.
- `emacs-share file FILE \"why\"' hands a file to the human in the dashboard.
  That is for the human, and is not a substitute for reporting `done'.

=== YOUR TASK ===

%s"
          coordinator-id (string-trim task)))

(defun rsr/agent-orchestration--write-brief (coordinator-id task)
  "Write the brief for TASK to a file and return its path."
  (make-directory rsr/agent-orchestration--brief-dir t)
  (let ((path (expand-file-name
               (format "%s-%s.md" coordinator-id
                       (rsr/agent-orchestration--next-id "brief"))
               rsr/agent-orchestration--brief-dir)))
    (with-temp-file path
      (insert (rsr/agent-orchestration--worker-preamble coordinator-id task)))
    path))

;;;; Entry points (called from `bin/emacs-agent')

(defcustom rsr/agent-orchestration-trust-new-worktrees t
  "When non-nil, register a spawn's directory as trusted with the agent first.
Both agent CLIs stop at an interactive trust prompt the first time they run in
a directory they have not seen (\"Do you trust the contents of this
directory?\"), and a worker stopped there never reads its brief — so an
orchestrator spawning into a worktree it just created would sit waiting for a
report that cannot come.  Registering the directory up front is what makes an
unattended spawn possible.

The cost is real and worth stating: any directory an orchestrator spawns into
becomes trusted for that agent from then on.  Set this to nil to leave both
configs alone and approve each new directory by hand instead — `spawn' then
says which worker is waiting on you."
  :type 'boolean)

(defcustom rsr/agent-orchestration-claude-config-file
  (expand-file-name "~/.claude.json")
  "Claude Code's own config, where per-directory trust is recorded."
  :type 'file)

(defcustom rsr/agent-orchestration-codex-config-file
  (expand-file-name "~/.codex/config.toml")
  "Codex's config, where per-directory trust is recorded."
  :type 'file)

(defun rsr/agent-orchestration--trust-claude (dir)
  "Record DIR as trusted in Claude Code's config; nil when it already was.
Reads and rewrites through this package's own JSON helpers, so everything else
in that file (it holds the user's whole Claude state) round-trips untouched and
a `.bak' is left behind.  Only written when something actually changes: live
Claude sessions rewrite this file themselves, and every needless write of ours
is another chance to land between one of their reads and writes."
  (let* ((file rsr/agent-orchestration-claude-config-file)
         (config (rsr/agent-sessions--read-json file))
         (projects (or (gethash "projects" config) (make-hash-table :test 'equal)))
         (entry (or (gethash dir projects) (make-hash-table :test 'equal))))
    (unless (eq (gethash "hasTrustDialogAccepted" entry) t)
      (puthash "hasTrustDialogAccepted" t entry)
      (puthash dir entry projects)
      (puthash "projects" projects config)
      (rsr/agent-sessions--write-json file config)
      (format "pre-trusted %s for claude" (abbreviate-file-name dir)))))

(defun rsr/agent-orchestration--trust-codex (dir)
  "Record DIR as trusted in Codex's config; nil when it already had an entry.
Appends a `[projects.\"DIR\"]' table rather than parsing the file: a new table
header is always a legal thing to add at the end of a TOML file, and there is
no TOML reader here that could round-trip the rest of it safely.  An existing
entry is left exactly as it is, even if it says untrusted — that would be the
user's own decision about this directory."
  (let* ((file rsr/agent-orchestration-codex-config-file)
         (header (format "[projects.\"%s\"]" dir))
         (existing (and (file-exists-p file)
                        (with-temp-buffer
                          (insert-file-contents file)
                          (buffer-string)))))
    (unless (and existing (string-search header existing))
      (when (file-exists-p file) (copy-file file (concat file ".bak") t))
      (make-directory (file-name-directory file) t)
      (with-temp-buffer
        (when existing
          (insert existing)
          (unless (string-suffix-p "\n" existing) (insert "\n")))
        (insert (format "\n%s\ntrust_level = \"trusted\"\n" header))
        (write-region (point-min) (point-max) file nil 'quiet))
      (format "pre-trusted %s for codex" (abbreviate-file-name dir)))))

(defun rsr/agent-orchestration--ensure-trusted (agent dir)
  "Make AGENT trust DIR before it is launched there.  Returns a note or nil.
The path is canonicalised because that is what the agent's own process will
see: on macOS a spawn into `/tmp/x' runs in `/private/tmp/x', and a trust entry
under the other spelling would not match.  A config we cannot read is reported
rather than raised: a spawn that works and warns beats a spawn that fails."
  (when rsr/agent-orchestration-trust-new-worktrees
    (let ((path (directory-file-name (file-truename dir))))
      (condition-case err
          (pcase agent
            ('claude (rsr/agent-orchestration--trust-claude path))
            ('codex (rsr/agent-orchestration--trust-codex path))
            ;; A type the user added themselves: we have no idea where it keeps
            ;; trust, so say nothing rather than guess.
            (_ nil))
        (error (format "could not pre-trust %s for %s (%s) — the worker may be sitting at a trust prompt"
                       (abbreviate-file-name path) agent
                       (error-message-string err)))))))

(defcustom rsr/agent-orchestration-codex-skills-dir
  (expand-file-name "~/.codex/skills/")
  "Where Codex looks for skills, in the same `<name>/SKILL.md' layout Claude uses."
  :type 'directory)

(defcustom rsr/agent-orchestration-codex-prompts-dir
  (expand-file-name "~/.codex/prompts/")
  "Where Codex looks for custom prompts, each usable as `/<name>'."
  :type 'directory)

(defconst rsr/agent-orchestration--skill-name "orca"
  "Name the skill is invoked by: `/orca', or `/orca --main' to coordinate.")

(defun rsr/agent-orchestration--skill-dir ()
  "The repo's top-level `skills/orca', which install.sh links for every harness."
  (expand-file-name (format "../../skills/%s/" rsr/agent-orchestration--skill-name)
                    rsr/agent-sessions--dir))

(defun rsr/agent-orchestration--link (target link)
  "Point LINK at TARGET, returning a string describing what happened.
Symlinks rather than copies so editing the guide in this package takes effect
at the agent's next invocation; and refuses to replace anything that is not
already our own link, because both directories belong to the user."
  (cond
   ((and (file-symlink-p link)
         (equal (file-truename link) (file-truename target)))
    (format "%s already linked" (abbreviate-file-name link)))
   ((or (file-exists-p link) (file-symlink-p link))
    (if (file-symlink-p link)
        (progn (delete-file link)
               (make-symbolic-link target link)
               (format "%s relinked" (abbreviate-file-name link)))
      (format "%s exists and is not a symlink — left alone"
              (abbreviate-file-name link))))
   (t
    (make-directory (file-name-directory link) t)
    (make-symbolic-link target link)
    (format "%s linked" (abbreviate-file-name link)))))

;;;###autoload
(defun rsr/agent-orchestration-install-skill ()
  "Make the orchestration skill loadable by Codex as `/orca'.
The repo's install.sh links `skills/orca' for Claude, Pi, agy and
~/.agents like every other skill; this adds what Codex needs beyond that:
its skill directory, and its prompts directory so `/orca' works there as a
slash command too.  The guides themselves are served by `emacs-agent guide',
so what is installed is a stub that cannot go stale.  Idempotent."
  (interactive)
  (let* ((dir (rsr/agent-orchestration--skill-dir))
         (results
          (list
           (rsr/agent-orchestration--link
            (directory-file-name dir)
            (expand-file-name rsr/agent-orchestration--skill-name
                              rsr/agent-orchestration-codex-skills-dir))
           (rsr/agent-orchestration--link
            (expand-file-name "orca-prompt.md" dir)
            (expand-file-name (format "%s.md" rsr/agent-orchestration--skill-name)
                              rsr/agent-orchestration-codex-prompts-dir)))))
    (unless (file-directory-p dir)
      (error "agent-sessions: missing skill directory %s" dir))
    (unless (server-running-p) (server-start))
    (message "agent-sessions: %s" (string-join results "; "))))

(defun rsr/agent-orchestration--model-flag (agent model)
  "Render MODEL as AGENT's model flag, nil when MODEL is empty.
Returns the symbol `unsupported' when a model was asked for and AGENT has no
spelling for one — the caller refuses the spawn rather than launching a worker
on a model nobody chose."
  (let ((model (string-trim (or model ""))))
    (cond
     ((string-empty-p model) nil)
     ((alist-get agent rsr/agent-orchestration-model-flags)
      (format (alist-get agent rsr/agent-orchestration-model-flags)
              (shell-quote-argument model)))
     (t 'unsupported))))

(defun rsr/agent-orchestration--launch-command (template brief model-flag)
  "Render TEMPLATE into the shell line that launches a worker on BRIEF.
MODEL-FLAG is the already-spelled flag or nil.  A template carrying neither
`%b' nor `%m' is the pre-model single-`%s' form and is rendered as such, so an
old customisation keeps working."
  (let ((quoted (shell-quote-argument brief)))
    (if (string-match-p "%[bm]" template)
        (format-spec template `((?b . ,quoted) (?m . ,(or model-flag ""))))
      (format template quoted))))

(defun rsr/agent-orchestration--mark-worker (buf coordinator-id coordinator title)
  "Attach BUF to COORDINATOR-ID as a worker and give it TITLE."
  (let ((parent-sid (plist-get coordinator :agent-session-id)))
    (with-current-buffer buf
      (when parent-sid
        (setq-local rsr/agent-session--branched-from
                    (cons parent-sid
                          (rsr/agent-sessions--session-short-label coordinator))))
      (setq-local rsr/agent-orchestration-coordinator coordinator-id)
      (when (and title (not (string-empty-p title)))
        (setq-local rsr/agent-session-title-override title)))))

(defun rsr/agent-orchestration-spawn (coordinator-id type worktree task
                                                    &optional title model)
  "Start a TYPE agent in WORKTREE on TASK, dispatched by COORDINATOR-ID.
MODEL, when given, is the model name to launch that agent on, spelled into its
command line by `rsr/agent-orchestration-model-flags'.
Returns a string to print.  WORKTREE must already exist: allocating checkouts
is the orchestrator's job, not this package's, so that nothing here can leave a
stray worktree or branch behind."
  (let* ((coordinator (rsr/agent-sessions--session-for-id coordinator-id))
         (agent (and type (not (string-empty-p type)) (intern type)))
         (template (and agent (alist-get agent rsr/agent-orchestration-launch-commands)))
         (model (string-trim (or model "")))
         (model-flag (and agent (rsr/agent-orchestration--model-flag agent model)))
         (dir (and worktree (not (string-empty-p worktree))
                   (file-name-as-directory (expand-file-name worktree)))))
    (cond
     ((null coordinator)
      (format "No Emacs terminal registered for session id %s" coordinator-id))
     ((null template)
      (format "Unknown agent type `%s'; known types: %s" type
              (mapconcat (lambda (cell) (symbol-name (car cell)))
                         rsr/agent-orchestration-launch-commands ", ")))
     ((eq model-flag 'unsupported)
      (format "Agent type `%s' has no --model flag configured; types that take one: %s"
              type
              (if rsr/agent-orchestration-model-flags
                  (mapconcat (lambda (cell) (symbol-name (car cell)))
                             rsr/agent-orchestration-model-flags ", ")
                "none")))
     ((and model-flag (not (string-match-p "%m" template)))
      (format "The launch command for `%s' has no `%%m' for a model flag: %s"
              type template))
     ((or (null dir) (not (file-directory-p dir)))
      (format "No such worktree directory: %s (create it first, or pass one from `emacs-agent worktrees')"
              (or worktree "")))
     ((string-empty-p (string-trim (or task "")))
      "Refusing to spawn a worker with an empty --task")
     (t
      (let* ((trust-note (rsr/agent-orchestration--ensure-trusted agent dir))
             (brief (rsr/agent-orchestration--write-brief coordinator-id task))
             (label (if (and title (not (string-empty-p (string-trim title))))
                        (string-trim title)
                      (rsr/agent-orchestration--task-title task)))
             ;; `--create-terminal' shows the new terminal in another window,
             ;; which is right when the user pressed `+' and wrong when an agent
             ;; spawned three workers in a row: the layout the user is reading
             ;; must not be rearranged by a background action.  The buffer and
             ;; its process outlive the restored configuration.
             (buf (save-window-excursion
                    (let ((rsr/agent-sessions--extra-terminal-env
                           (list "EMACS_AGENT_ROLE=worker"
                                 (format "EMACS_AGENT_COORDINATOR=%s" coordinator-id)
                                 (format "EMACS_AGENT_TASK_BRIEF=%s" brief))))
                      (rsr/agent-sessions--create-terminal
                       dir (plist-get (rsr/agent-session--repo-info dir) :worktree))))))
        (if (not (buffer-live-p buf))
            "Could not create a terminal for the worker"
          (let ((worker-id (buffer-local-value 'rsr/agent-session-id buf)))
            (rsr/agent-orchestration--mark-worker
             buf coordinator-id coordinator label)
            (rsr/agent-sessions--terminal-send
             buf (rsr/agent-orchestration--launch-command template brief model-flag))
            (rsr/agent-sessions--refresh-if-visible)
            (format "Spawned %s (%s) in %s\nTask: %s\nBrief: %s%s"
                    worker-id
                    (if (string-empty-p model) type (format "%s, %s" type model))
                    (abbreviate-file-name dir) label brief
                    (if trust-note (concat "\nNote: " trust-note) "")))))))))

;;;; Launched sessions (called from bin/agent-launch)

(defun rsr/agent-sessions-launch-spawn (parent-id session cwd name attach title
                                                  command env &optional detached
                                                  attach-label opener-id)
  "Open a session window for `agent-launch' and type COMMAND into it.
The launcher (`bin/agent-launch', used by the workflow stage keys, review and
bug-fix children, and explore-session) calls this over emacsclient so the new
session gets what only Emacs can give it: a tracked id in its environment
(hooks, the session log, restore, `emacs-share') and a dashboard row.  The
script keeps every other decision — the command, its environment, the tmux
window options — so that its plain-tmux fallback opens the same session.

PARENT-ID, when non-empty, is the terminal id of the session this one is a
child of: the row nests under it and the child learns it as
`EMACS_AGENT_PARENT'.  SESSION, when non-empty, is the tmux session to open
in (a child shares its parent's); otherwise the usual repository-derived
target applies.  CWD is the working directory, NAME the window name, ATTACH a
file to show under the new row (labelled ATTACH-LABEL, default \"brief\"),
TITLE the row's title, COMMAND the shell line that starts the agent and ENV
its extra `VAR=VALUE' entries, one per line.  DETACHED non-nil leaves the
current tmux window selected.  Emacs's own window layout is never rearranged.
OPENER-ID is the terminal a top-level session was opened from, when it was
opened from a dashboard session: the new session starts in that session's
folder, as a fork starts in its parent's, without being nested under it.
Returns \"Opened WINDOW TERMINAL-ID\" on success; failures are returned as
text because emacsclient's printed value is the script's only channel back."
  (let* ((parent-id (and parent-id (not (string-empty-p parent-id)) parent-id))
         (parent (and parent-id (rsr/agent-sessions--session-for-id parent-id)))
         (opener (and opener-id (not (string-empty-p opener-id)) (null parent)
                      (rsr/agent-sessions--session-for-id opener-id)))
         (session (and session (not (string-empty-p session)) session))
         (cwd (and cwd (not (string-empty-p cwd))
                   (file-name-as-directory (expand-file-name cwd))))
         (attach (and attach (not (string-empty-p attach)) (expand-file-name attach)))
         (title (and title (not (string-empty-p title)) title))
         (name (if (or (null name) (string-empty-p name)) "session" name))
         (env (and env (split-string env "\n" t))))
    (cond
     ((and parent-id (null parent))
      (format "No Emacs terminal registered for session id %s" parent-id))
     ((or (null cwd) (not (file-directory-p cwd)))
      (format "No such directory for the session: %s" (or cwd "")))
     ((and attach (not (file-exists-p attach)))
      (format "No file to attach at %s" attach))
     ((string-empty-p (string-trim (or command "")))
      "Refusing to open a session with an empty command")
     (t
      (let ((buf (save-window-excursion
                   (let ((rsr/agent-sessions-terminal 'tmux)
                         (rsr/agent-tmux--target (if session (cons session cwd)
                                                   rsr/agent-tmux--target))
                         (rsr/agent-sessions--tmux-window-options
                          (list :name name :detached detached :silent t))
                         (rsr/agent-sessions--extra-terminal-env
                          (append env
                                  (and parent-id
                                       (list (format "EMACS_AGENT_PARENT=%s" parent-id))))))
                     (condition-case err
                         (rsr/agent-sessions--create-terminal cwd name)
                       (error (error-message-string err)))))))
        (cond
         ((stringp buf) buf)
         ((not (buffer-live-p buf)) "Could not create a terminal for the session")
         (t
          (let ((parent-sid (and parent (plist-get parent :agent-session-id)))
                (child-id (buffer-local-value 'rsr/agent-session-id buf)))
            (with-current-buffer buf
              (when parent-sid
                (setq-local rsr/agent-session--branched-from
                            (cons parent-sid
                                  (rsr/agent-sessions--session-short-label parent))))
              ;; The opener's folder is a default the first hook persists
              ;; (`rsr/agent-sessions--folder-hydrate') only when the new
              ;; session lands in the folder's repo.
              (when-let* ((folder (and opener
                                       (rsr/agent-sessions--folder-for-session
                                        opener))))
                (setq-local rsr/agent-session--folder-id folder))
              (when title
                (setq-local rsr/agent-session-title-override title)))
            ;; The brief is what the session was told; it belongs under its
            ;; row, and reading it there clears it like any attachment.
            (when attach
              (rsr/agent-sessions--share-file
               (rsr/agent-sessions--session-for-id child-id) attach
               (or attach-label "brief")))
            (rsr/agent-sessions--terminal-send buf command)
            (rsr/agent-sessions--refresh-if-visible)
            (format "Opened %s %s"
                    (buffer-local-value 'rsr/agent-tmux-window buf) child-id)))))))))

;;;; Exploration children (called from skills/explore-session/scripts/open-window.sh)

(defun rsr/agent-sessions-explore-spawn (parent-id session cwd name dir slug
                                                   command env &optional detached)
  "Open an exploration child window for the agent in terminal PARENT-ID.
Kept for callers of the original interface; `rsr/agent-sessions-launch-spawn'
does the work.  SESSION is the parent's tmux session, which the child must
share; DIR holds `brief.md', which is attached to the child's row; SLUG titles
the row `explore: SLUG'; NAME defaults to `explore-SLUG'.  See
`rsr/agent-sessions-launch-spawn' for the rest."
  (let* ((brief (and dir (not (string-empty-p dir))
                     (expand-file-name "brief.md" dir)))
         (slug (string-trim (or slug "")))
         (name (if (or (null name) (string-empty-p name))
                   (concat "explore-" slug)
                 name)))
    (cond
     ((null (rsr/agent-sessions--session-for-id parent-id))
      (format "No Emacs terminal registered for session id %s" parent-id))
     ((or (null session) (string-empty-p session))
      "No tmux session named for the child")
     ((or (null brief) (not (file-exists-p brief)))
      (format "No brief at %s (write it first)" (or brief "")))
     ((string-empty-p slug) "Refusing to open an exploration with no slug")
     ((string-empty-p (string-trim (or command "")))
      "Refusing to open an exploration with an empty command")
     (t
      (rsr/agent-sessions-launch-spawn
       parent-id session cwd name brief (format "explore: %s" slug)
       command env detached "exploration brief")))))

(defun rsr/agent-orchestration--logged-recipient (value &optional by-agent-session)
  "Return the most recent resumable session matching VALUE.
Match an agent session id when BY-AGENT-SESSION is non-nil, otherwise a
terminal id."
  (when-let ((row (car (sqlite-select
                        (rsr/agent-sessions--db)
                        (concat
                         "SELECT agent_type, agent_sid, worktree, title
                           FROM sessions
                          WHERE " (if by-agent-session "agent_sid" "emacs_sid") " = ?
                            AND agent_type IS NOT NULL
                            AND agent_sid IS NOT NULL
                          ORDER BY opened_at DESC, id DESC
                          LIMIT 1")
                        (list value)))))
    (pcase-let ((`(,agent-type ,agent-sid ,worktree ,title) row))
      (list :agent-type agent-type :agent-session-id agent-sid
            :worktree worktree :worktree-path worktree :title title))))

(defun rsr/agent-orchestration--link-recipient (address)
  "Return resumable session metadata encoded by agent-session ADDRESS."
  (when (string-prefix-p "agent-session:" address)
    (pcase (rsr/agent-sessions--parse-session-link address)
      (`(,agent ,session-id ,worktree)
       (list :agent-type agent :agent-session-id session-id
             :worktree worktree :worktree-path worktree)))))

(defun rsr/agent-orchestration--live-session-recipient (session-id)
  "Resolve agent SESSION-ID to (TERMINAL-ID SESSION nil), or nil."
  (when-let* ((buf (rsr/agent-sessions--buffer-for-agent-session session-id))
              (id (buffer-local-value 'rsr/agent-session-id buf))
              (session (rsr/agent-sessions--session-for-id id)))
    (list id session nil)))

(defun rsr/agent-orchestration--resumable-recipient (address recipient)
  "Resolve RECIPIENT metadata to a live terminal or revival from ADDRESS."
  (when recipient
    (let ((key (rsr/agent-orchestration--mail-key address recipient)))
      (if-let ((current (rsr/agent-orchestration--live-id-for-key key)))
          (list current (rsr/agent-sessions--session-for-id current) nil)
        (list address recipient t)))))

(defun rsr/agent-orchestration--resolve-recipient (address)
  "Resolve ADDRESS to (CURRENT-ID SESSION REVIVE-P), or nil.
ADDRESS may be a terminal id, raw agent session id, or `agent-session:' link."
  (or (when-let ((session (rsr/agent-sessions--session-for-id address)))
        (list address session nil))
      (when-let ((link (rsr/agent-orchestration--link-recipient address)))
        (or (rsr/agent-orchestration--live-session-recipient
             (plist-get link :agent-session-id))
            (rsr/agent-orchestration--resumable-recipient address link)))
      (rsr/agent-orchestration--live-session-recipient address)
      (rsr/agent-orchestration--resumable-recipient
       address (rsr/agent-orchestration--logged-recipient address))
      (rsr/agent-orchestration--resumable-recipient
       address (rsr/agent-orchestration--logged-recipient address t))))

(defun rsr/agent-orchestration--revive-recipient
    (coordinator-id coordinator recipient message)
  "Resume RECIPIENT as COORDINATOR-ID's child and submit MESSAGE.
Return the new terminal id."
  (let* ((prompt (concat "$orca (/orca) agent mail revived this session.\n\n"
                         (rsr/agent-orchestration--format-message message)))
         (buf (save-window-excursion
                (let ((rsr/agent-sessions--extra-terminal-env
                       (list "EMACS_AGENT_ROLE=worker"
                             (format "EMACS_AGENT_COORDINATOR=%s"
                                     coordinator-id))))
                  (rsr/agent-session-start
                   (plist-get recipient :worktree-path)
                   (plist-get recipient :agent-type)
                   (plist-get recipient :agent-session-id)
                   prompt))))
         (id (and (buffer-live-p buf)
                  (buffer-local-value 'rsr/agent-session-id buf)))
         (title (plist-get recipient :title)))
    (unless id
      (error "Could not create a terminal for the revived session"))
    (rsr/agent-orchestration--mark-worker
     buf coordinator-id coordinator title)
    id))

(defun rsr/agent-orchestration--store-message (id message)
  "Record MESSAGE in terminal ID's in-memory and durable mailboxes."
  (plist-put message :to id)
  (rsr/agent-orchestration--mail-insert message)
  (puthash id (append (rsr/agent-orchestration--messages id) (list message))
           rsr/agent-orchestration--mail))

(defun rsr/agent-orchestration-send (from-id to type subject body files report)
  "Send a message from FROM-ID to TO, reviving a killed recipient if needed."
  (let ((type (if (or (null type) (string-empty-p type)) "status" type))
        (sender (rsr/agent-sessions--session-for-id from-id)))
    (cond
     ((null sender)
      (format "No Emacs terminal registered for session id %s" from-id))
     ((not (member type rsr/agent-orchestration-message-types))
      (format "Unknown message type `%s'; known types: %s" type
              (string-join rsr/agent-orchestration-message-types ", ")))
     ((or (null to) (string-empty-p to))
      "A message needs a --to (an Emacs terminal id)")
     ((or (null subject) (string-empty-p (string-trim subject)))
      "A message needs a --subject")
     (t
      (if-let ((resolved (rsr/agent-orchestration--resolve-recipient to)))
          (pcase-let* ((`(,current-id ,recipient ,revive-p) resolved)
                       (msg (list :id (rsr/agent-orchestration--next-id "msg")
                                  :from from-id
                                  :from-key (rsr/agent-orchestration--mail-key
                                             from-id sender)
                                  :from-label (rsr/agent-sessions--session-short-label
                                               sender)
                                  :to current-id
                                  :to-key (rsr/agent-orchestration--mail-key
                                           current-id recipient)
                                  :type type :subject (string-trim subject)
                                  :body (or body "") :files (or files "")
                                  :report (or report "")
                                  :sent-at (rsr/agent-sessions--now) :read nil)))
            (condition-case err
                (progn
                  (when revive-p
                    (setq current-id
                          (rsr/agent-orchestration--revive-recipient
                           from-id sender recipient msg)))
                  (rsr/agent-orchestration--store-message current-id msg)
                  (let ((delivery
                         (if revive-p
                             (progn
                               (rsr/agent-orchestration--consume (list msg))
                               'revived)
                           (rsr/agent-orchestration-deliver current-id))))
                    (rsr/agent-sessions--refresh-if-visible)
                    (concat
                     (format "Sent %s to %s" type to)
                     (let ((details nil))
                       (when revive-p
                         (push (format "revived as %s" current-id) details))
                       (when (and (not revive-p) (not (equal current-id to)))
                         (push (format "routed to %s" current-id) details))
                       (pcase delivery
                         ('queued (push "queued into agent" details))
                         ('delivered (push "delivered to idle agent" details)))
                       (if details
                           (format " (%s)" (string-join (nreverse details) "; "))
                         "")))))
              (error (format "Could not send to recipient %s%s: %s"
                             to (if revive-p " while reviving it" "")
                             (error-message-string err)))))
        (format "No live or resumable agent session for recipient %s" to))))))

(defun rsr/agent-orchestration-check (id types consume)
  "Return ID's unread mail, marking it read unless CONSUME is nil.
TYPES is a comma-separated filter or nil."
  (if (null (rsr/agent-sessions--session-for-id id))
      (format "No Emacs terminal registered for session id %s" id)
    (rsr/agent-orchestration--hydrate id)
    (let* ((filter (and types (not (string-empty-p types))
                        (split-string types "," t "[ \t]+")))
           (unknown (seq-remove
                     (lambda (candidate)
                       (member candidate rsr/agent-orchestration-message-types))
                     (or filter '()))))
      (if unknown
          (format "Unknown message type(s) in --types: %s" (string-join unknown ", "))
        (let ((pending (rsr/agent-orchestration--pending id filter)))
          (when consume (rsr/agent-orchestration--consume pending))
          (when pending (rsr/agent-sessions--refresh-if-visible))
          (rsr/agent-orchestration--format-messages pending))))))

(defun rsr/agent-orchestration-wait-check (id types)
  "Consume and return all of ID's mail, stopping on TYPES.
The first output line is `wait: stop', `wait: continue', or `wait: error'.
TYPES only controls the stop decision; every pending message is returned and
consumed in the same snapshot so progress cannot become stale or race a later
terminal message."
  (if (null (rsr/agent-sessions--session-for-id id))
      (format "wait: error\nNo Emacs terminal registered for session id %s" id)
    (rsr/agent-orchestration--hydrate id)
    (let* ((filter (and types (not (string-empty-p types))
                        (split-string types "," t "[ \t]+")))
           (unknown (seq-remove
                     (lambda (candidate)
                       (member candidate rsr/agent-orchestration-message-types))
                     (or filter '())))
           (pending (rsr/agent-orchestration--pending id)))
      (if unknown
          (format "wait: error\nUnknown message type(s) in --types: %s"
                  (string-join unknown ", "))
        (let ((stop (and pending
                         (or (null filter)
                             (seq-some (lambda (message)
                                         (member (plist-get message :type) filter))
                                       pending)))))
          (rsr/agent-orchestration--consume pending)
          (when pending (rsr/agent-sessions--refresh-if-visible))
          (concat (if stop "wait: stop\n" "wait: continue\n")
                  (rsr/agent-orchestration--format-messages pending)))))))

(defun rsr/agent-orchestration-list (id)
  "Describe the workers ID spawned, and ID's own coordinator if it has one."
  (if (null (rsr/agent-sessions--session-for-id id))
      (format "No Emacs terminal registered for session id %s" id)
    (let* ((entries (rsr/agent-sessions--live-entries))
           (mine (seq-filter
                  (lambda (entry)
                    (let ((buf (plist-get (plist-get entry :session) :buffer)))
                      (and (buffer-live-p buf)
                           (equal id (buffer-local-value
                                      'rsr/agent-orchestration-coordinator buf)))))
                  entries))
           (buf (plist-get (rsr/agent-sessions--session-for-id id) :buffer))
           (my-coordinator (and (buffer-live-p buf)
                                (buffer-local-value
                                 'rsr/agent-orchestration-coordinator buf))))
      (concat
       (if my-coordinator (format "your coordinator: %s\n" my-coordinator) "")
       (format "workers: %d\n" (length mine))
       (mapconcat
        (lambda (entry)
          (let* ((wid (plist-get entry :id))
                 (session (plist-get entry :session))
                 (unread (rsr/agent-orchestration--pending-count wid)))
            (format "%s  %-7s %-15s %s%s\n"
                    wid
                    (plist-get session :agent-type)
                    (plist-get session :status)
                    (or (plist-get entry :title) "")
                    (if (> unread 0) (format "  (%d unread for it)" unread) ""))))
        mine "")))))

(defun rsr/agent-orchestration-worktrees (id)
  "List the worktrees of ID's repo with what is running in each.
Reads git rather than the render path's cache: the caller is about to allocate
a worktree, and a cache that predates the last `git worktree add' would hand
out one that is already taken — or hide one that just became available."
  (let ((session (rsr/agent-sessions--session-for-id id)))
    (if (null session)
        (format "No Emacs terminal registered for session id %s" id)
      (let* ((root (or (plist-get session :repo-root)
                       (let ((buf (plist-get session :buffer)))
                         (and (buffer-live-p buf)
                              (plist-get (rsr/agent-sessions--buffer-repo-info buf)
                                         :repo-root)))))
             (worktrees (and root (rsr/agent-sessions--compute-worktrees root)))
             (entries (rsr/agent-sessions--live-entries)))
        (if (null worktrees)
            "Not inside a git repository Emacs knows about"
          (concat
           (format "repo: %s\n" (abbreviate-file-name root))
           (mapconcat
            (lambda (wt)
              (let* ((path (plist-get wt :path))
                     (canon (rsr/agent-sessions--canonical-path path))
                     (busy (seq-filter
                            (lambda (entry)
                              (equal canon (rsr/agent-sessions--canonical-path
                                            (plist-get (plist-get entry :session)
                                                       :worktree-path))))
                            entries))
                     (dirty (let ((default-directory path))
                              (ignore-errors (magit-anything-modified-p)))))
                ;; A count rather than free/busy: several agents can share a
                ;; worktree when their writes do not overlap, so what the
                ;; caller needs is who is there, not our verdict on whether it
                ;; may use the place.
                (format "%-9s %-40s %-28s %-6s%s\n"
                        (format "%d agent%s" (length busy)
                                (if (= (length busy) 1) "" "s"))
                        (abbreviate-file-name path)
                        (plist-get wt :label)
                        (if dirty "dirty" "clean")
                        (if busy
                            (concat "  "
                                    (mapconcat
                                     (lambda (entry)
                                       (format "%s(%s)"
                                               (plist-get (plist-get entry :session) :agent-type)
                                               (plist-get (plist-get entry :session) :status)))
                                     busy " "))
                          ""))))
            worktrees "")))))))

;;; Creating worktrees ------------------------------------------------------
;;
;; `Z' (Magit's worktree key) makes a worktree for a branch inside a plain folder named after the
;; repo, next to the main checkout: REPO/<branch>/ beside REPO/<main's branch>/.
;; A repo not yet laid out so is offered a migration first.  The repo's name
;; is recorded in its git config, because its main checkout's folder is now
;; a branch name (see `rsr/agent-tmux-recorded-repo-name').

(defcustom rsr/agent-sessions-worktree-agent nil
  "Optional command override for `Z', including any command-line flags.
When nil, use `rsr/agent-sessions-default-agent'.  A prefix argument ignores
this override and launches the alternate of the configured default agent."
  :type '(choice (const :tag "Use default agent" nil) string))

(defcustom rsr/agent-sessions-symlink-directories
  '(("~" . 1) ("~/.claude" . 4) ("~/.codex" . 4) ("~/.pi" . 4) ("~/.agents" . 4)
    ("~/.config" . 4) ("~/.emacs.d" . 2) ("~/.local/bin" . 1))
  "(DIRECTORY . DEPTH) searched for symlinks into a repo about to be migrated.
A migration moves the repo's files, which breaks every link into them."
  :type '(alist :key-type directory :value-type integer))

(defcustom rsr/agent-sessions-history-directories
  '(("~/.claude/projects" . claude) ("~/.pi/agent/sessions" . pi))
  "(DIRECTORY . AGENT) of agent session stores with one folder per path.
Claude keeps a project's sessions and memory in a folder named after the
path it ran in, and pi its sessions; a migration offers to rename those
folders so the agents still find them at the repo's new path."
  :type '(alist :key-type directory :value-type symbol))

(defun rsr/agent-sessions--history-folder-name (agent path)
  "The folder name AGENT's history store gives PATH."
  (let ((path (directory-file-name path)))
    (pcase agent
      ('claude (replace-regexp-in-string "[^A-Za-z0-9]" "-" path))
      ('pi (concat "--" (replace-regexp-in-string
                         "[/\\:]" "-" (string-remove-prefix "/" path))
                   "--")))))

(defun rsr/agent-sessions--history-folder-cwd (folder)
  "The directory the sessions in history FOLDER ran in, read from a transcript."
  (seq-some (lambda (file)
              (with-temp-buffer
                (ignore-errors (insert-file-contents file nil 0 65536))
                (and (re-search-forward "\"cwd\" *: *\"\\([^\"]+\\)\"" nil t)
                     (match-string 1))))
            (directory-files folder t "\\.jsonl\\'")))

(defun rsr/agent-sessions--path-under-p (path root)
  "Non-nil when PATH is ROOT or inside it; both are expanded first."
  (and path
       (string-prefix-p (file-name-as-directory (expand-file-name root))
                        (file-name-as-directory (expand-file-name path)))))

(defun rsr/agent-sessions--move-path (path old new)
  "PATH, which is under directory OLD, moved under directory NEW."
  (concat (directory-file-name new)
          (substring (directory-file-name (expand-file-name path))
                     (length (directory-file-name (expand-file-name old))))))

(defun rsr/agent-sessions--history-moves (old new)
  "(FROM . TO) for each history folder of the sessions run under OLD.
TO is the folder the same session would have under NEW.  A folder whose
transcripts name no directory is matched only by its exact name."
  (let (moves)
    (pcase-dolist (`(,store . ,agent) rsr/agent-sessions-history-directories)
      (let* ((store (expand-file-name store))
             (stem (string-remove-suffix
                    "--" (rsr/agent-sessions--history-folder-name agent old))))
        (when (file-directory-p store)
          (dolist (name (directory-files store nil "\\`[^.]"))
            (let ((folder (expand-file-name name store)))
              (when (and (string-prefix-p stem name) (file-directory-p folder))
                (let* ((cwd (rsr/agent-sessions--history-folder-cwd folder))
                       (target
                        (cond ((rsr/agent-sessions--path-under-p cwd old)
                               (rsr/agent-sessions--move-path cwd old new))
                              ((and (null cwd)
                                    (equal name (rsr/agent-sessions--history-folder-name
                                                 agent old)))
                               new))))
                  (when target
                    (push (cons folder
                                (expand-file-name
                                 (rsr/agent-sessions--history-folder-name agent target)
                                 store))
                          moves)))))))))
    (nreverse moves)))

(defun rsr/agent-sessions--symlinks-into (root)
  "(LINK . TARGET) for each symlink under the configured directories into ROOT.
See `rsr/agent-sessions-symlink-directories'."
  (let ((roots (delete-dups (list (expand-file-name root) (file-truename root))))
        links)
    (pcase-dolist (`(,dir . ,depth) rsr/agent-sessions-symlink-directories)
      (let ((dir (expand-file-name dir)))
        (when (file-directory-p dir)
          (dolist (link (ignore-errors
                          (process-lines "find" dir "-maxdepth" (number-to-string depth)
                                         "-type" "l")))
            (when-let* ((target (file-symlink-p link))
                        (target (expand-file-name target (file-name-directory link))))
              (when (seq-some (lambda (r) (rsr/agent-sessions--path-under-p target r))
                              roots)
                (push (cons link target) links)))))))
    (nreverse links)))

(defun rsr/agent-sessions--migration-unsaved (root)
  "Names of the buffers visiting files under ROOT with unsaved changes."
  (delq nil (mapcar (lambda (buf)
                      (with-current-buffer buf
                        (and buffer-file-name (buffer-modified-p)
                             (rsr/agent-sessions--path-under-p buffer-file-name root)
                             (buffer-name buf))))
                    (buffer-list))))

(defun rsr/agent-sessions--terminal-backend (buf)
  "The `rsr/agent-sessions-terminal' backend terminal BUF runs on."
  (with-current-buffer buf
    (cond ((derived-mode-p 'rsr/agent-tmux-mode) 'tmux)
          ((derived-mode-p 'vterm-mode) 'vterm)
          ((derived-mode-p 'eat-mode) 'eat)
          ((derived-mode-p 'ghostel-mode) 'ghostel)
          (t rsr/agent-sessions-terminal))))

(defun rsr/agent-sessions--migration-terminals (root)
  "What a migration of ROOT stops and brings back: one plist per terminal.
Every terminal whose directory is under ROOT, with what reopening it needs:
:buffer, :backend, :dir, :name, :folder, and for an agent :agent-type,
:agent-sid, :title and :running.  A `*tmux: S*' client is left out: it
shows a session rather than running in a directory."
  (let ((sessions (make-hash-table :test 'eq)))
    (maphash (lambda (_id session)
               (when (buffer-live-p (plist-get session :buffer))
                 (puthash (plist-get session :buffer) session sessions)))
             rsr/agent-sessions)
    (delq nil
          (mapcar
           (lambda (buf)
             (let* ((session (gethash buf sessions))
                    (dir (or (plist-get session :worktree-path)
                             (buffer-local-value 'default-directory buf))))
               (when (and (or session
                              (with-current-buffer buf
                                (or (derived-mode-p 'rsr/agent-tmux-mode)
                                    (and (derived-mode-p 'vterm-mode 'eat-mode
                                                         'ghostel-mode)
                                         (get-buffer-process buf)))))
                          (not (string-prefix-p "*tmux: " (buffer-name buf)))
                          (rsr/agent-sessions--path-under-p dir root))
                 (list :buffer buf
                       :backend (rsr/agent-sessions--terminal-backend buf)
                       :dir dir
                       :name (buffer-name buf)
                       :folder (rsr/agent-sessions--folder-for-session
                                (or session (list :buffer buf :repo-root root)))
                       :agent-type (plist-get session :agent-type)
                       :agent-sid (plist-get session :agent-session-id)
                       :title (buffer-local-value 'rsr/agent-session-title-override buf)
                       :running (eq (plist-get session :status) 'running)))))
           (buffer-list)))))

(defun rsr/agent-sessions--migration-panes (root)
  "(PANE SESSION COMMAND) for each tmux pane under ROOT no terminal stands for.
These are closed by a migration and not brought back: a shell opened in
tmux directly, say, which Emacs has no record of."
  (let ((windows (mapcar (lambda (b) (buffer-local-value 'rsr/agent-tmux-window b))
                         (rsr/agent-tmux-proxies))))
    (delq nil
          (mapcar (lambda (line)
                    (pcase (split-string line "\t")
                      (`(,pane ,session ,window ,command ,path)
                       (and (not (member window windows))
                            (rsr/agent-sessions--path-under-p path root)
                            (list pane session command)))))
                  (split-string (or (rsr/agent-tmux--output
                                     "list-panes" "-a" "-F"
                                     (concat "#{pane_id}\t#{session_name}\t#{window_id}"
                                             "\t#{pane_current_command}\t#{pane_current_path}"))
                                    "")
                                "\n" t)))))

(defun rsr/agent-sessions--migration-stop (terminals panes)
  "Close TERMINALS and tmux PANES before their directory moves."
  (dolist (terminal terminals)
    (when-let ((buf (plist-get terminal :buffer)))
      (when (buffer-live-p buf)
        ;; Bound in the buffer: a tmux proxy's close prompt is a buffer-local
        ;; member, and the migration has already asked.
        (with-current-buffer buf
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf))))))
  (dolist (pane panes)
    (rsr/agent-tmux--ok "kill-pane" "-t" (car pane))))

(defun rsr/agent-sessions--migration-reopen-quietly (terminal old new)
  "Reopen TERMINAL out of sight, reporting rather than signalling a failure.
Run from a timer: by then `Z' has shown the new worktree's agent, and a
terminal shown now would land in whatever window is selected, the dashboard
included."
  (condition-case err
      (save-window-excursion
        (rsr/agent-sessions--migration-reopen terminal old new))
    (error (message "agent-sessions: %s" (error-message-string err)))))

(defun rsr/agent-sessions--migration-reopen (terminal old new)
  "Reopen TERMINAL, closed while its directory moved from under OLD to NEW.
An agent is resumed in its conversation; one never used, and a plain
terminal, start afresh."
  (let* ((dir (file-name-as-directory
               (rsr/agent-sessions--move-path (plist-get terminal :dir) old new)))
         (type (plist-get terminal :agent-type))
         (sid (plist-get terminal :agent-sid))
         (rsr/agent-sessions-terminal (plist-get terminal :backend))
         (rsr/agent-tmux--target nil)
         (buf (if (and type sid
                       (not (rsr/agent-sessions--never-saved-p
                             (list :agent-type type :agent-sid sid))))
                  (rsr/agent-session-start dir (intern type) sid)
                (let ((buf (rsr/agent-sessions--create-terminal dir)))
                  (when type (rsr/agent-sessions--terminal-send buf type))
                  buf))))
    (when (buffer-live-p buf)
      (when-let ((title (plist-get terminal :title)))
        (with-current-buffer buf
          (setq-local rsr/agent-session-title-override title)))
      (when-let ((folder (plist-get terminal :folder)))
        (ignore-errors
          (rsr/agent-sessions--folder-set
           (list :buffer buf :repo-root (rsr/agent-sessions--canonical-path
                                         (plist-get (rsr/agent-session--repo-info dir)
                                                    :repo-root)))
           folder)))
      (rsr/agent-sessions--refresh-if-visible))
    buf))

(defun rsr/agent-sessions--git (dir &rest args)
  "Run git with ARGS in DIR; return (STATUS . OUTPUT)."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (cons (apply #'process-file magit-git-executable nil t nil args)
            (string-trim (buffer-string))))))

(defun rsr/agent-sessions--git-or-error (dir &rest args)
  "Run git with ARGS in DIR and return its output; signal its error on failure."
  (pcase-let ((`(,status . ,output) (apply #'rsr/agent-sessions--git dir args)))
    (unless (eq status 0)
      (user-error "git %s failed: %s" (car args) output))
    output))

(defun rsr/agent-sessions--worktree-folder-name (branch)
  "The folder a worktree of BRANCH gets: BRANCH with each `/' made `-'."
  (replace-regexp-in-string "/" "-" branch))

(defun rsr/agent-sessions--db-move-paths (old new)
  "Rewrite every stored path under directory OLD to the same path under NEW.
Folders, manual order and the session log all key on paths, so this keeps
them attached to a repo that moved.  A row the rewrite would collide with
an existing one is left as it was."
  (let* ((db (rsr/agent-sessions--db))
         (old (directory-file-name old))
         (new (directory-file-name new))
         (prefix (concat old "/")))
    (dolist (table (mapcar #'car (sqlite-select
                                  db "SELECT name FROM sqlite_master
                                       WHERE type = 'table'
                                         AND name NOT LIKE 'sqlite_%'")))
      (dolist (column (sqlite-select db (format "PRAGMA table_info(\"%s\")" table)))
        (when (string-equal-ignore-case (nth 2 column) "TEXT")
          (let ((col (nth 1 column)))
            (sqlite-execute
             db (format "UPDATE OR IGNORE \"%s\" SET \"%s\" = ? || substr(\"%s\", ?)
                          WHERE substr(\"%s\", 1, ?) = ?"
                        table col col col)
             (list (concat new "/") (1+ (length prefix)) (length prefix) prefix))
            (sqlite-execute
             db (format "UPDATE OR IGNORE \"%s\" SET \"%s\" = ? WHERE \"%s\" = ?"
                        table col col)
             (list new old))))))
    (setq rsr/agent-sessions--folders-loaded-p nil
          rsr/agent-sessions--order nil)))

(defun rsr/agent-sessions--repoint-buffers (old new)
  "Point the buffers under directory OLD at NEW, after the repo moved there.
Magit and Dired buffers cache paths of their own, so those are killed."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (cond ((and buffer-file-name
                  (rsr/agent-sessions--path-under-p buffer-file-name old))
             (let ((modified (buffer-modified-p)))
               (set-visited-file-name
                (rsr/agent-sessions--move-path buffer-file-name old new) t)
               (set-buffer-modified-p modified)))
            ((not (rsr/agent-sessions--path-under-p default-directory old)))
            ((derived-mode-p 'magit-mode 'dired-mode) (kill-buffer buf))
            (t (setq default-directory
                     (file-name-as-directory
                      (rsr/agent-sessions--move-path default-directory old new))))))))

(defun rsr/agent-sessions--migration-report (root main links history
                                                    &optional terminals panes)
  "Show what migrating ROOT to MAIN will do.
LINKS and HISTORY are the symlinks and history folders found, TERMINALS and
PANES what is running there and will be stopped."
  (with-current-buffer (get-buffer-create "*agent-sessions migration*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Move %s\n  to %s\n" root main))
      (when terminals
        (insert "\nStopped, then brought back in the new place:\n")
        (dolist (terminal terminals)
          (insert (format "  %s%s%s\n" (plist-get terminal :name)
                          (if (plist-get terminal :agent-sid)
                              (format " (%s, resumed)" (plist-get terminal :agent-type))
                            "")
                          (if (plist-get terminal :running)
                              "  mid-turn: its current turn is lost"
                            "")))))
      (when panes
        (insert "\ntmux panes closed and not brought back:\n")
        (pcase-dolist (`(,pane ,session ,command) panes)
          (insert (format "  %s in session %s (%s)\n" pane session command))))
      (when-let ((stale (seq-filter (lambda (dir)
                                      (rsr/agent-sessions--path-under-p dir root))
                                    load-path)))
        (insert "\nEmacs load-path entries that will point at the old path:\n")
        (dolist (dir stale) (insert "  " dir "\n")))
      (when links
        (insert "\nSymlinks that will break:\n")
        (pcase-dolist (`(,link . ,target) links)
          (insert (format "  %s -> %s\n" (abbreviate-file-name link) target))))
      (when history
        (insert "\nAgent history folders named after the old path:\n")
        (pcase-dolist (`(,from . ,to) history)
          (insert (format "  %s\n    -> %s\n" (abbreviate-file-name from)
                          (file-name-nondirectory to)))))
      (goto-char (point-min))
      (special-mode))
    (display-buffer (current-buffer))))

(defun rsr/agent-sessions--migrate-repo (root)
  "Move the checkout at ROOT into ROOT/<its branch>/; return the new main root.
Asks first, and refuses while a file under ROOT has unsaved changes.  What
runs in ROOT is stopped and brought back at the new path.  Afterwards the linked
worktrees are repaired, the repo's name recorded, the dashboard's stored
paths moved, and, if chosen, symlinks and agent history re-pointed."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (name (file-name-nondirectory (directory-file-name root)))
         (branch (or (magit-get-current-branch)
                     (user-error "%s is not on a branch; check one out first" name)))
         (folder (rsr/agent-sessions--worktree-folder-name branch))
         (main (file-name-as-directory (expand-file-name folder root))))
    (when-let ((unsaved (rsr/agent-sessions--migration-unsaved root)))
      (user-error "Save these before migrating %s: %s"
                  name (string-join unsaved ", ")))
    (let* ((terminals (rsr/agent-sessions--migration-terminals root))
           (panes (rsr/agent-sessions--migration-panes root))
           (links (rsr/agent-sessions--symlinks-into root))
           (history (rsr/agent-sessions--history-moves root main))
           (linked (seq-remove
                    (lambda (path) (rsr/agent-sessions--path-under-p path root))
                    (mapcar #'car (let ((default-directory root))
                                    (magit-list-worktrees))))))
      (pcase-let
          ((`(,repoint ,move-history)
            ;; The report is on screen only while the questions are asked;
            ;; left there, its window is where `Z' shows the new agent.
            (save-window-excursion
              (rsr/agent-sessions--migration-report
               root main links history terminals panes)
              (unless (y-or-n-p
                       (concat (format "%s is not in the %s/<branch> layout.  Migrate it"
                                       name name)
                               (if (or terminals panes)
                                   (format ", stopping what runs there (%d)? "
                                           (+ (length terminals) (length panes)))
                                 "? ")))
                (user-error "Not migrated"))
              (list (and links (y-or-n-p (format "Re-point the %d symlink%s to %s? "
                                                 (length links)
                                                 (if (cdr links) "s" "")
                                                 (abbreviate-file-name main))))
                    (and history
                         (y-or-n-p (format "Rename the %d agent history folder%s? "
                                           (length history)
                                           (if (cdr history) "s" ""))))))))
        (rsr/agent-sessions--migration-stop terminals panes)
        (let ((temp (make-temp-name (concat (directory-file-name root) ".migrating-"))))
          (rename-file (directory-file-name root) temp)
          (condition-case err
              (progn (make-directory root)
                     (rename-file temp (directory-file-name main)))
            (error
             (ignore-errors (delete-directory root))
             (rename-file temp (directory-file-name root))
             (signal (car err) (cdr err)))))
        (when linked
          (apply #'rsr/agent-sessions--git-or-error main "worktree" "repair" linked))
        (rsr/agent-sessions--git-or-error main "config" "agent-sessions.repo-name" name)
        (rsr/agent-sessions--db-move-paths root main)
        (unless (equal root (file-truename root))
          (rsr/agent-sessions--db-move-paths (file-truename root) (file-truename main)))
        (rsr/agent-sessions--repoint-buffers root main)
        (when repoint
          (pcase-dolist (`(,link . ,target) links)
            (make-symbolic-link (rsr/agent-sessions--move-path
                                 target
                                 (if (rsr/agent-sessions--path-under-p target root)
                                     root
                                   (file-truename root))
                                 main)
                                link t)))
        (when move-history
          (pcase-dolist (`(,from . ,to) history)
            (if (file-exists-p to)
                (message "Left %s: %s already exists" from to)
              (rename-file from to))))
        ;; Staggered, as `rsr/agent-sessions-restore-previous' does: terminals
        ;; opened in one go leave their shells racing their own startup.  The
        ;; terminal goes to the timer as an argument: this file is dynamically
        ;; bound, so a lambda would find `terminal' unbound when it ran.
        (seq-do-indexed (lambda (terminal n)
                          (run-at-time (* n 1.0) nil
                                       #'rsr/agent-sessions--migration-reopen-quietly
                                       terminal root main))
                        terminals)
        (message "Migrated %s to %s" name (abbreviate-file-name main))
        main))))

(defun rsr/agent-sessions--adopt-layout (root)
  "Offer to record ROOT's parent as the repo folder; return ROOT if accepted.
For a checkout already named after its branch, which is laid out as
REPO/<branch>/ but was never migrated, so nothing recorded its name."
  (let ((parent (file-name-nondirectory
                 (directory-file-name (file-name-directory (directory-file-name root))))))
    (when (y-or-n-p (format "%s is already named after its branch.  Use %s as the repo folder? "
                            (abbreviate-file-name root) parent))
      (rsr/agent-sessions--git-or-error root "config" "agent-sessions.repo-name" parent)
      root)))

(defun rsr/agent-sessions--add-worktree (main)
  "Add a worktree beside MAIN, the repo's main checkout, for a branch asked for.
Asks for the branch: an existing local branch is checked out, a remote
branch gets a local one tracking it, and a new name is created from a
starting point asked for as Magit's branch commands ask.  Returns
\(BRANCH . PATH)."
  (let* ((default-directory main)
         (branch (magit-completing-read "Worktree for branch"
                                        (magit-list-branch-names)
                                        nil nil nil 'magit-revision-history))
         (local (cond ((magit-local-branch-p branch) branch)
                      ((magit-remote-branch-p branch)
                       (cdr (magit-split-branch-name branch)))
                      (t branch)))
         (path (expand-file-name (rsr/agent-sessions--worktree-folder-name local)
                                 (file-name-directory (directory-file-name main)))))
    (when (file-exists-p path)
      (user-error "%s already exists" (abbreviate-file-name path)))
    (cond ((magit-local-branch-p local)
           (rsr/agent-sessions--git-or-error main "worktree" "add" path local))
          ((magit-remote-branch-p branch)
           (rsr/agent-sessions--git-or-error main "worktree" "add" "-b" local path branch))
          (t
           (rsr/agent-sessions--git-or-error main "check-ref-format" "--branch" local)
           (rsr/agent-sessions--git-or-error
            main "worktree" "add" "-b" local path
            (magit-read-starting-point "Create branch" local))))
    (cons local (file-name-as-directory path))))

(defun rsr/agent-sessions-new-worktree (&optional prefix)
  "Create a worktree for a branch and start an agent in it.
The repo is the one at point in the dashboard, else the current buffer's.
The worktree goes in REPO/<branch>/, beside the main checkout, a `/' in the
branch name made `-'; a repo not laid out so is offered a migration first.
The worktree gets a folder of the same name, and a tmux session in which
the configured default agent starts.  With PREFIX, start the alternate agent.
An explicit `rsr/agent-sessions-worktree-agent' overrides the normal command."
  (interactive "P")
  (let* ((command (if prefix (rsr/agent-sessions-select-agent t)
                    (or rsr/agent-sessions-worktree-agent
                        (rsr/agent-sessions-select-agent))))
         (repo-section (and (derived-mode-p 'rsr/agent-sessions-mode)
                            (rsr/agent-sessions--enclosing-section
                             'rsr/agent-session-repo)))
         (root (or (and repo-section (plist-get (oref repo-section value) :root))
                   (plist-get (rsr/agent-session--repo-info default-directory)
                              :repo-root)
                   (user-error "No repo at point")))
         (root (file-name-as-directory (expand-file-name root)))
         (main (let ((default-directory root))
                 (cond ((rsr/agent-tmux-recorded-repo-name root) root)
                       ((and (magit-get-current-branch)
                             (equal (file-name-nondirectory (directory-file-name root))
                                    (rsr/agent-sessions--worktree-folder-name
                                     (magit-get-current-branch))))
                        (or (rsr/agent-sessions--adopt-layout root)
                            (rsr/agent-sessions--migrate-repo root)))
                       (t (rsr/agent-sessions--migrate-repo root)))))
         (added (rsr/agent-sessions--add-worktree main))
         (path (cdr added))
         (name (file-name-nondirectory (directory-file-name path)))
         (folder (rsr/agent-sessions--folder-create
                  name (rsr/agent-sessions--canonical-path main)))
         (buf (let ((rsr/agent-sessions-terminal 'tmux)
                    (rsr/agent-tmux--target nil))
                (rsr/agent-sessions--create-terminal path name))))
    (clrhash rsr/agent-sessions--worktrees-cache)
    (rsr/agent-sessions--folder-set (list :buffer buf :repo-root main)
                                    (plist-get folder :id))
    (rsr/agent-sessions--terminal-send buf command)
    (rsr/agent-sessions--refresh-if-visible)
    (rsr/agent-sessions--goto-terminal-row buf)
    (message "Worktree %s on %s" (abbreviate-file-name path) (car added))
    buf))

(defun rsr/agent-sessions-describe-mode ()
  "Show the dashboard's help in the window beside it.
`describe-mode' uses `display-buffer''s default, which splits the window
beside the side-window dashboard; replace it instead, as opening a session
does.  `q' in the help puts the window's previous buffer back."
  (interactive)
  (let ((display-buffer-overriding-action rsr/agent-tmux-other-window-action))
    (describe-mode)))

(define-key rsr/agent-sessions-mode-map (kbd "RET") #'rsr/agent-sessions-jump)
(define-key rsr/agent-sessions-mode-map (kbd "?") #'rsr/agent-sessions-describe-mode)
(define-key rsr/agent-sessions-mode-map (kbd "h") #'rsr/agent-sessions-describe-mode)
;; `o' is "other window", as in dired, ibuffer and occur.
(define-key rsr/agent-sessions-mode-map (kbd "o") #'rsr/agent-sessions-jump-other-window)
(define-key rsr/agent-sessions-mode-map (kbd "d") #'rsr/agent-sessions-show-file-diff)
(define-key rsr/agent-sessions-mode-map (kbd "v") #'rsr/agent-sessions-display)
(define-key rsr/agent-sessions-mode-map (kbd "V") #'rsr/agent-sessions-display-or-browse)
(define-key rsr/agent-sessions-mode-map (kbd "w") #'rsr/agent-sessions-copy-attachment)
(define-key rsr/agent-sessions-mode-map (kbd "k") #'rsr/agent-sessions-kill)
(define-key rsr/agent-sessions-mode-map (kbd "b") #'rsr/agent-sessions-branch)
(define-key rsr/agent-sessions-mode-map (kbd "B") #'rsr/agent-sessions-mark-parent)
(define-key rsr/agent-sessions-mode-map (kbd "D")
  #'rsr/agent-sessions-submission-diff-or-detach-parent)
(define-key rsr/agent-sessions-mode-map (kbd "t") #'rsr/agent-sessions-cycle-state)
(define-key rsr/agent-sessions-mode-map (kbd "SPC") #'rsr/agent-sessions-edit-title)
(define-key rsr/agent-sessions-mode-map (kbd "u") #'rsr/agent-sessions-mark-unread)
(define-key rsr/agent-sessions-mode-map (kbd "m") #'rsr/agent-sessions-mark-unread)
(define-key rsr/agent-sessions-mode-map (kbd "e") #'rsr/agent-sessions-edit-note)
(define-key rsr/agent-sessions-mode-map (kbd "R") #'rsr/agent-sessions-restore)
(define-key rsr/agent-sessions-mode-map (kbd "g") #'rsr/agent-sessions-refresh)
(define-key rsr/agent-sessions-mode-map (kbd "<backtab>")
  #'rsr/agent-sessions-toggle-overview)
(define-key rsr/agent-sessions-mode-map (kbd "<S-tab>")
  #'rsr/agent-sessions-toggle-overview)
(define-key rsr/agent-sessions-mode-map (kbd "s") #'rsr/agent-sessions-toggle-sort)
(define-key rsr/agent-sessions-mode-map (kbd "S") #'rsr/agent-sessions-toggle-attention-sort)
(define-key rsr/agent-sessions-mode-map (kbd "F") #'rsr/agent-sessions-folder-action)
(define-key rsr/agent-sessions-mode-map (kbd "+") #'rsr/agent-sessions-new-vterm)
(define-key rsr/agent-sessions-mode-map (kbd "Z") #'rsr/agent-sessions-new-worktree)
(define-key rsr/agent-sessions-mode-map (kbd "n") #'rsr/agent-sessions-next)
(define-key rsr/agent-sessions-mode-map (kbd "p") #'rsr/agent-sessions-prev)
(define-key rsr/agent-sessions-mode-map (kbd "N") #'rsr/agent-sessions-next-attention)
(define-key rsr/agent-sessions-mode-map (kbd "P") #'rsr/agent-sessions-prev-attention)
(define-key rsr/agent-sessions-mode-map (kbd "M-n") #'rsr/agent-sessions-move-down)
(define-key rsr/agent-sessions-mode-map (kbd "M-p") #'rsr/agent-sessions-move-up)
(define-key rsr/agent-sessions-mode-map (kbd "C-c C-o") #'rsr/agent-sessions-clear-manual-order)

;;; Wiring our hooks into Claude Code / Codex ------------------------------
;;
;; Both agents read a `{"hooks": {EVENT: [GROUP ...]}}' JSON config; each GROUP
;; is `{"hooks": [{"type":"command","command":SCRIPT,...}], ["matcher":M]}'.  We
;; own exactly the groups whose command runs one of our forwarder scripts (by
;; filename), so we can add/remove them idempotently while leaving every other
;; hook (orca's, the user's) untouched.

(defcustom rsr/agent-sessions-claude-settings-file
  (expand-file-name "~/.claude/settings.json")
  "Claude Code user settings file that `rsr/agent-sessions-install' wires."
  :type 'file)

(defcustom rsr/agent-sessions-codex-hooks-file
  (expand-file-name "~/.codex/hooks.json")
  "Codex hooks file that `rsr/agent-sessions-install' wires."
  :type 'file)

(defcustom rsr/agent-sessions-agy-hooks-file
  (expand-file-name "~/.gemini/config/hooks.json")
  "Antigravity CLI (agy) hooks file that `rsr/agent-sessions-install' wires."
  :type 'file)

(defcustom rsr/agent-sessions-pi-extension-file
  (expand-file-name "~/.pi/agent/extensions/agent-sessions-pi-hook.ts")
  "Where `rsr/agent-sessions-install' installs the Pi event forwarder.
Pi has no hooks.json — extensions are plain files in this directory — so
installation is a copy, and uninstallation a delete."
  :type 'file)

(defcustom rsr/agent-sessions-claude-hook-events
  '("SessionStart" "SessionEnd" "UserPromptSubmit" "Stop" "StopFailure"
    "SubagentStop" "TeammateIdle"
    ("PreToolUse" . "*") ("PostToolUse" . "*") ("PermissionRequest" . "*"))
  "Claude hook events to forward to the dashboard.
Each item is either an event name, or (EVENT . MATCHER) for tool-scoped events.
`SessionEnd' earns its place by closing the session's log row the moment the
agent exits, so `R' can offer it back while its terminal is still sitting
there at a shell prompt.  Codex has no equivalent event; there the end is
noticed when the terminal dies or another session starts in it."
  :type '(repeat (choice string (cons string string))))

(defcustom rsr/agent-sessions-codex-hook-events
  '("SessionStart" "UserPromptSubmit" "PreToolUse" "PostToolUse"
    "PermissionRequest" "Stop")
  "Codex hook events to forward to the dashboard."
  :type '(repeat (choice string (cons string string))))

(defconst rsr/agent-sessions--claude-hook-script "agent-sessions-claude-hook.sh")
(defconst rsr/agent-sessions--codex-hook-script "agent-sessions-codex-hook.sh")
(defconst rsr/agent-sessions--pi-hook-script "agent-sessions-pi-hook.ts")
(defconst rsr/agent-sessions--agy-hook-script "agent-sessions-agy-hook.sh")

(defcustom rsr/agent-sessions-agy-hook-events
  '("SessionStart" "PreInvocation" ("PostToolUse" . "*") "Stop")
  "agy hook events to forward to the dashboard.
Each item is an event name, or (EVENT . MATCHER) for tool-scoped events."
  :type '(repeat (choice string (cons string string))))

(defconst rsr/agent-sessions--agy-hook-name "agent-sessions"
  "Our named hook in agy's hooks.json, beside other tools' (orca's).")

(defun rsr/agent-sessions--read-json (file)
  "Parse FILE as JSON into hash-tables + lists, or an empty object if absent.
Signals a `user-error' (rather than clobbering) if FILE holds invalid JSON."
  (if (file-exists-p file)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            ;; Arrays as vectors (not lists): native `json-serialize' treats a
            ;; Lisp list as an alist/plist object, so JSON arrays must round-trip
            ;; as vectors to come back out as arrays.
            (json-parse-buffer :object-type 'hash-table :array-type 'array
                               :null-object :null :false-object :false))
        (error (user-error "agent-sessions: %s is not valid JSON (%s); left untouched"
                           file (error-message-string err))))
    (make-hash-table :test 'equal)))

(defun rsr/agent-sessions--write-json (file obj)
  "Write OBJ to FILE as pretty-printed JSON, backing up any existing FILE.
`json-serialize' returns a *unibyte* string of UTF-8 bytes.  Inserted as-is,
every non-ASCII character becomes a run of raw bytes, and `json-pretty-print-
buffer' then re-encodes each of those as literal `\\302\\267' escape text —
so a round-trip silently rewrites `·' as four visible characters, and does it
to every em dash and accent in the file.  Decoding first is what makes the
round-trip lossless."
  (make-directory (file-name-directory file) t)
  (when (file-exists-p file)
    (copy-file file (concat file ".bak") t))
  (let ((coding-system-for-write 'utf-8))
    (with-temp-file file
      (insert (decode-coding-string
               (json-serialize obj :null-object :null :false-object :false)
               'utf-8))
      (json-pretty-print-buffer))))

(defun rsr/agent-sessions--our-group-p (group script)
  "Non-nil if hook GROUP runs our SCRIPT (matched by basename)."
  (let ((cmds (and (hash-table-p group) (gethash "hooks" group)))
        (name (regexp-quote (file-name-nondirectory script))))
    (and (vectorp cmds)
         (seq-some (lambda (h)
                     (let ((c (and (hash-table-p h) (gethash "command" h))))
                       (and (stringp c) (string-match-p name c))))
                   cmds))))

(defun rsr/agent-sessions--make-group (script matcher)
  "Build a hook GROUP hash-table running SCRIPT, with optional MATCHER."
  (let ((cmd (make-hash-table :test 'equal))
        (grp (make-hash-table :test 'equal)))
    (puthash "type" "command" cmd)
    (puthash "command" script cmd)
    (puthash "timeout" 10 cmd)
    (when matcher (puthash "matcher" matcher grp))
    (puthash "hooks" (vector cmd) grp)
    grp))

(defun rsr/agent-sessions--strip-hooks (events-map script)
  "Remove our SCRIPT groups from EVENTS-MAP, dropping events left empty.
Returns t when anything was removed."
  (let (changed drop)
    (maphash
     (lambda (event groups)
       (let* ((orig (if (vectorp groups) (append groups nil) nil))
              (kept (seq-remove (lambda (g) (rsr/agent-sessions--our-group-p g script))
                                orig)))
         (unless (= (length kept) (length orig)) (setq changed t))
         (if kept (puthash event (vconcat kept) events-map)
           (push event drop))))
     events-map)
    (dolist (event drop) (remhash event events-map))
    changed))

(defun rsr/agent-sessions--wire (file events script)
  "Add SCRIPT hook groups for EVENTS into FILE's `hooks' map, idempotently.
Strips any stale groups of ours first (so re-running after moving the package
or editing the event list self-heals), then appends fresh ones."
  (let* ((root (rsr/agent-sessions--read-json file))
         (hooks (let ((h (gethash "hooks" root)))
                  (if (hash-table-p h) h (make-hash-table :test 'equal)))))
    (rsr/agent-sessions--strip-hooks hooks script)
    (dolist (ev events)
      (let* ((event (if (consp ev) (car ev) ev))
             (matcher (and (consp ev) (cdr ev)))
             (existing (gethash event hooks))
             (base (if (vectorp existing) existing [])))
        (puthash event
                 (vconcat base (vector (rsr/agent-sessions--make-group script matcher)))
                 hooks)))
    (puthash "hooks" hooks root)
    (rsr/agent-sessions--write-json file root)))

(defun rsr/agent-sessions--unwire (file script)
  "Remove our SCRIPT hook groups from FILE, leaving other hooks intact.
Returns t if FILE was changed."
  (when (file-exists-p file)
    (let* ((root (rsr/agent-sessions--read-json file))
           (hooks (gethash "hooks" root)))
      (when (and (hash-table-p hooks)
                 (rsr/agent-sessions--strip-hooks hooks script))
        (if (zerop (hash-table-count hooks))
            (remhash "hooks" root)
          (puthash "hooks" hooks root))
        (rsr/agent-sessions--write-json file root)
        t))))

(defun rsr/agent-sessions--wire-pi (script)
  "Install the Pi extension SCRIPT into `rsr/agent-sessions-pi-extension-file'.
Pi has no hooks config to edit; extensions are whole files in
`~/.pi/agent/extensions/', so wiring is a fresh copy — re-running after
editing the source self-heals."
  (make-directory (file-name-directory rsr/agent-sessions-pi-extension-file) t)
  (copy-file script rsr/agent-sessions-pi-extension-file t))

(defun rsr/agent-sessions--wire-agy (script)
  "Set our named hook in `rsr/agent-sessions-agy-hooks-file' to run SCRIPT.
agy's hooks.json maps hook names to their events, so ours is one entry,
replaced whole on every run; an event's handlers are listed directly, and a
tool event's are wrapped in a matcher group.  SCRIPT gets the event name as
its argument because agy's payload does not carry it."
  (let ((root (rsr/agent-sessions--read-json rsr/agent-sessions-agy-hooks-file))
        (spec (make-hash-table :test 'equal)))
    (dolist (ev rsr/agent-sessions-agy-hook-events)
      (let* ((event (if (consp ev) (car ev) ev))
             (handler (make-hash-table :test 'equal)))
        (puthash "type" "command" handler)
        (puthash "command" (format "%s %s" (shell-quote-argument script) event) handler)
        (puthash "timeout" 10 handler)
        (puthash event
                 (if (consp ev)
                     (let ((group (make-hash-table :test 'equal)))
                       (puthash "matcher" (cdr ev) group)
                       (puthash "hooks" (vector handler) group)
                       (vector group))
                   (vector handler))
                 spec)))
    (puthash rsr/agent-sessions--agy-hook-name spec root)
    (rsr/agent-sessions--write-json rsr/agent-sessions-agy-hooks-file root)))

(defun rsr/agent-sessions--unwire-agy ()
  "Remove our named hook from agy's hooks.json.  Returns t if it was there."
  (let ((file rsr/agent-sessions-agy-hooks-file))
    (when (file-exists-p file)
      (let ((root (rsr/agent-sessions--read-json file)))
        (when (gethash rsr/agent-sessions--agy-hook-name root)
          (remhash rsr/agent-sessions--agy-hook-name root)
          (rsr/agent-sessions--write-json file root)
          t)))))

(defun rsr/agent-sessions--unwire-pi ()
  "Remove the installed Pi extension.  Returns t if anything was removed."
  (let ((file rsr/agent-sessions-pi-extension-file))
    (when (file-exists-p file)
      (delete-file file)
      t)))

;;;###autoload
(defun rsr/agent-sessions-install (&optional force)
  "Wire this package's hooks into Claude Code, Codex, Pi and agy.
So a `claude'/`codex'/`pi'/`agy' run in any Emacs terminal reports to the dashboard,
without depending on any external tool (e.g. orca).  Idempotent — re-run any
time: after installing a second agent, moving this package, changing the hook
event lists, or removing orca.  Only touches hook entries pointing at this
package's own forwarder scripts; other hooks are left as-is.

Wires Claude when `~/.claude' exists, Codex when `~/.codex' exists, Pi
when `~/.pi' exists, and agy when `~/.gemini' exists; with a prefix arg (FORCE)
wires all regardless,
creating the config as needed.  Also starts the Emacs server, which the
hooks need to reach us."
  (interactive "P")
  (let ((claude-script (expand-file-name rsr/agent-sessions--claude-hook-script
                                         rsr/agent-sessions--dir))
        (codex-script (expand-file-name rsr/agent-sessions--codex-hook-script
                                        rsr/agent-sessions--dir))
        (pi-script (expand-file-name rsr/agent-sessions--pi-hook-script
                                     rsr/agent-sessions--dir))
        (agy-script (expand-file-name rsr/agent-sessions--agy-hook-script
                                      rsr/agent-sessions--dir))
        done)
    (dolist (s (list claude-script codex-script pi-script agy-script))
      (if (file-exists-p s)
          (set-file-modes s #o755)
        (error "agent-sessions: missing hook script %s" s)))
    (when (or force (file-directory-p
                     (file-name-directory rsr/agent-sessions-claude-settings-file)))
      (rsr/agent-sessions--wire rsr/agent-sessions-claude-settings-file
                               rsr/agent-sessions-claude-hook-events claude-script)
      (push "Claude" done))
    (when (or force (file-directory-p
                     (file-name-directory rsr/agent-sessions-codex-hooks-file)))
      (rsr/agent-sessions--wire rsr/agent-sessions-codex-hooks-file
                               rsr/agent-sessions-codex-hook-events codex-script)
      (push "Codex" done))
    (when (or force (file-directory-p "~/.pi"))
      (rsr/agent-sessions--wire-pi pi-script)
      (push "Pi" done))
    (when (or force (file-directory-p "~/.gemini"))
      (rsr/agent-sessions--wire-agy agy-script)
      (push "agy" done))
    (unless (server-running-p) (server-start))
    (if done
        (message "agent-sessions: wired %s (server running)"
                 (string-join (nreverse done) " + "))
      (message "agent-sessions: none of ~/.claude, ~/.codex, ~/.pi, ~/.gemini found; use `C-u M-x rsr/agent-sessions-install' to force"))))

;;;###autoload
(defun rsr/agent-sessions-uninstall ()
  "Remove this package's hooks from Claude Code, Codex, Pi and agy config.
Leaves every other hook (orca's, yours) intact, and leaves the forwarder
scripts on disk.  Safe to run whether or not `rsr/agent-sessions-install' ran."
  (interactive)
  (let ((changed (delq nil
                       (list (and (rsr/agent-sessions--unwire
                                   rsr/agent-sessions-claude-settings-file
                                   rsr/agent-sessions--claude-hook-script)
                                  "Claude")
                             (and (rsr/agent-sessions--unwire
                                   rsr/agent-sessions-codex-hooks-file
                                   rsr/agent-sessions--codex-hook-script)
                                  "Codex")
                             (and (rsr/agent-sessions--unwire-pi)
                                  "Pi")
                             (and (rsr/agent-sessions--unwire-agy)
                                  "agy")))))
    (message (if changed
                 (format "agent-sessions: unhooked from %s" (string-join changed " + "))
               "agent-sessions: nothing to remove"))))

;;;###autoload
(defun rsr/agent-session-setup ()
  "Install all side effects this package makes on systems outside itself.
Namely: the vterm/eat/ghostel advice (session-id injection
and terminal-title capture), the focus hook that clears the needs-attention
highlight, the `agent-session' Org link type, the `C-x p a' project binding,
the tmux reattach at startup, and starting the Emacs server
\(hook scripts reach us via emacsclient).  Idempotent; call from init/config."
  ;; vterm: inject EMACS_AGENT_SESSION_ID and capture the terminal title.
  (with-eval-after-load 'vterm
    (unless (advice-member-p #'rsr/agent-sessions--vterm-advice 'vterm--internal)
      (advice-add 'vterm--internal :around #'rsr/agent-sessions--vterm-advice))
    (unless (advice-member-p #'rsr/agent-sessions--capture-title 'vterm--set-title)
      (advice-add 'vterm--set-title :before #'rsr/agent-sessions--capture-title)))
  ;; eat: the same id injection and title capture.
  (with-eval-after-load 'eat
    (unless (advice-member-p #'rsr/agent-sessions--eat-advice 'eat--1)
      (advice-add 'eat--1 :around #'rsr/agent-sessions--eat-advice))
    (unless (advice-member-p #'rsr/agent-sessions--eat-capture-title 'eat--t-set-title)
      (advice-add 'eat--t-set-title :after #'rsr/agent-sessions--eat-capture-title)))
  ;; ghostel: the same again.  `ghostel--set-title' receives the raw OSC 0/2
  ;; title with the terminal's buffer current, like `vterm--set-title'.
  (with-eval-after-load 'ghostel
    (unless (advice-member-p #'rsr/agent-sessions--ghostel-advice 'ghostel-create)
      (advice-add 'ghostel-create :around #'rsr/agent-sessions--ghostel-advice))
    (unless (advice-member-p #'rsr/agent-sessions--capture-title 'ghostel--set-title)
      (advice-add 'ghostel--set-title :before #'rsr/agent-sessions--capture-title)))
  ;; Clear a session's needs-attention highlight once the user focuses it.
  (add-hook 'buffer-list-update-hook #'rsr/agent-session--clear-attention-on-focus)
  ;; Mark the dashboard row whose terminal is on screen beside it.  Closing a
  ;; window runs only the second hook.
  (add-hook 'window-buffer-change-functions #'rsr/agent-sessions--mark-on-screen-soon)
  (add-hook 'window-configuration-change-hook #'rsr/agent-sessions--mark-on-screen-soon)
  ;; Record that sessions still running at exit were *not* closed by the user.
  ;; This is the half of the close-detection scheme that runs when Emacs goes
  ;; away in an orderly fashion; `kill-buffer-hook' covers the other half, and
  ;; the fact that Emacs runs one but not the other is what distinguishes them.
  (add-hook 'kill-emacs-hook #'rsr/agent-sessions--log-close-all)
  ;; The other side of that: tmux agents outlive Emacs, so pick them back up.
  ;; Only for the tmux backend, so other setups never shell out to tmux.
  (when (eq rsr/agent-sessions-terminal 'tmux)
    (if after-init-time
        (run-at-time 0 nil #'rsr/agent-sessions-tmux-reattach)
      (add-hook 'emacs-startup-hook #'rsr/agent-sessions-tmux-reattach)))
  ;; A periodic heartbeat so a session lost to a *crash* can still be dated:
  ;; nothing runs at that point, so the last time we know Emacs was alive is
  ;; the best available answer.
  (unless rsr/agent-sessions--heartbeat-timer
    (setq rsr/agent-sessions--heartbeat-timer
          (run-with-timer 60 60 #'rsr/agent-sessions--db-heartbeat)))
  ;; `agent-session:' Org links that resume/jump to a session.
  (with-eval-after-load 'ol
    (org-link-set-parameters "agent-session"
                             :follow #'rsr/agent-sessions--org-follow-link
                             :store #'rsr/agent-sessions--org-store-link))
  ;; C-x p a: switch between / create agent sessions for the current project.
  (with-eval-after-load 'project
    (define-key project-prefix-map (kbd "a") #'rsr/agent-session-switch-or-new))
  ;; Hook scripts forward events via emacsclient, so the server must be up.
  (unless (server-running-p)
    (server-start)))

;;;###autoload
(defun rsr/agent-sessions-list ()
  "Open the dashboard of Claude/Codex sessions running in vterm."
  (interactive)
  (let ((buf (get-buffer-create rsr/agent-sessions-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'rsr/agent-sessions-mode)
        (rsr/agent-sessions-mode))
      (rsr/agent-sessions--refresh))
    (if rsr/agent-sessions-display-side
        (select-window
         (display-buffer-in-side-window
          buf `((side . ,rsr/agent-sessions-display-side)
                (slot . 0)
                (window-width . ,rsr/agent-sessions-window-width)
                (preserve-size . (t . nil)))))
      (pop-to-buffer buf))))

(provide 'agent-sessions)
