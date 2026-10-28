/**
 * Automatically give each Pi session a compact task name.
 *
 * A fast secondary model names the task from the first prompt and recent
 * conversation context. Names are persisted as Pi session names, which Pi
 * also exposes in the terminal pane title for tmux/Fleet.
 */
import { complete, type Api, type Model, type UserMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext, ModelRegistry } from "@earendil-works/pi-coding-agent";

const STATE_TYPE = "auto-task-name";
const FAST_MODELS: Array<[provider: string, modelId: string]> = [
	["openai-codex", "gpt-5.4-mini"],
	["openai-codex", "gpt-5.3-codex-spark"],
	["anthropic", "claude-haiku-4-5"],
];
const MAX_CONTEXT_CHARS = 6000;
const MAX_NAME_CHARS = 32;
const ACTIONS = new Set([
	"add", "analyze", "audit", "build", "clean", "compare", "configure", "debug", "design", "document",
	"explain", "fix", "implement", "improve", "investigate", "migrate", "name", "optimize", "plan", "refactor",
	"remove", "rename", "repair", "research", "review", "simplify", "test", "update", "upgrade", "validate",
]);
const STOP_WORDS = new Set([
	"a", "an", "and", "are", "as", "at", "automatic", "automatically", "be", "can", "could", "do", "does",
	"for", "from", "how", "i", "in", "is", "it", "lets", "like", "may", "me", "of", "ok", "on", "only", "or",
	"our", "please", "reply", "should", "the", "then", "this", "to", "we", "what", "with", "would", "you",
]);

interface PersistedNameState {
	version: 1;
	name?: string;
	automatic: boolean;
}

const SYSTEM_PROMPT = `Name the active coding-agent task from the conversation.

Return only a lowercase kebab-case slug. No quotes, JSON, markdown, or explanation.

Rules:
- Prefer exactly two words; never exceed three words.
- First word is a specific imperative action verb.
- Remaining words identify the concrete object or outcome.
- Maximum 32 characters.
- Do not include the repository/project or platform name; it is displayed separately.
- Name the central deliverable, ignoring incidental instructions such as "reply OK".
- Avoid vague names such as work-task, make-changes, handle-request, or update-code.
- Resolve references in the latest request (such as "implement this") from the preceding context.

Examples:
design-statusline
fix-notifications
research-terminals
configure-fleet
refactor-session-manager`;

async function selectNamingModel(modelRegistry: ModelRegistry): Promise<Model<Api> | undefined> {
	for (const [provider, modelId] of FAST_MODELS) {
		const model = modelRegistry.find(provider, modelId);
		if (!model) continue;
		const auth = await modelRegistry.getApiKeyAndHeaders(model);
		if (auth.ok) return model;
	}
	return undefined;
}

function wordsFrom(value: string): string[] {
	return value
		.toLowerCase()
		.replace(/['’]/g, "")
		.replace(/[^a-z0-9]+/g, "-")
		.split("-")
		.filter(Boolean);
}

function inferAction(prompt: string): string {
	const text = prompt.toLowerCase();
	const patterns: Array<[RegExp, string]> = [
		[/\b(fix|debug|repair|resolve)\b/, "fix"],
		[/\b(research|investigate|explore|find out)\b/, "research"],
		[/\b(compare|choose|recommend)\b/, "compare"],
		[/\b(remove|delete|disable|drop)\b/, "remove"],
		[/\b(configure|setup|set up)\b/, "configure"],
		[/\b(refactor|restructure)\b/, "refactor"],
		[/\b(test|verify|validate|check)\b/, "validate"],
		[/\b(review|inspect|audit)\b/, "review"],
		[/\b(plan|design|discuss)\b/, "design"],
		[/\b(rename|name)\b/, "rename"],
		[/\b(update|upgrade)\b/, "update"],
		[/\b(improve|simplify|optimize)\b/, "improve"],
		[/\b(implement|build|create|add|make)\b/, "implement"],
	];
	for (const [pattern, action] of patterns) {
		if (pattern.test(text)) return action;
	}
	return "implement";
}

function fallbackName(prompt: string): string {
	const action = inferAction(prompt);
	const candidates = wordsFrom(prompt).filter(
		(word) => !STOP_WORDS.has(word) && !ACTIONS.has(word) && word.length > 1,
	);
	return normalizeName([action, ...candidates.slice(0, 2)].join("-"), prompt) ?? "name-task";
}

function normalizeName(value: string, prompt: string): string | undefined {
	let words = wordsFrom(value).filter((word) => !STOP_WORDS.has(word));
	if (words.length === 0) return undefined;
	if (!ACTIONS.has(words[0])) words.unshift(inferAction(prompt));
	words = words.slice(0, 3);
	if (words.length === 1) words.push("task");

	while (words.join("-").length > MAX_NAME_CHARS && words.length > 2) words.pop();
	if (words.join("-").length > MAX_NAME_CHARS) {
		words[1] = words[1].slice(0, Math.max(3, MAX_NAME_CHARS - words[0].length - 1));
	}
	const name = words.join("-").replace(/-+$/g, "");
	return name.length >= 3 ? name : undefined;
}

function messageText(message: unknown): string {
	if (typeof message !== "object" || message === null) return "";
	const record = message as { role?: unknown; content?: unknown };
	if (record.role !== "user" && record.role !== "assistant") return "";
	if (typeof record.content === "string") return `${record.role}: ${record.content}`;
	if (!Array.isArray(record.content)) return "";
	const text = record.content
		.filter((part): part is { type: "text"; text: string } =>
			typeof part === "object" && part !== null && (part as { type?: unknown }).type === "text" &&
			typeof (part as { text?: unknown }).text === "string")
		.map((part) => part.text)
		.join("\n");
	return text ? `${record.role}: ${text}` : "";
}

function namingContext(prompt: string, ctx: ExtensionContext): string {
	const messages: string[] = [];
	for (const entry of ctx.sessionManager.getBranch()) {
		if (entry.type !== "message") continue;
		const text = messageText(entry.message);
		if (text) messages.push(text);
	}
	messages.push(`user (latest request): ${prompt}`);
	return messages.join("\n\n").slice(-MAX_CONTEXT_CHARS);
}

function latestState(ctx: ExtensionContext): PersistedNameState | undefined {
	let state: PersistedNameState | undefined;
	for (const entry of ctx.sessionManager.getBranch()) {
		if (entry.type !== "custom" || entry.customType !== STATE_TYPE) continue;
		const data = entry.data as Partial<PersistedNameState> | undefined;
		if (data?.version === 1 && typeof data.automatic === "boolean") {
			state = {
				version: 1,
				automatic: data.automatic,
				name: typeof data.name === "string" ? data.name : undefined,
			};
		}
	}
	return state;
}

async function generateName(prompt: string, context: string, ctx: ExtensionContext, signal: AbortSignal): Promise<string> {
	try {
		const model = await selectNamingModel(ctx.modelRegistry);
		if (!model || signal.aborted) return fallbackName(prompt);
		const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
		if (!auth.ok || signal.aborted) return fallbackName(prompt);

		const userMessage: UserMessage = {
			role: "user",
			content: [{ type: "text", text: context }],
			timestamp: Date.now(),
		};
		const response = await complete(
			model,
			{ systemPrompt: SYSTEM_PROMPT, messages: [userMessage] },
			{ apiKey: auth.apiKey, headers: auth.headers, signal: AbortSignal.any([signal, AbortSignal.timeout(8000)]) },
		);
		if (response.stopReason === "error" || response.stopReason === "aborted") return fallbackName(prompt);
		const text = response.content
			.filter((part): part is { type: "text"; text: string } => part.type === "text")
			.map((part) => part.text)
			.join(" ");
		return normalizeName(text, prompt) ?? fallbackName(prompt);
	} catch {
		return fallbackName(prompt);
	}
}

export default function autoTaskName(pi: ExtensionAPI) {
	let shouldGenerate = false;
	let replaceExistingAutomatic = false;
	let generatedName: string | undefined;
	let pendingAutomaticName: string | undefined;
	let generation: Promise<void> | undefined;
	let abortController = new AbortController();
	let disposed = false;

	function persist(name: string | undefined, automatic: boolean): void {
		pi.appendEntry(STATE_TYPE, { version: 1, name, automatic } satisfies PersistedNameState);
	}

	function restore(event: { reason: "startup" | "reload" | "new" | "resume" | "fork" }, ctx: ExtensionContext): void {
		abortController.abort();
		abortController = new AbortController();
		disposed = false;
		generation = undefined;
		pendingAutomaticName = undefined;

		const currentName = pi.getSessionName();
		const state = latestState(ctx);
		const isAutomatic = Boolean(currentName && state?.automatic && state.name === currentName);
		replaceExistingAutomatic = event.reason === "fork" && isAutomatic;
		generatedName = isAutomatic && !replaceExistingAutomatic ? currentName : undefined;
		shouldGenerate = !currentName || replaceExistingAutomatic;
	}

	pi.on("session_start", async (event, ctx) => restore(event, ctx));
	pi.on("session_tree", async (_event, ctx) => {
		const state = latestState(ctx);
		const currentName = pi.getSessionName();
		generatedName = currentName && state?.automatic && state.name === currentName ? currentName : undefined;
		replaceExistingAutomatic = false;
		shouldGenerate = !currentName;
	});

	pi.on("session_info_changed", async (event) => {
		if (pendingAutomaticName && event.name === pendingAutomaticName) {
			generatedName = pendingAutomaticName;
			pendingAutomaticName = undefined;
			return;
		}
		// Any other name change came from the user, CLI, or another extension.
		generatedName = undefined;
		replaceExistingAutomatic = false;
		shouldGenerate = false;
		persist(event.name, false);
	});

	pi.on("before_agent_start", async (event, ctx) => {
		const existingName = pi.getSessionName();
		if (!shouldGenerate || generation || generatedName || (existingName && !replaceExistingAutomatic)) return;
		shouldGenerate = false;
		const prompt = event.prompt.trim();
		if (!prompt) return;
		const context = namingContext(prompt, ctx);
		const sessionFile = ctx.sessionManager.getSessionFile();

		generation = generateName(prompt, context, ctx, abortController.signal)
			.then((name) => {
				if (disposed || abortController.signal.aborted) return;
				if (ctx.sessionManager.getSessionFile() !== sessionFile || pi.getSessionName() !== existingName) return;
				pendingAutomaticName = name;
				generatedName = name;
				persist(name, true);
				pi.setSessionName(name);
			})
			.finally(() => {
				generation = undefined;
			});
	});

	// Ensure Fleet never observes a completed unnamed task, without delaying the
	// main agent's startup. Usually the background name is already ready here.
	pi.on("agent_settled", async () => {
		if (generation) await generation;
	});

	pi.on("session_shutdown", async () => {
		disposed = true;
		abortController.abort();
	});
}
