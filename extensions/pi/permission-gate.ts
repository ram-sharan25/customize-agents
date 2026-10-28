/**
 * Ask for confirmation before potentially destructive bash commands.
 * Uses a fast secondary model to briefly explain the command's impact.
 */
import { complete, type Api, type Model, type UserMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext, ModelRegistry } from "@earendil-works/pi-coding-agent";

const FAST_MODEL_IDS = ["gpt-5.4-mini", "gpt-5.3-codex-spark", "claude-haiku-4-5"];
const DANGEROUS_PATTERNS = [
	/\brm\s+(-rf?|--recursive)/i,
	/\bsudo\b/i,
	/\b(chmod|chown)\b.*777/i,
	/\bgit\s+(reset\s+--hard|clean\s+-fd)/i,
	/\bmkfs(?:\.|\s)/i,
	/\bdd\s+.*\bof=\/dev\//i,
];

async function selectExplanationModel(
	currentModel: Model<Api> | undefined,
	modelRegistry: ModelRegistry,
): Promise<Model<Api> | undefined> {
	for (const modelId of FAST_MODEL_IDS) {
		const provider = modelId.startsWith("claude") ? "anthropic" : "openai-codex";
		const model = modelRegistry.find(provider, modelId);
		if (model) {
			const auth = await modelRegistry.getApiKeyAndHeaders(model);
			if (auth.ok) return model;
		}
	}
	return currentModel;
}

async function explainCommand(command: string, ctx: ExtensionContext): Promise<string> {
	const model = await selectExplanationModel(ctx.model, ctx.modelRegistry);
	if (!model) return "This command will execute with your user permissions.";

	const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
	if (!auth.ok) return "This command will execute with your user permissions.";

	const userMessage: UserMessage = {
		role: "user",
		content: [{ type: "text", text: `Explain this shell command in one short sentence: ${command}` }],
		timestamp: Date.now(),
	};

	try {
		const response = await complete(
			model,
			{
				systemPrompt:
					"You explain shell commands for a confirmation dialog. State what it changes, deletes, or accesses. Be concise, factual, and do not give advice. Never execute the command.",
				messages: [userMessage],
			},
			{ apiKey: auth.apiKey, headers: auth.headers, signal: AbortSignal.timeout(8000) },
		);

		if (response.stopReason === "error" || response.stopReason === "aborted") {
			return "This command will execute with your user permissions.";
		}
		const text = response.content
			.filter((part): part is { type: "text"; text: string } => part.type === "text")
			.map((part) => part.text)
			.join(" ")
			.trim();
		return text ? text.slice(0, 500) : "This command will execute with your user permissions.";
	} catch {
		return "This command will execute with your user permissions.";
	}
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return undefined;

		const command = typeof event.input.command === "string" ? event.input.command : "";
		if (!DANGEROUS_PATTERNS.some((pattern) => pattern.test(command))) return undefined;

		if (!ctx.hasUI) {
			return { block: true, reason: "Dangerous command blocked (no UI for confirmation)" };
		}

		const explanation = await explainCommand(command, ctx);
		const choice = await ctx.ui.select(
			`⚠️ Dangerous command:\n\n  ${command}\n\n${explanation}\n\nAllow?`,
			["Yes", "No"],
		);

		if (choice !== "Yes") return { block: true, reason: "Blocked by user" };
		return undefined;
	});
}
