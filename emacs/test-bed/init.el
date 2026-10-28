;;; init.el --- isolated test config for bp's agent-sessions -*- lexical-binding: t -*-
;;
;; Launch:  open -na Emacs --args --init-directory ~/Stillness/Development/customize-agents/emacs/test-bed
;; (via launchd, so it doesn't inherit the launching shell's tmux/Claude env)
;;
;; Reuses the packages already installed in ~/.emacs.d/elpa (read-only), runs
;; its own server named "agent-test" so the main Emacs ("server") is untouched,
;; and keeps its SQLite db inside this directory.

;; --- packages: reuse ~/.emacs.d/elpa, never fetch ---------------------------
(setq package-user-dir (expand-file-name "~/.emacs.d/elpa")
      package-archives nil)
(package-initialize)
(require 'magit)

;; --- ghostel ----------------------------------------------------------------
;; Comes from ~/.emacs.d/elpa like everything else (activated above).
(with-eval-after-load 'ghostel
  ;; Ghostty's built-in colours, as in ~/.emacs.d/modules/personal/terminal-config.el.
  (set-face-attribute 'ghostel-default nil :foreground "#ffffff" :background "#282c34")
  (cl-loop for (name color) on
           '(black "#1d1f21" red "#cc6666" green "#b5bd68" yellow "#f0c674"
             blue "#81a2be" magenta "#b294bb" cyan "#8abeb7" white "#c5c8c6"
             bright-black "#666666" bright-red "#d54e53" bright-green "#b9ca4a"
             bright-yellow "#e7c547" bright-blue "#7aa6da" bright-magenta "#c397d8"
             bright-cyan "#70c0b1" bright-white "#eaeaea")
           by #'cddr
           do (set-face-attribute (intern (format "ghostel-color-%s" name)) nil
                                  :foreground color :background color))
  ;; Download a matching module if a future update needs one, without asking.
  (setq ghostel-module-auto-install 'download)
  ;; ~50k lines of history at ~130 columns (default 5 MB keeps ~4k).
  (setq ghostel-max-scrollback (* 60 1024 1024))
  ;; Emacs launched from a shell leaks TMUX*, TERM_PROGRAM*, GHOSTTY_* and
  ;; CLAUDE* into every terminal: tmux thinks it's nested, yazi thinks it's in
  ;; Ghostty proper, and Claude marks itself a child session and stops saving
  ;; transcripts.  A bare "KEY" in `ghostel-environment' unsets it.
  (setq ghostel-environment
        (seq-keep (lambda (kv)
                    (let ((k (car (split-string kv "="))))
                      (and (string-match-p
                            "\\`\\(TMUX\\|TERM_PROGRAM\\|GHOSTTY_\\|CLAUDE\\)" k)
                           k)))
                  process-environment)))
(global-set-key (kbd "C-c t") #'ghostel)

;; --- own server, so emacsclient from the main Emacs is unaffected -----------
(setq server-name "agent-test")

;; --- agent-sessions ---------------------------------------------------------
(add-to-list 'load-path
             (expand-file-name "../agent-sessions" user-emacs-directory))
(require 'agent-sessions)

(setq rsr/agent-sessions-db-file (expand-file-name "agent-sessions.db" user-emacs-directory)
      rsr/agent-sessions-terminal 'ghostel
      rsr/agent-sessions-show-all-worktrees t)

;; The hook scripts and emacs-share call plain `emacsclient -e`, which targets
;; the default socket "server" (the main Emacs). Point them at this instance by
;; injecting EMACS_SOCKET_NAME into every session terminal's environment.
(defun rsr/agent-sessions--add-socket-env (env)
  (cons (format "EMACS_SOCKET_NAME=%s" server-name) env))
(advice-add 'rsr/agent-sessions--terminal-environment
            :filter-return #'rsr/agent-sessions--add-socket-env)

;; Keys: bp binds these under his M-m prefix; here they live under C-c a.
(define-prefix-command 'rsr/agent-prefix-map)
(global-set-key (kbd "C-c a") 'rsr/agent-prefix-map)
(define-key rsr/agent-prefix-map (kbd "a") #'rsr/agent-sessions-list)
(define-key rsr/agent-prefix-map (kbd "s") #'rsr/agent-sessions-send-region)
(with-eval-after-load 'ghostel
  (define-key ghostel-mode-map (kbd "C-c C-l") #'rsr/agent-session-insert-org-link))
(add-to-list 'project-switch-commands '(rsr/agent-session-switch-or-new "Agent Session"))

;; Advice on eat, focus hook, Org link type, C-x p a, and server-start.
(rsr/agent-session-setup)

;; --- Linear -----------------------------------------------------------------
;; linear-emacs is cloned, not on MELPA. Its deps (request, dash, s) come from
;; ~/.emacs.d/elpa. Issues land in this directory, not in the Brain repo.
(add-to-list 'load-path
             (expand-file-name "~/Stillness/Development/cloned-projects/linear-emacs"))
(require 'org)
(require 'linear-emacs)
(setq linear-emacs-org-file-path (expand-file-name "linear.org" user-emacs-directory))

;; The key lives in ~/.emacs.d/secrets.el.gpg as `my/linear-key'. Decrypt it on
;; the first Linear request rather than at startup, so launching never prompts.
(defun rsr/linear-load-key (&rest _)
  (unless linear-emacs-api-key
    (require 'epa-file)
    (setq epg-pinentry-mode 'loopback)
    (load "~/.emacs.d/secrets.el.gpg")
    (setq linear-emacs-api-key (if (functionp 'my/linear-key)
                                   (my/linear-key)
                                 my/linear-key))))
(advice-add 'linear-emacs--headers :before #'rsr/linear-load-key)

;; Hook wiring into ~/.claude/settings.json, ~/.codex/hooks.json and
;; ~/.pi/agent/extensions is NOT run automatically. Do it once, explicitly:
;;   M-x rsr/agent-sessions-install      (M-x rsr/agent-sessions-uninstall to undo)

(message "agent-sessions test config loaded; server=%s" server-name)
;;; init.el ends here
