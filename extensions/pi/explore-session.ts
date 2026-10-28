/**
 * explore-session — Pi side of the shared `explore-session` skill.
 *
 * Opens a child pi session in a new window of the current tmux session with a
 * curated brief (or, on request, a copy of the current branch), and carries
 * the child's one-line "done" notice back into the live parent session.
 *
 * Pieces:
 *  - tool `open_exploration_session` (parent, model-callable): resolves the
 *    exploration directory and writes brief.md through the skill's shared
 *    scripts/template, then runs scripts/open-window.sh.
 *  - tool `report_to_parent` (child only, registered when the window was
 *    opened by this extension): sends the notice over the parent's inbox
 *    socket; falls back to an inbox file.
 *  - inbox listener (every session): a Unix socket at
 *    /tmp/pi-explore-<uid>/<session id>.sock, bound in `session_start` and
 *    closed in `session_shutdown`.  A notice becomes a displayed custom
 *    message (`triggerTurn: false`): it is in context for the next turn but
 *    starts none and never touches the editor.  Pi has no cross-process
 *    messaging of its own (verified 1.4.0), so this socket is the one new
 *    transport; it is pi-to-pi only.
 *  - command `/explore <topic>`: asks the model to use the tool.
 *
 * The three-step flow (open -> one-line notice -> "bring in" reads only
 * summary.md) and the file layout are described in skills/explore-session/SKILL.md.
 */

import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const NOTICE_TYPE = "explore-notice";
const INBOX_ROOT = `/tmp/pi-explore-${os.userInfo().uid}`;
const SOCKET_TIMEOUT_MS = 3000;
const MAX_LINE_BYTES = 64 * 1024;

// ---------------------------------------------------------------------------
// Locating the shared skill (scripts + brief template)

function skillDir(): string {
	const candidates: string[] = [];
	try {
		// extensions/pi/explore-session.ts -> skills/explore-session (same repo)
		const here = path.dirname(new URL(import.meta.url).pathname);
		candidates.push(path.resolve(here, "..", "..", "skills", "explore-session"));
	} catch {
		// import.meta.url unavailable under this loader; fall through.
	}
	candidates.push(path.join(process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), ".pi", "agent"), "skills", "explore-session"));
	candidates.push(path.join(os.homedir(), ".pi", "agent", "skills", "explore-session"));
	for (const c of candidates) {
		if (fs.existsSync(path.join(c, "scripts", "open-window.sh"))) return c;
	}
	throw new Error(`explore-session skill not found (looked in ${candidates.join(", ")})`);
}

function slugify(text: string): string {
	return (
		text
			.toLowerCase()
			.replace(/[^a-z0-9]+/g, "-")
			.replace(/^-+|-+$/g, "")
			.slice(0, 48)
			.replace(/-+$/g, "") || "exploration"
	);
}

function fillTemplate(template: string, values: Record<string, string>): string {
	return template.replace(/\{\{(\w+)\}\}/g, (_m, key: string) => values[key] ?? `{{${key}}}`);
}

function bulletize(items: string[] | undefined, empty: string): string {
	const clean = (items ?? []).map((s) => s.trim()).filter(Boolean);
	return clean.length ? clean.map((s) => `- ${s}`).join("\n") : empty;
}

function socketPathFor(sessionId: string): string {
	return path.join(INBOX_ROOT, `${sessionId}.sock`);
}

function inboxDirFor(sessionId: string): string {
	return path.join(INBOX_ROOT, "inbox", sessionId);
}

function ensureInboxRoot(): void {
	fs.mkdirSync(INBOX_ROOT, { recursive: true, mode: 0o700 });
}

// Copy the current branch into a new session file (what /clone writes), so a
// child can start from the parent's context while the parent is untouched.
// Same shape as SessionManager.createBranchedSession: a version-3 header with
// `parentSession`, then the root->leaf entries verbatim (ids and parentIds
// kept, so the chain stays valid).
function writeBranchCopy(ctx: ExtensionContext): string | null {
	const sm = ctx.sessionManager;
	const parentFile = sm.getSessionFile();
	const branch = sm.getBranch();
	if (!parentFile || !fs.existsSync(parentFile) || branch.length === 0) return null;
	const id = randomUUID();
	const timestamp = new Date().toISOString();
	const file = path.join(sm.getSessionDir(), `${timestamp.replace(/[:.]/g, "-")}_${id}.jsonl`);
	const header = { type: "session", version: 3, id, timestamp, cwd: sm.getCwd(), parentSession: parentFile };
	const lines = [JSON.stringify(header), ...branch.map((e) => JSON.stringify(e))];
	fs.writeFileSync(file, `${lines.join("\n")}\n`, { mode: 0o600 });
	return file;
}

// ---------------------------------------------------------------------------

export default function (pi: ExtensionAPI) {
	let server: net.Server | null = null;
	let boundPath: string | null = null;
	let currentCtx: ExtensionContext | null = null;

	const childMode = process.env.EXPLORE_PARENT_AGENT === "pi" && !!process.env.EXPLORE_PARENT_SOCKET;

	// --- Parent inbox --------------------------------------------------------

	function deliverNotice(text: string): void {
		const line = text.trim();
		if (!line) return;
		pi.sendMessage({ customType: NOTICE_TYPE, content: line, display: true }, { triggerTurn: false });
		try {
			currentCtx?.ui.notify(line, "info");
		} catch {
			// UI may be gone; the message entry is what matters.
		}
	}

	function drainInbox(sessionId: string): void {
		const dir = inboxDirFor(sessionId);
		if (!fs.existsSync(dir)) return;
		for (const name of fs.readdirSync(dir).sort()) {
			const file = path.join(dir, name);
			try {
				const msg = JSON.parse(fs.readFileSync(file, "utf8")) as { type?: string; text?: string };
				if (msg.type === NOTICE_TYPE && typeof msg.text === "string") deliverNotice(msg.text);
			} catch {
				// Unreadable inbox file: drop it below.
			}
			fs.rmSync(file, { force: true });
		}
	}

	function closeServer(): void {
		if (server) {
			try {
				server.close();
			} catch {
				// already closed
			}
			server = null;
		}
		if (boundPath) {
			fs.rmSync(boundPath, { force: true });
			boundPath = null;
		}
	}

	function bindServer(sessionId: string): void {
		closeServer();
		ensureInboxRoot();
		const sockPath = socketPathFor(sessionId);
		fs.rmSync(sockPath, { force: true });
		const srv = net.createServer((socket) => {
			let buf = "";
			let done = false;
			socket.setEncoding("utf8");
			socket.setTimeout(SOCKET_TIMEOUT_MS, () => socket.destroy());
			socket.on("data", (chunk: string) => {
				if (done) return;
				buf += chunk;
				if (buf.length > MAX_LINE_BYTES) {
					done = true;
					socket.end("error: too long\n");
					return;
				}
				const nl = buf.indexOf("\n");
				if (nl < 0) return;
				done = true;
				try {
					const msg = JSON.parse(buf.slice(0, nl)) as { type?: string; text?: string };
					if (msg.type === NOTICE_TYPE && typeof msg.text === "string") {
						deliverNotice(msg.text);
						socket.end("ok\n");
					} else {
						socket.end("error: unknown message\n");
					}
				} catch {
					socket.end("error: bad json\n");
				}
			});
			socket.on("error", () => socket.destroy());
		});
		srv.on("error", (err) => {
			try {
				currentCtx?.ui.notify(`explore-session inbox unavailable: ${err.message}`, "warning");
			} catch {
				// no UI
			}
		});
		srv.listen(sockPath, () => {
			try {
				fs.chmodSync(sockPath, 0o600);
			} catch {
				// best effort
			}
		});
		server = srv;
		boundPath = sockPath;
	}

	pi.on("session_start", async (_event, ctx) => {
		currentCtx = ctx;
		const sessionId = ctx.sessionManager.getSessionId();
		bindServer(sessionId);
		drainInbox(sessionId);
		if (childMode && process.env.EXPLORE_SLUG) {
			try {
				ctx.ui.setStatus("explore", `exploring ${process.env.EXPLORE_SLUG} for parent pi`);
			} catch {
				// no UI
			}
		}
	});

	pi.on("session_shutdown", async () => {
		closeServer();
		currentCtx = null;
	});

	// --- Parent: open a child ---------------------------------------------------

	const OpenParams = Type.Object({
		topic: Type.String({ description: "The tangent to explore, in the user's words (one short paragraph)." }),
		goal: Type.Optional(Type.String({ description: "What the parent wants to learn or decide from it." })),
		context: Type.Optional(
			Type.String({
				description:
					"At most 10 lines of pointers and facts the child cannot get from the files. Never transcript, tool output, or file contents.",
			}),
		),
		files: Type.Optional(Type.Array(Type.String(), { description: "Absolute paths worth reading first, with line ranges or symbols when known." })),
		constraints: Type.Optional(Type.Array(Type.String(), { description: "Extra constraints for the child, as short bullets." })),
		slug: Type.Optional(Type.String({ description: "kebab-case name (<= 48 chars); derived from topic when omitted." })),
		task_dir: Type.Optional(
			Type.String({
				description:
					"When this conversation is about a Plans task, its directory /Users/rrimal/Stillness/Agent_Stuffs/Plans/<project>/<task>; findings then go under its artifacts/. Otherwise omit: they go under the cwd repo's Plans/<repo>/artifacts/explorations/.",
			}),
		),
		root: Type.Optional(
			Type.String({
				description:
					"Only after the directory step refused (no repo, or no Plans project for it) and the user named a folder: the parent directory to create the exploration in.",
			}),
		),
		fork: Type.Optional(Type.Boolean({ description: "Only when the user explicitly said 'fork': start the child from a copy of this session's current branch." })),
		focus: Type.Optional(Type.Boolean({ description: "Switch to the new tmux window (default true)." })),
		start_now: Type.Optional(Type.String({ description: "A task the child should start on immediately; otherwise it acknowledges the brief and waits." })),
	});

	pi.registerTool({
		name: "open_exploration_session",
		label: "Open exploration session",
		description:
			"Open a separate pi session in a new window of the current tmux session to explore one tangent, seeded with a curated brief (topic, minimal context, file pointers), so this conversation stays clean. Use when the user asks to open a new session to explore, understand, or learn something on the side. Set fork only when the user explicitly says 'fork'. Requires tmux.",
		promptSnippet: "Open a separate exploration session in a new tmux window with a curated brief",
		promptGuidelines: [
			"Use open_exploration_session only when the user asks for a separate session to explore a tangent; pass pointers, not transcript or file contents, as context.",
		],
		parameters: OpenParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			if (!process.env.TMUX || !process.env.TMUX_PANE) {
				throw new Error("not inside tmux; nothing opened. Explorations need this pi to run in a tmux window.");
			}
			const skill = skillDir();
			const scripts = path.join(skill, "scripts");
			const slug = slugify(params.slug || params.topic);

			// 1. Directory (the script owns the layout rules and the no-project refusal).
			const dirArgs = ["--slug", slug];
			if (params.task_dir) dirArgs.push("--task-dir", params.task_dir);
			else if (params.root) dirArgs.push("--root", params.root);
			const dirRes = await pi.exec(path.join(scripts, "explore-dir.sh"), dirArgs, { cwd: ctx.cwd });
			if (dirRes.code !== 0) {
				throw new Error(dirRes.stderr.trim() || `explore-dir.sh exited ${dirRes.code}`);
			}
			const dir = dirRes.stdout.trim();

			// 2. Brief.
			const sm = ctx.sessionManager;
			const sessionId = sm.getSessionId();
			const sock = socketPathFor(sessionId);
			const name = pi.getSessionName();
			const template = fs.readFileSync(path.join(skill, "brief-template.md"), "utf8");
			const brief = fillTemplate(template, {
				slug,
				parent_agent: "pi",
				parent_address: `pi session id ${sessionId}${name ? ` ("${name}")` : ""}, inbox socket ${sock}`,
				parent_tmux: process.env.TMUX_PANE ? `pane ${process.env.TMUX_PANE} (see EXPLORE_PARENT_TMUX)` : "unknown",
				topic: params.topic.trim(),
				goal: (params.goal || "Understand the topic well enough to answer the parent's question.").trim(),
				context: (params.context || "(none given)").trim(),
				files: bulletize(params.files, "- (none named)"),
				constraints: bulletize(params.constraints, "- none beyond the shared rules"),
				dir,
				report_instruction: "Call the `report_to_parent` tool; it sends this line to the parent's inbox for you.",
				start: params.start_now
					? `Start now: ${params.start_now.trim()} Report progress to the user here, not to the parent.`
					: "Acknowledge this brief in at most two lines and wait for the user.",
			});
			fs.writeFileSync(path.join(dir, "brief.md"), brief, { mode: 0o644 });

			// 3. Optional branch copy for fork mode.
			let sessionFile: string | null = null;
			let forkNote = "";
			if (params.fork) {
				sessionFile = writeBranchCopy(ctx);
				if (!sessionFile) forkNote = "\nnote: this session has no saved branch yet, so the child starts from the brief only.";
			}

			// 4. Window.
			const args = ["--agent", "pi", "--slug", slug, "--dir", dir, "--cwd", ctx.cwd];
			if (sessionFile) args.push("--fork", "--session-file", sessionFile);
			if (params.focus === false) args.push("--no-focus");
			args.push("--env", `EXPLORE_PARENT_SOCKET=${sock}`, "--env", `EXPLORE_PARENT_SESSION_ID=${sessionId}`);
			if (name) args.push("--env", `EXPLORE_PARENT_NAME=${name}`);
			const res = await pi.exec(path.join(scripts, "open-window.sh"), args, { cwd: ctx.cwd });
			if (res.code !== 0) {
				throw new Error(res.stderr.trim() || `open-window.sh exited ${res.code}`);
			}
			const text = `${res.stdout.trim()}${forkNote}`;
			return {
				content: [{ type: "text", text }],
				details: { slug, dir, sessionFile, output: res.stdout },
			};
		},
	});

	pi.registerCommand("explore", {
		description: "Open an exploration session in a new tmux window: /explore <topic>",
		handler: async (args, ctx) => {
			const topic = (args || "").trim();
			if (!topic) {
				ctx.ui.notify("Usage: /explore <topic> — or just ask to open a new session to explore something.", "info");
				return;
			}
			pi.sendUserMessage(
				`Open an exploration session for this tangent using the open_exploration_session tool: ${topic}\nGive it a curated brief (topic, goal, at most 10 lines of context, file pointers). Do not fork unless I said "fork".`,
			);
		},
	});

	// --- Child: report back -----------------------------------------------------

	if (childMode) {
		pi.registerTool({
			name: "report_to_parent",
			label: "Report to parent session",
			description:
				"Send the parent pi session the one-line notice that this exploration is done and ready to bring in. Only when the user says to report back, and only after summary.md (<= 12 lines) and findings.md exist in the exploration directory.",
			promptSnippet: "Send the parent session the one-line 'exploration done' notice",
			parameters: Type.Object({
				text: Type.Optional(Type.String({ description: "Override for the notice line; normally omitted." })),
			}),
			async execute(_toolCallId, params) {
				const dir = process.env.EXPLORE_DIR || "";
				const slug = process.env.EXPLORE_SLUG || "unknown";
				const sock = process.env.EXPLORE_PARENT_SOCKET || "";
				const parentId = process.env.EXPLORE_PARENT_SESSION_ID || "";
				if (!dir || !fs.existsSync(path.join(dir, "summary.md"))) {
					throw new Error(`write ${path.join(dir || "<EXPLORE_DIR>", "summary.md")} (<= 12 lines) before reporting back`);
				}
				const text = (params.text || `exploration ${slug} done — ready to bring in (${dir})`).trim().split("\n")[0];
				const payload = `${JSON.stringify({ type: NOTICE_TYPE, slug, dir, text })}\n`;

				const sent = await new Promise<string | null>((resolve) => {
					const client = net.createConnection(sock);
					let reply = "";
					const fail = (why: string) => {
						client.destroy();
						resolve(why);
					};
					client.setTimeout(SOCKET_TIMEOUT_MS, () => fail("timeout"));
					client.on("error", (e) => fail(e.message));
					client.on("connect", () => client.write(payload));
					client.on("data", (d) => {
						reply += d.toString();
					});
					client.on("close", () => resolve(reply.startsWith("ok") ? null : reply.trim() || "no acknowledgement"));
				});

				type ReportDetails = { delivered: boolean; text: string; reason?: string };
				if (sent === null) {
					const details: ReportDetails = { delivered: true, text };
					return { content: [{ type: "text", text: `sent to parent: ${text}` }], details };
				}
				// Parent unreachable: leave the notice where its next session_start drains it.
				let fallback = "";
				if (parentId) {
					const inbox = inboxDirFor(parentId);
					fs.mkdirSync(inbox, { recursive: true, mode: 0o700 });
					const file = path.join(inbox, `${Date.now()}.json`);
					fs.writeFileSync(file, `${JSON.stringify({ type: NOTICE_TYPE, slug, dir, text })}\n`, { mode: 0o600 });
					fallback = ` Left a copy at ${file}; the parent picks it up when it next starts.`;
				}
				const details: ReportDetails = { delivered: false, reason: sent, text };
				return {
					content: [
						{
							type: "text",
							text: `parent inbox unreachable (${sent}).${fallback} Tell the user the notice could not be delivered live; the summary is at ${path.join(dir, "summary.md")}.`,
						},
					],
					details,
				};
			},
		});
	}
}
