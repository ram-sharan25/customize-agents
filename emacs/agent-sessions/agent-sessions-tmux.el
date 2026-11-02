;;; agent-sessions-tmux.el --- tmux backend for agent-sessions -*- lexical-binding: t -*-

;;; Commentary:

;; Agents run as windows in a per-repository tmux session on the user's normal
;; tmux server, so a session can be attached from Emacs, Ghostty or anywhere
;; else.  Emacs shows each session through one ghostel buffer, *tmux: NAME*.
;; Seeing a second agent of the same session at once (the dashboard's `o')
;; takes a second terminal, *tmux: NAME @N*, attached to a view: a session
;; NAME~view-N with window @N linked into it, so it has its own current window.
;;
;; agent-sessions identifies a session by an Emacs buffer and keeps its state in
;; buffer-local variables.  A tmux agent has no buffer of its own, so it gets a
;; *proxy*: a buffer in `rsr/agent-tmux-mode' that records the window (=@N=) and
;; carries that state.  Everything above the terminal layer then works
;; unchanged; this file supplies the terminal layer: windows, I/O, screen
;; capture, liveness and display.
;;
;; Only windows created here are managed; other panes on the shared server are
;; never touched.  Every tmux call goes through `rsr/agent-tmux--call', and a
;; failing call (server down, window gone) reads as "no result", never as an
;; error, so hooks and dashboard rendering cannot be broken by tmux.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup rsr/agent-tmux nil
  "tmux backend for agent-sessions."
  :group 'tools)

(defcustom rsr/agent-tmux-program "tmux"
  "The tmux executable."
  :type 'string)

(defcustom rsr/agent-tmux-socket nil
  "tmux socket name (tmux -L), or nil for the default server.
Set it to keep a separate server, as tests and the test bed do."
  :type '(choice (const :tag "Default server" nil) string))

(defun rsr/agent-tmux--socket-args ()
  "The tmux arguments that select `rsr/agent-tmux-socket'."
  (and rsr/agent-tmux-socket (list "-L" rsr/agent-tmux-socket)))

(defcustom rsr/agent-tmux-unset-environment
  '("CLAUDECODE" "CLAUDE_CODE_ENTRYPOINT" "CLAUDE_CODE_CHILD_SESSION"
    "PI_CODING_AGENT_DIR")
  "Variables removed from a new window's environment.
Windows inherit the tmux server's environment, which keeps whatever the
process that started the server had.  A Claude child-session marker there
turns off transcript saving in every Claude started in the window, and a stale
`PI_CODING_AGENT_DIR' points pi at the wrong home."
  :type '(repeat string))

(defcustom rsr/agent-tmux-hide-mode-line t
  "Non-nil to hide the Emacs mode line in *tmux: S* buffers.
tmux draws its own status line inside the buffer, so the mode line below it
is a second one.  tmux's status is a session option, so it cannot be turned
off for the Emacs client alone without also losing it in Ghostty."
  :type 'boolean)

(defface rsr/agent-tmux-faint '((t :inherit shadow))
  "Face for faint (SGR 2) text in a captured tmux screen.")

(defvar-local rsr/agent-tmux-session nil
  "The tmux session this buffer belongs to.
Set in proxy buffers and in the ghostel buffer attached to the session.")

(defvar-local rsr/agent-tmux-window nil
  "The tmux window id (\"@N\") a proxy buffer stands in for.")

(defvar-local rsr/agent-tmux--window-gone nil
  "Non-nil once the proxy's window is known to have closed.
Killing such a proxy must not try to kill the window again.")

;;; Calling tmux

(defun rsr/agent-tmux--call (args &optional input)
  "Run tmux with ARGS, feeding INPUT on stdin when non-nil.
Return (STATUS . OUTPUT); STATUS is -1 when tmux could not be run."
  (with-temp-buffer
    (when input (insert input))
    (let ((status (condition-case nil
                      (apply #'call-process-region (point-min) (point-max)
                             rsr/agent-tmux-program t t nil
                             (append (rsr/agent-tmux--socket-args) args))
                    (error -1))))
      (cons status (buffer-string)))))

(defun rsr/agent-tmux--ok (&rest args)
  "Run tmux with ARGS; return non-nil on success."
  (eq 0 (car (rsr/agent-tmux--call args))))

(defun rsr/agent-tmux--output (&rest args)
  "Run tmux with ARGS; return its output without the final newline, or nil."
  (let ((result (rsr/agent-tmux--call args)))
    (and (eq 0 (car result)) (string-trim-right (cdr result) "\n"))))

;;; Sessions

(defun rsr/agent-tmux-session-name (string)
  "STRING made safe as a tmux session name (`.', `:' and spaces become `-')."
  (replace-regexp-in-string "[.: ]" "-" string))

(defun rsr/agent-tmux-sessions ()
  "Names of the running tmux sessions, views left out."
  (when-let ((out (rsr/agent-tmux--output "list-sessions" "-F" "#{session_name}")))
    (seq-remove #'rsr/agent-tmux-view-session-p (split-string out "\n" t))))

(defun rsr/agent-tmux-view-session (session window)
  "The name of the view of SESSION that `rsr/agent-tmux-show-view' keeps on WINDOW.
`~' never occurs in a name from `rsr/agent-tmux-session-name'."
  (concat session "~view-" (string-remove-prefix "@" window)))

(defun rsr/agent-tmux-view-session-p (name)
  "Non-nil when tmux session NAME is a view (`rsr/agent-tmux-view-session')."
  (string-match-p "~view-[0-9]+\\'" name))

(defvar rsr/agent-tmux--target nil
  "When non-nil, a (SESSION . DIRECTORY) that `rsr/agent-tmux-target' returns.
Bound by commands that already resolved the target, so it is asked for once.")

(defun rsr/agent-tmux-recorded-repo-name (main)
  "The repo name recorded in the git config of the main checkout MAIN, or nil.
A repo laid out as REPO/<branch>/ has its main checkout named after a branch,
so its name is kept as `agent-sessions.repo-name' rather than read from a
folder.  Reads `.git/config' rather than running git."
  (with-temp-buffer
    (ignore-errors
      (insert-file-contents (expand-file-name ".git/config" main)))
    (let ((case-fold-search t))
      (and (re-search-forward "^\\[agent-sessions\\][ \t]*$" nil t)
           (let ((end (save-excursion
                        (if (re-search-forward "^\\[" nil t)
                            (match-beginning 0)
                          (point-max)))))
             (and (re-search-forward
                   "^[ \t]*repo-name[ \t]*=[ \t]*\\(.*?\\)[ \t]*$" end t)
                  (match-string-no-properties 1)))))))

(defun rsr/agent-tmux-checkout (dir)
  "For DIR inside a git checkout, return (REPO WORKTREE ROOT MAIN), else nil.
REPO is the repository's name, WORKTREE nil for the main checkout and the
linked worktree's name otherwise, ROOT the checkout's top directory and MAIN
the main checkout's, which is ROOT outside a linked worktree.  Reads
the `.git' file of a linked worktree (\"gitdir: <main>/.git/worktrees/X\")
rather than running git.  A worktree folder named REPO-X is called X.  REPO
is the name recorded by `rsr/agent-tmux-recorded-repo-name' when there is one."
  (when-let ((root (locate-dominating-file dir ".git")))
    (let* ((root (file-name-as-directory (expand-file-name root)))
           (dotgit (expand-file-name ".git" root))
           (folder (file-name-nondirectory (directory-file-name root))))
      (if (file-directory-p dotgit)
          (list (or (rsr/agent-tmux-recorded-repo-name root) folder) nil root root)
        (let* ((gitdir (with-temp-buffer
                         (ignore-errors (insert-file-contents dotgit))
                         (and (re-search-forward "^gitdir: *\\(.+\\)$" nil t)
                              (expand-file-name (match-string 1) root))))
               (main (and gitdir
                          (string-match "\\`\\(.*\\)/\\.git/worktrees/[^/]+/?\\'" gitdir)
                          (match-string 1 gitdir))))
          (if (not main)
              ;; A submodule or other `.git' file: a checkout of its own.
              (list folder nil root root)
            (let ((repo (or (rsr/agent-tmux-recorded-repo-name main)
                            (file-name-nondirectory (directory-file-name main)))))
              (list repo
                    (if (and (string-prefix-p (concat repo "-") folder)
                             (> (length folder) (1+ (length repo))))
                        (substring folder (1+ (length repo)))
                      folder)
                    root
                    (file-name-as-directory main)))))))))

(defun rsr/agent-tmux-target (&optional dir)
  "Return (SESSION . DIRECTORY) for DIR (default `default-directory').
Inside a repository: the repository's name and its main checkout's root, from
any of its worktrees.  One session holds all of a repo's agents, each window
in its own checkout; the dashboard's folders tell them apart, and a session
per worktree outlived the worktree.  Elsewhere: a session name read from the
user, and DIR."
  (let ((dir (expand-file-name (or dir default-directory))))
    (or rsr/agent-tmux--target
        (pcase (rsr/agent-tmux-checkout dir)
          (`(,repo ,_worktree ,_root ,main)
           (cons (rsr/agent-tmux-session-name repo) main))
          (_
           (let ((name (string-trim (completing-read "tmux session: "
                                                     (rsr/agent-tmux-sessions)))))
             (when (string-empty-p name) (user-error "No session name given"))
             (cons (rsr/agent-tmux-session-name name) dir)))))))

(defun rsr/agent-tmux-read-target (&optional dir)
  "Ask for the tmux session to open in; return (SESSION . DIRECTORY).
Unlike `rsr/agent-tmux-target', asks inside a repository too.  The default
is the session of the current tmux buffer, else the one
`rsr/agent-tmux-target' would derive from DIR.  The repo's own session opens
in DIR's checkout root, so an agent asked for from a worktree works there;
another existing session in its own start directory; a new one in DIR."
  (let* ((dir (expand-file-name (or dir default-directory)))
         (derived (pcase (rsr/agent-tmux-checkout dir)
                    (`(,repo ,_worktree ,root ,_main)
                     (cons (rsr/agent-tmux-session-name repo) root))))
         (default (or rsr/agent-tmux-session (car derived)))
         (name (string-trim
                (completing-read (format-prompt "tmux session" default)
                                 (rsr/agent-tmux-sessions)
                                 nil nil nil nil default))))
    (when (string-empty-p name) (user-error "No session name given"))
    (let ((session (rsr/agent-tmux-session-name name)))
      (cons session
            (or (and (equal session (car derived)) (cdr derived))
                (rsr/agent-tmux-session-path session)
                dir)))))

(defvar rsr/agent-tmux--session-paths (make-hash-table :test 'equal)
  "Session name → its start directory, once asked.")

(defun rsr/agent-tmux-session-path (session)
  "SESSION's start directory (tmux's session_path), or nil."
  (or (gethash session rsr/agent-tmux--session-paths)
      (when-let ((path (rsr/agent-tmux--output "display-message" "-p" "-t"
                                               (concat "=" session ":")
                                               "#{session_path}")))
        (unless (string-empty-p path)
          (puthash session (file-name-as-directory path)
                   rsr/agent-tmux--session-paths)))))

(defun rsr/agent-tmux-ensure-session (session dir)
  "Create detached SESSION in DIR unless it already exists.
Return t when it existed, the id of its placeholder window when it was
created, and nil on failure.  A new session comes with a window of its own; it
runs `sleep' rather than the user's shell, and the caller closes it once the
agent's window is open, so closing the last agent ends the session instead of
leaving a stray shell to keep it alive."
  (or (rsr/agent-tmux--ok "has-session" "-t" (concat "=" session))
      ;; A session of this name that has since gone may have started elsewhere.
      (progn (remhash session rsr/agent-tmux--session-paths)
             (rsr/agent-tmux--output "new-session" "-d" "-P" "-F" "#{window_id}"
                                     "-s" session "-c" dir "sleep" "86400"))))

(defun rsr/agent-tmux-session-buffer (session)
  "The ghostel buffer attached to SESSION, or nil."
  (get-buffer (format "*tmux: %s*" session)))

(declare-function ghostel-exec "ghostel")
(defvar ghostel--process)
(defvar ghostel--pid)

(defconst rsr/agent-tmux-other-window-action
  '((display-buffer-reuse-window
     rsr/agent-tmux--display-buffer-in-selected-window
     display-buffer-use-some-window)
    (inhibit-same-window . t)
    (some-window . mru))
  "How a session, its file or its link is shown from the dashboard.
Reuse a window already showing the buffer, else replace the most recently used
other window; never split.  The dashboard sits in a side window, which
`display-buffer' will not reuse, so its default action split the frame anew
on every open.  From an ordinary window with no other beside it (a
notification click, an Org link, a new terminal), there is no other window,
so the selected one is used rather than split.")

(defun rsr/agent-tmux--display-buffer-in-selected-window (buffer alist)
  "`display-buffer' action: the selected window, when nothing else will do.
That is when it already shows BUFFER, or is the only ordinary window in the
frame.  `inhibit-same-window' would otherwise put a second copy of BUFFER
beside it, or split it.  The dashboard's side window is never used."
  (let ((window (selected-window)))
    (when (and (not (window-parameter window 'window-side))
               (not (window-dedicated-p window))
               (not (window-minibuffer-p window))
               (or (eq (window-buffer window) buffer)
                   (not (get-mru-window nil nil t))))
      (window--display-buffer buffer window 'reuse alist))))

(defun rsr/agent-tmux--show-terminal (name session dir display attach)
  "Show ghostel buffer NAME attached to tmux SESSION, running tmux ATTACH if not.
ATTACH is the tmux argument list that attaches a client.  A buffer whose
client is still running is only shown.  DIR is the buffer's directory; with
DISPLAY non-nil, display it without selecting it.  Return the buffer."
  (require 'ghostel)
  (let ((buffer (get-buffer-create name)))
    (if display
        (display-buffer buffer rsr/agent-tmux-other-window-action)
      (pop-to-buffer buffer rsr/agent-tmux-other-window-action))
    (with-current-buffer buffer
      (unless (process-live-p ghostel--process)
        (setq default-directory (file-name-as-directory dir))
        (ghostel-exec buffer (executable-find rsr/agent-tmux-program)
                      (append (rsr/agent-tmux--socket-args) attach)))
      ;; After `ghostel-exec', whose mode change resets buffer-local values.
      (when rsr/agent-tmux-hide-mode-line
        (setq-local mode-line-format nil))
      (setq-local rsr/agent-tmux-session session))
    buffer))

(defun rsr/agent-tmux-show (session dir &optional display create)
  "Show SESSION in its ghostel buffer, attaching to it as needed.
With DISPLAY non-nil, display the buffer without selecting it.  Return the
buffer.  A session that doesn't exist is an error unless CREATE is non-nil,
when it is created in DIR: one made here starts on a shell window that no
agent owns, which would keep the session alive after its last agent."
  (unless (or create (rsr/agent-tmux--ok "has-session" "-t" (concat "=" session)))
    (user-error "tmux session %s has ended" session))
  (rsr/agent-tmux--show-terminal (format "*tmux: %s*" session) session dir display
                                 (if create
                                     (list "new-session" "-A" "-s" session "-c" dir)
                                   (list "attach-session" "-t" (concat "=" session)))))

(defun rsr/agent-tmux-view-buffer-name (session window)
  "The name of the buffer `rsr/agent-tmux-show-view' shows WINDOW of SESSION in."
  (format "*tmux: %s %s*" session window))

(defun rsr/agent-tmux--make-view (view window dir)
  "Create session VIEW holding only WINDOW, linked from its own session.
A new session comes with a window of its own; it runs `sleep' rather than
the user's shell, and is closed once WINDOW is linked in."
  (let ((target (concat "=" view ":")))
    (rsr/agent-tmux--ok "new-session" "-d" "-s" view "-c" dir "sleep" "86400")
    (let ((placeholder (rsr/agent-tmux--output "display-message" "-p" "-t" target
                                               "#{window_id}")))
      (rsr/agent-tmux--ok "link-window" "-d" "-s" window "-t" target)
      (when placeholder
        (rsr/agent-tmux--ok "kill-window" "-t" placeholder)))))

(defun rsr/agent-tmux-show-view (session window dir &optional display)
  "Show WINDOW of SESSION in a terminal of its own, *tmux: SESSION WINDOW*.
*tmux: SESSION* can show one window at a time, so a second agent of the same
session is shown through a view: a session of its own with WINDOW linked
into it.  It is not a grouped session (`new-session -t'), though that would
need no linking: on tmux 3.7 any grouped session on the server stops
`choose-tree -s' (prefix s) opening for every other session, so a view from
an earlier version that is grouped is replaced.  The view is destroyed when
its terminal's client goes (`destroy-unattached on'), leaving SESSION and
WINDOW alone, and when WINDOW closes, having no other window.  The option is
set after the client attaches, as a session with it is destroyed once it has
no client.  DIR and DISPLAY are as in `rsr/agent-tmux-show'.  Return the
buffer."
  (let* ((view (rsr/agent-tmux-view-session session window))
         (target (concat "=" view ":"))
         (name (rsr/agent-tmux-view-buffer-name session window)))
    ;; `has-session', not `display-message': tmux 3.7 answers the latter for a
    ;; missing session with success and no output.
    (cond
     ((not (rsr/agent-tmux--ok "has-session" "-t" target))
      (rsr/agent-tmux--make-view view window dir))
     ((equal (rsr/agent-tmux--output "display-message" "-p" "-t" target
                                     "#{session_grouped}")
             "1")
      (when-let ((old (get-buffer name)))
        (let ((kill-buffer-query-functions nil)) (kill-buffer old)))
      (rsr/agent-tmux--ok "kill-session" "-t" target)
      (rsr/agent-tmux--make-view view window dir)))
    (rsr/agent-tmux--ok "select-window" "-t" (concat target window))
    (let ((buffer (rsr/agent-tmux--show-terminal
                   name view dir display
                   (list "attach-session" "-t" target
                         ";" "set-option" "-t" target "destroy-unattached" "on"))))
      (with-current-buffer buffer
        (setq-local rsr/agent-tmux-view-terminal t))
      buffer)))

(defvar-local rsr/agent-tmux-view-terminal nil
  "Non-nil in a terminal made by `rsr/agent-tmux-show-view'.")

(defun rsr/agent-tmux-kill-hidden-views ()
  "Kill each view terminal no window shows.
A view is only there to be seen beside its session's terminal, so closing its
last window kills it: its client goes, and `destroy-unattached' then removes
the view session, leaving the agent's window alone."
  (let ((kill-buffer-query-functions nil))
    (dolist (buffer (buffer-list))
      (when (and (buffer-local-value 'rsr/agent-tmux-view-terminal buffer)
                 (not (get-buffer-window buffer t)))
        (kill-buffer buffer)))))

(defun rsr/agent-tmux--kill-hidden-views-soon (&rest _)
  "Run `rsr/agent-tmux-kill-hidden-views' once redisplay is done.
For `window-buffer-change-functions', which runs during redisplay."
  (run-at-time 0 nil #'rsr/agent-tmux-kill-hidden-views))

(add-hook 'window-buffer-change-functions #'rsr/agent-tmux--kill-hidden-views-soon)

(defun rsr/agent-tmux-active-window (session)
  "The id of SESSION's current window, or nil."
  (rsr/agent-tmux--output "display-message" "-p" "-t" (concat "=" session ":")
                          "#{window_id}"))

(defun rsr/agent-tmux--terminal-pid (buffer)
  "The pid of the tmux client ghostel BUFFER runs, or nil."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (or (and (boundp 'ghostel--pid) ghostel--pid)
             (and (boundp 'ghostel--process)
                  (process-live-p ghostel--process)
                  (process-id ghostel--process))))))

(defun rsr/agent-tmux-client (buffer)
  "The tty of the tmux client running in ghostel BUFFER, or nil.
Matched by pid: ghostel runs the client directly, so its child is the client.
A client can be moved to another session from inside it (prefix s, prefix
\=(), after which *tmux: S* no longer shows S; showing a window there must
therefore address the client, not the session."
  (when-let* ((pid (rsr/agent-tmux--terminal-pid buffer))
              (out (rsr/agent-tmux--output "list-clients" "-F"
                                           "#{client_pid}\t#{client_tty}")))
    (cl-loop for line in (split-string out "\n" t)
             for (client-pid tty) = (split-string line "\t")
             when (equal client-pid (number-to-string pid))
             return tty)))

(defun rsr/agent-tmux-client-window (buffer)
  "The window the tmux client in ghostel BUFFER is showing, or nil.
Read from `list-clients': `display-message -c TTY' expands its format in the
most recently used session, not in the one that client shows."
  (when-let ((tty (rsr/agent-tmux-client buffer))
             (out (rsr/agent-tmux--output "list-clients" "-F"
                                          "#{client_tty}\t#{window_id}")))
    (cl-loop for line in (split-string out "\n" t)
             for (client-tty window) = (split-string line "\t")
             when (equal client-tty tty) return window)))

;;; Windows

(defun rsr/agent-tmux-new-window (session dir env &optional name detached)
  "Open a window in SESSION at DIR running the user's shell; return its id.
ENV is a list of \"VAR=VALUE\" strings set in the window.  Variables in
`rsr/agent-tmux-unset-environment' are removed first.  NAME, when non-nil,
names the window; DETACHED non-nil leaves SESSION's current window as it is
instead of switching to the new one (`new-window -d').

ENV is applied by `env' in the window's command rather than with
`new-window -e': tmux replaces PATH with the calling client's, so a PATH
given with -e never reaches the shell."
  (apply #'rsr/agent-tmux--output
         `("new-window" "-P" "-F" "#{window_id}" "-t" ,(concat "=" session ":")
           ,@(and detached '("-d"))
           ,@(and name (list "-n" name))
           "-c" ,dir
           ,@(rsr/agent-tmux--shell-command env))))

(defun rsr/agent-tmux--shell-command (env)
  "The command a window runs: the user's login shell with ENV applied."
  `("env" ,@(mapcan (lambda (var) (list "-u" var))
                    rsr/agent-tmux-unset-environment)
    ,@env
    ,(or (getenv "SHELL") "/bin/sh") "-l"))

(defun rsr/agent-tmux-respawn (window dir env)
  "Replace WINDOW's shell with a new one at DIR, run as `rsr/agent-tmux-new-window'
runs it, with ENV.  For a window tmux-resurrect restored: its shell started
without the environment that lets the agent's hooks reach Emacs."
  (apply #'rsr/agent-tmux--ok
         `("respawn-pane" "-k" "-t" ,window "-c" ,dir
           ,@(rsr/agent-tmux--shell-command env))))

(defun rsr/agent-tmux-select-window (window)
  "Make WINDOW the current window of its session."
  (rsr/agent-tmux--ok "select-window" "-t" window))

(defun rsr/agent-tmux-kill-window (window)
  "Close WINDOW."
  (rsr/agent-tmux--ok "kill-window" "-t" window))

(defun rsr/agent-tmux-send-text (window string)
  "Type STRING into WINDOW literally."
  (rsr/agent-tmux--ok "send-keys" "-t" window "-l" "--" string))

(defun rsr/agent-tmux-send-enter (window)
  "Press Enter in WINDOW."
  (rsr/agent-tmux--ok "send-keys" "-t" window "Enter"))

(defun rsr/agent-tmux-paste (window string)
  "Paste STRING into WINDOW, bracketed when the program there asked for it."
  (and (eq 0 (car (rsr/agent-tmux--call
                   (list "load-buffer" "-b" "agent-sessions-paste" "-")
                   string)))
       (rsr/agent-tmux--ok "paste-buffer" "-p" "-d" "-b" "agent-sessions-paste"
                           "-t" window)))

(defun rsr/agent-tmux-capture (window)
  "WINDOW's visible screen and recent history, with SGR codes, or nil."
  (rsr/agent-tmux--output "capture-pane" "-p" "-e" "-J" "-S" "-40" "-t" window))

;;; Pane state, read once and shared by a dashboard render

(defvar rsr/agent-tmux--panes nil
  "Cache: (TIME . HASH) mapping window id to (:pid PID :title TITLE).")

(defconst rsr/agent-tmux--panes-ttl 1.0
  "Seconds a pane snapshot is reused; one render issues at most one call.")

(defun rsr/agent-tmux-panes ()
  "Hash of window id → (:pid PID :title TITLE) for every window's first pane.
Nil when tmux could not be asked, which callers must read as \"unknown\", not
\"no windows\".  A server that is not running has no windows: it exits with
its last session, which is how the last agent anywhere ends when it quits."
  (if (and rsr/agent-tmux--panes
           (< (- (float-time) (car rsr/agent-tmux--panes)) rsr/agent-tmux--panes-ttl))
      (cdr rsr/agent-tmux--panes)
    (let* ((result (rsr/agent-tmux--call
                    '("list-panes" "-a" "-F" "#{window_id}\t#{pane_pid}\t#{pane_title}")))
           (out (pcase result
                  (`(0 . ,out) (string-trim-right out "\n"))
                  (`(1 . ,(rx bos (or "no server running on " "error connecting to ")))
                   "")))
           (table (and out (make-hash-table :test 'equal))))
      (when table
        (dolist (line (split-string out "\n" t))
          (pcase (split-string line "\t")
            (`(,win ,pid . ,title)
             (unless (gethash win table)
               (puthash win (list :pid (string-to-number pid)
                                  :title (string-join title "\t"))
                        table))))))
      (setq rsr/agent-tmux--panes (cons (float-time) table))
      table)))

(defun rsr/agent-tmux-forget-panes ()
  "Drop the pane snapshot, so the next read asks tmux again."
  (setq rsr/agent-tmux--panes nil))

;;; Reattaching after Emacs restarts
;;
;; Emacs runs `kill-emacs-hook' but not `kill-buffer-hook' when it exits, so
;; a proxy never closes its window then: the agent keeps running in tmux.  To
;; find it again, each window agent-sessions opens is tagged with the terminal
;; id its shell was given (`@agent-session-id', never changed afterwards: the
;; agent's environment keeps it) and the id of the Emacs terminal currently
;; logging it (`@agent-session-log-id', moved on at each reattach).

(defconst rsr/agent-tmux--id-option "@agent-session-id"
  "Window option holding the terminal id a window was opened with.")

(defconst rsr/agent-tmux--log-id-option "@agent-session-log-id"
  "Window option holding the terminal id whose log rows describe the window.")

(defconst rsr/agent-tmux--restored-option "@agent-session-restored"
  "Window option set by the tmux-resurrect restore hook (`resurrect/').
The window's tags were put back after a restore, but it runs a fresh shell,
not the agent, so reattaching it must start the agent again.")

(defun rsr/agent-tmux-tag-window (window id &optional log-id)
  "Record terminal ID, and LOG-ID (default ID), on WINDOW for a later Emacs.
With LOG-ID, ID is left as it is and only the log id moves."
  (and (or log-id
           (rsr/agent-tmux--ok "set-option" "-w" "-t" window
                               rsr/agent-tmux--id-option id))
       (rsr/agent-tmux--ok "set-option" "-w" "-t" window
                           rsr/agent-tmux--log-id-option (or log-id id))))

(defun rsr/agent-tmux--pane-env-id (pid)
  "EMACS_AGENT_SESSION_ID in the environment of process PID, or nil.
The fallback for windows opened before tagging existed.  Best effort: Linux
exposes /proc; macOS needs `ps eww', which may be refused."
  (let ((environ (format "/proc/%d/environ" pid)))
    (if (file-readable-p environ)
        (with-temp-buffer
          (insert-file-contents-literally environ)
          (and (re-search-forward "EMACS_AGENT_SESSION_ID=\\([^\0]+\\)" nil t)
               (match-string 1)))
      (with-temp-buffer
        (and (eq 0 (ignore-errors
                     (call-process "ps" nil t nil "eww" "-o" "command="
                                   "-p" (number-to-string pid))))
             (progn (goto-char (point-min))
                    (re-search-forward
                     "\\(?:^\\| \\)EMACS_AGENT_SESSION_ID=\\([^ \n]+\\)" nil t))
             (match-string 1))))))

(defun rsr/agent-tmux-agent-windows ()
  "Windows on the server that agent-sessions opened, as plists.
Each is (:window W :session S :dir DIR :id ID :log-id LOG-ID :restored R):
ID the terminal id the window's shell was given, LOG-ID the one its latest
log rows are under, R non-nil for a window tmux-resurrect restored (see
`rsr/agent-tmux--restored-option').  Untagged windows are recognised from
their shell's environment when that can be read; any other window is left out."
  (when-let ((out (rsr/agent-tmux--output
                   "list-panes" "-a" "-F"
                   (concat "#{window_id}\t#{session_name}\t#{pane_pid}\t"
                           "#{pane_current_path}\t#{" rsr/agent-tmux--id-option "}\t"
                           "#{" rsr/agent-tmux--log-id-option "}\t"
                           "#{" rsr/agent-tmux--restored-option "}"))))
    (let (seen windows)
      (dolist (line (split-string out "\n" t))
        (pcase (split-string line "\t")
          (`(,win ,session ,pid ,dir ,tag ,log-tag . ,restored)
           ;; A view lists the window it links too; the window is the base's.
           (unless (or (member win seen) (rsr/agent-tmux-view-session-p session))
             (push win seen)
             (when-let ((id (if (string-empty-p tag)
                                (rsr/agent-tmux--pane-env-id (string-to-number pid))
                              tag)))
               (push (list :window win :session session :dir dir :id id
                           :log-id (if (string-empty-p log-tag) id log-tag)
                           :restored (not (string-empty-p (or (car restored) ""))))
                     windows))))))
      (nreverse windows))))

;;; Screen text

(defun rsr/agent-tmux--sgr-faint (params set)
  "Walk SGR PARAMS (the text between ESC[ and m), calling SET on faint changes.
SET gets t at 2 and nil at 22 or a reset (0, or no parameters).  The colour
arguments of 38/48/58 are skipped, so the 2 in 38;2;R;G;B is not faint.
Colon sub-parameters (38:2:R:G:B) stay one parameter and are ignored."
  (let ((ps (if (string-empty-p params) '("0") (split-string params ";"))))
    (while ps
      (let ((p (pop ps)))
        (pcase p
          ("2" (funcall set t))
          ((or "0" "" "22") (funcall set nil))
          ((or "38" "48" "58")
           (pcase (pop ps)
             ("5" (pop ps))
             ("2" (setq ps (nthcdr 3 ps))))))))))

(defun rsr/agent-tmux-faint-text (string)
  "STRING with SGR escapes removed and faint (SGR 2) runs given a faint face.
Faint ends at SGR 22 or a reset (0 or empty).  Other escape sequences are
dropped.  Lets the composer check tell Claude's inline completion, which is
drawn faint, from typed input."
  (let ((pos 0) (faint nil) (parts nil))
    (while (string-match "\e\\(?:\\[\\([0-?]*\\)[ -/]*\\([@-~]\\)\\|][^\a\e]*\\(?:\a\\|\e\\\\\\)\\|[@-Z\\\\-_]\\)"
                         string pos)
      ;; Read everything from the match first: `split-string' below runs its
      ;; own regex search and would overwrite the match data.
      (let ((text (substring string pos (match-beginning 0)))
            (params (match-string 1 string))
            (final (match-string 2 string))
            (next (match-end 0)))
        (push (if faint (propertize text 'face 'rsr/agent-tmux-faint) text) parts)
        (when (equal final "m")
          (rsr/agent-tmux--sgr-faint params (lambda (on) (setq faint on))))
        (setq pos next)))
    (let ((rest (substring string pos)))
      (push (if faint (propertize rest 'face 'rsr/agent-tmux-faint) rest) parts))
    (apply #'concat (nreverse parts))))

;;; Proxy buffers

(defvar-keymap rsr/agent-tmux-mode-map
  :parent special-mode-map
  "RET" #'rsr/agent-tmux-show-proxy)

(define-derived-mode rsr/agent-tmux-mode special-mode "Agent-tmux"
  "Stand-in buffer for an agent running in a tmux window.
It carries the agent's dashboard state.  Its text is the window's last
captured screen; \\[rsr/agent-tmux-show-proxy] shows the live window."
  (setq-local revert-buffer-function
              (lambda (&rest _) (rsr/agent-tmux-refresh-screen (current-buffer)))))

(defun rsr/agent-tmux-make-proxy (name session window dir)
  "Create a proxy buffer NAME for WINDOW of SESSION, working in DIR."
  (with-current-buffer (generate-new-buffer name)
    (rsr/agent-tmux-mode)
    (setq default-directory (file-name-as-directory dir)
          rsr/agent-tmux-session session
          rsr/agent-tmux-window window)
    (add-hook 'kill-buffer-query-functions #'rsr/agent-tmux--confirm-kill nil t)
    (add-hook 'kill-buffer-hook #'rsr/agent-tmux--kill-window-on-kill nil t)
    (current-buffer)))

(defun rsr/agent-tmux-proxy-p (&optional buffer)
  "Non-nil when BUFFER (default current) is a tmux proxy."
  (eq (buffer-local-value 'major-mode (or buffer (current-buffer)))
      'rsr/agent-tmux-mode))

(defun rsr/agent-tmux-refresh-screen (buffer)
  "Replace proxy BUFFER's text with its window's current screen.
Return non-nil when the screen could be read."
  (with-current-buffer buffer
    (when-let ((screen (rsr/agent-tmux-capture rsr/agent-tmux-window)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (rsr/agent-tmux-faint-text screen))
        ;; tmux pads the capture to the pane's height; checks that look at
        ;; "the last few lines" must see the content, not the padding.
        (goto-char (point-max))
        (skip-chars-backward " \t\n")
        (delete-region (line-end-position) (point-max)))
      t)))

(defvar rsr/agent-tmux-own-view nil
  "Non-nil to give a proxy's window a terminal of its own when need be.
That is when its session's terminal is on screen showing another window:
rather than switch that terminal, `rsr/agent-tmux-show-proxy' opens a view
\(`rsr/agent-tmux-show-view').  Bound by the dashboard's `o', which is for
seeing two agents at once.")

(defun rsr/agent-tmux--terminal-showing (window)
  "A terminal on screen whose tmux client shows WINDOW, or nil.
A client not found (still attaching, say) counts as showing its session's
current window, as in `rsr/agent-tmux--fresh-active-window'."
  (seq-find (lambda (b)
              (let ((session (buffer-local-value 'rsr/agent-tmux-session b)))
                (and session
                     (not (rsr/agent-tmux-proxy-p b))
                     (get-buffer-window b)
                     (equal (or (rsr/agent-tmux-client-window b)
                                (rsr/agent-tmux-active-window session))
                            window))))
            (buffer-list)))

(defun rsr/agent-tmux-show-proxy (&optional buffer display)
  "Show the tmux window behind proxy BUFFER (default current).
With DISPLAY non-nil, display the session buffer without selecting it.
A terminal already on screen showing the window is used as it is, so a view
`o' opened is gone back to rather than its window switched to elsewhere."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (let* ((session rsr/agent-tmux-session)
           (window rsr/agent-tmux-window)
           (dir default-directory)
           (main (rsr/agent-tmux-session-buffer session))
           (here (rsr/agent-tmux--terminal-showing window)))
      (cond
       (here
        (if display
            (display-buffer here rsr/agent-tmux-other-window-action)
          (pop-to-buffer here rsr/agent-tmux-other-window-action))
        here)
       ((and rsr/agent-tmux-own-view main (get-buffer-window main))
        (rsr/agent-tmux-show-view session window dir display))
       (t
        ;; Selecting the window covers a client that is about to attach;
        ;; one already attached may be on another session by now, so it
        ;; is switched to the window as well.
        (let ((shown (progn (rsr/agent-tmux-select-window window)
                            (rsr/agent-tmux-show session dir display))))
          (when-let ((tty (rsr/agent-tmux-client shown)))
            (rsr/agent-tmux--ok "switch-client" "-c" tty "-t" window))
          shown))))))

(defun rsr/agent-tmux-window-of (buffer)
  "For the ghostel buffer attached to a session, its active window's proxy.
Return BUFFER unchanged for anything else.  Lets focus tracking treat looking
at *tmux: S* as looking at the agent in S's current window."
  (let ((session (buffer-local-value 'rsr/agent-tmux-session buffer)))
    (if (or (null session) (rsr/agent-tmux-proxy-p buffer))
        buffer
      (let ((active (rsr/agent-tmux--cached-active-window session buffer)))
        (or (and active
                 (seq-find (lambda (b)
                             (and (rsr/agent-tmux-proxy-p b)
                                  (equal (buffer-local-value 'rsr/agent-tmux-window b)
                                         active)))
                           (buffer-list)))
            buffer)))))

(defvar rsr/agent-tmux--clients nil
  "Cache: (TIME . HASH) mapping a client's pid, as a string, to its window.")

(defun rsr/agent-tmux--clients ()
  "Hash of client pid → the window it shows, reused for `rsr/agent-tmux--panes-ttl'.
A tmux call costs ~14ms, and the dashboard renders on every hook event."
  (if (and rsr/agent-tmux--clients
           (< (- (float-time) (car rsr/agent-tmux--clients)) rsr/agent-tmux--panes-ttl))
      (cdr rsr/agent-tmux--clients)
    (let ((table (make-hash-table :test 'equal)))
      (dolist (line (split-string (or (rsr/agent-tmux--output
                                       "list-clients" "-F"
                                       "#{client_pid}\t#{window_id}")
                                      "")
                                  "\n" t))
        (pcase (split-string line "\t")
          (`(,pid ,window) (puthash pid window table))))
      (setq rsr/agent-tmux--clients (cons (float-time) table))
      table)))

(defun rsr/agent-tmux-forget-clients ()
  "Drop the client snapshot, so the next read asks tmux again."
  (setq rsr/agent-tmux--clients nil))

(defun rsr/agent-tmux-shown-proxies (buffers)
  "The proxies of the windows that the tmux terminals among BUFFERS show.
One `list-clients' answers for every terminal, and nothing is asked when
BUFFERS holds none.  A terminal whose client is not listed (still attaching)
counts as showing its session's current window, as in
`rsr/agent-tmux--terminal-showing'."
  (when-let ((terminals (seq-filter
                         (lambda (b)
                           (and (buffer-local-value 'rsr/agent-tmux-session b)
                                (not (rsr/agent-tmux-proxy-p b))))
                         buffers)))
    (let ((clients (rsr/agent-tmux--clients))
          (proxies (make-hash-table :test 'equal)))
      (dolist (p (rsr/agent-tmux-proxies))
        (puthash (buffer-local-value 'rsr/agent-tmux-window p) p proxies))
      (delete-dups
       (delq nil (mapcar
                  (lambda (term)
                    (let ((pid (rsr/agent-tmux--terminal-pid term)))
                      (gethash (or (and pid (gethash (number-to-string pid) clients))
                                   (rsr/agent-tmux-active-window
                                    (buffer-local-value 'rsr/agent-tmux-session term)))
                               proxies)))
                  terminals))))))

(defvar rsr/agent-tmux--active-cache nil
  "(TIME BUFFER . WINDOW): the last active-window answer, reused briefly.")

(defun rsr/agent-tmux--cached-active-window (session buffer)
  "The window shown in ghostel BUFFER, attached to SESSION.
Asks tmux at most once a second per buffer."
  (pcase rsr/agent-tmux--active-cache
    (`(,time ,b . ,win)
     (if (and (eq b buffer) (< (- (float-time) time) 1.0))
         win
       (rsr/agent-tmux--fresh-active-window session buffer)))
    (_ (rsr/agent-tmux--fresh-active-window session buffer))))

(defun rsr/agent-tmux--fresh-active-window (session buffer)
  "Ask tmux for the window BUFFER's client shows and cache the answer.
Falls back to SESSION's current window when the client can't be found."
  (let ((win (or (rsr/agent-tmux-client-window buffer)
                 (rsr/agent-tmux-active-window session))))
    (setq rsr/agent-tmux--active-cache (cons (float-time) (cons buffer win)))
    win))

(defun rsr/agent-tmux--confirm-kill ()
  "Ask before killing a proxy whose window is still open."
  (or rsr/agent-tmux--window-gone
      (null (gethash rsr/agent-tmux-window (or (rsr/agent-tmux-panes)
                                               (make-hash-table))))
      (y-or-n-p (format "Close tmux window %s in session %s? "
                        rsr/agent-tmux-window rsr/agent-tmux-session))))

(defun rsr/agent-tmux--kill-window-on-kill ()
  "Close the proxy's window when the proxy is killed, unless it already closed.
Its view terminal goes too: with the window gone the view would show another.
Each window showing it is quit, so one made for it closes and one it took
over gets its old buffer back, instead of showing some other buffer.
Quitting a window can make the buffer it falls back to current, so this one
is restored before its window is read; otherwise the window outlived its row."
  (when-let ((view (get-buffer (rsr/agent-tmux-view-buffer-name
                                rsr/agent-tmux-session rsr/agent-tmux-window))))
    (save-current-buffer
      (let ((kill-buffer-query-functions nil))
        (dolist (window (get-buffer-window-list view nil t))
          (quit-restore-window window 'kill))
        (when (buffer-live-p view)
          (kill-buffer view)))))
  (unless rsr/agent-tmux--window-gone
    (rsr/agent-tmux-kill-window rsr/agent-tmux-window)
    (rsr/agent-tmux-forget-panes)))

(defun rsr/agent-tmux-proxies ()
  "All live proxy buffers."
  (seq-filter #'rsr/agent-tmux-proxy-p (buffer-list)))

(defun rsr/agent-tmux-dead-proxies (&optional proxies)
  "Those of PROXIES (default all) whose windows have closed.
Empty when there are none or tmux is unreachable; asks tmux only when there
is something to check."
  (let ((proxies (or proxies (rsr/agent-tmux-proxies))))
    (when-let ((panes (and proxies (rsr/agent-tmux-panes))))
      (seq-remove (lambda (b)
                    (gethash (buffer-local-value 'rsr/agent-tmux-window b) panes))
                  proxies))))

(defun rsr/agent-tmux-reap (buffers)
  "Kill proxy BUFFERS whose windows have closed."
  (dolist (b buffers)
    (when (buffer-live-p b)
      (with-current-buffer b (setq rsr/agent-tmux--window-gone t))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer b)))))

(defun rsr/agent-tmux-pane-title (buffer)
  "The title the program in proxy BUFFER's window set, or nil.
tmux reports the host name when no title was set; that is not a title."
  (when-let* ((panes (rsr/agent-tmux-panes))
              (pane (gethash (buffer-local-value 'rsr/agent-tmux-window buffer) panes))
              (title (plist-get pane :title)))
    (unless (or (string-empty-p title)
                (string-prefix-p (car (split-string (system-name) "\\.")) title))
      title)))

(defun rsr/agent-tmux-pane-pid (buffer)
  "The pid of the shell in proxy BUFFER's window, or nil."
  (when-let* ((panes (rsr/agent-tmux-panes))
              (pane (gethash (buffer-local-value 'rsr/agent-tmux-window buffer) panes)))
    (plist-get pane :pid)))

;;; Commands

(declare-function ghostel "ghostel")
(declare-function rsr/agent-sessions--create-terminal "agent-sessions")
(declare-function rsr/agent-sessions--terminal-send "agent-sessions")
(declare-function rsr/agent-sessions--new-terminal-at-point "agent-sessions")
(declare-function rsr/agent-sessions--ask-folder-for "agent-sessions")
(defvar rsr/agent-sessions-terminal)

;;;###autoload
(defun rsr/agent-tmux-terminal (&optional plain)
  "Attach to this repository's tmux session in a ghostel buffer.
The session is named after the git repository and created on first use;
outside a repository you are asked for its name.  With prefix argument
PLAIN, open a plain ghostel shell instead."
  (interactive "P")
  (if plain
      (ghostel)
    (pcase-let ((`(,session . ,dir) (rsr/agent-tmux-target)))
      (rsr/agent-tmux-show session dir nil t))))

(defun rsr/agent-tmux-agent (program)
  "Open a tracked agent-sessions terminal in a new tmux window and run PROGRAM.
In the dashboard the tmux session and folder come from point, as for `+'.
Elsewhere both the session (`rsr/agent-tmux-read-target') and the folder
are asked."
  (require 'agent-sessions)
  (let* ((rsr/agent-sessions-terminal 'tmux)
         (buf (if (derived-mode-p 'rsr/agent-sessions-mode)
                  (or (rsr/agent-sessions--new-terminal-at-point)
                      (user-error "No worktree at point"))
                (let ((rsr/agent-tmux--target (rsr/agent-tmux-read-target)))
                  (rsr/agent-sessions--create-terminal
                   (cdr rsr/agent-tmux--target))))))
    (rsr/agent-sessions--terminal-send buf program)
    (unless (derived-mode-p 'rsr/agent-sessions-mode)
      (rsr/agent-sessions--ask-folder-for buf))
    buf))

;;;###autoload
(defun rsr/agent-tmux-default (&optional prefix)
  "Open the configured default agent, or its alternate with PREFIX."
  (interactive "P")
  (require 'agent-sessions)
  (rsr/agent-tmux-agent (rsr/agent-sessions-select-agent prefix)))

(defun rsr/agent-tmux-claude ()
  "Open Claude Code in a new window of this repository's tmux session."
  (interactive)
  (rsr/agent-tmux-agent "claude"))

;;;###autoload
(defun rsr/agent-tmux-pi ()
  "Open pi in a new window of this repository's tmux session."
  (interactive)
  (rsr/agent-tmux-agent "pi"))

(provide 'agent-sessions-tmux)
;;; agent-sessions-tmux.el ends here
