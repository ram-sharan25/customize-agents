# Pi instructions

Shared rules for every agent (git, answer depth, planning lifecycle, install location, questions, verification) load from `~/.pi/agent/APPEND_SYSTEM.md`, which links to `instructions/shared/core.md` in customize-agents.

## Pi configuration

Pi's home is `/Users/rrimal/.pi/agent/`; Pi's own data (sessions, auth, trust, caches, installed packages) lives there. Its shared configuration — these instructions, `settings.json`, skills, extensions, and prompts — lives in `/Users/rrimal/Stillness/Development/customize-agents/` and is linked into Pi's home one hop deep. Edit the repo copy; never create a second copy, and keep `~/.config` free of agent configuration.
