;;; agent-sessions-config.el --- dashboard for agent sessions in ghostel -*- lexical-binding: t -*-
;;
;; Copy to ~/.emacs.d/modules/personal/agent-sessions-config.el.  The package
;; itself stays in the customize-agents repo and is loaded from there.

(require 'magit)

(add-to-list 'load-path (expand-file-name "~/Stillness/Development/customize-agents/emacs/agent-sessions"))
(require 'agent-sessions)

(setq rsr/agent-sessions-terminal 'ghostel
      rsr/agent-sessions-show-all-worktrees t)
;; db defaults to ~/.emacs.d/agent-sessions.db

;; C-c i is the AI and agents prefix (ai-keymap.el).
(keymap-set rsr/ai-map "d" #'rsr/agent-sessions-list)
(keymap-set rsr/ai-map "r" #'rsr/agent-sessions-send-region)

(with-eval-after-load 'ghostel
  (define-key ghostel-mode-map (kbd "C-c C-l") #'rsr/agent-session-insert-org-link))

(add-to-list 'project-switch-commands '(rsr/agent-session-switch-or-new "Agent Session"))

;; Advice on ghostel, focus hook, Org link type, C-x p a, server-start.
(rsr/agent-session-setup)

;; Hook wiring is explicit and one-time: M-x rsr/agent-sessions-install

(provide 'agent-sessions-config)
;;; agent-sessions-config.el ends here
