# Pi instructions

Shared rules for every agent (git, answer depth, planning lifecycle, install location, questions, verification) load from `~/.pi/agent/APPEND_SYSTEM.md`, which links to `instructions/shared/core.md` in customize-agents.

## Pi configuration

Pi's home is `~/.pi/agent/`; Pi's own data (sessions, auth, trust, caches, installed packages) lives there. Shared configuration belongs in the `customize-agents` repository, normally at `~/Stillness/Development/customize-agents/`, and is linked into Pi's home one hop deep. Resolve installed symlinks to locate the source repository. Edit the repo copy; never create a second copy, and keep `~/.config` free of agent configuration.
