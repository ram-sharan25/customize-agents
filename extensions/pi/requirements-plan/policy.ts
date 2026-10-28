import path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { RunSnapshot } from "./domain.ts";
const SUITE_TOOLS = new Set(["requirements_plan", "requirements_plan_stage", "requirements_plan_read"]);
export function assistantHasMixedStart(ctx: ExtensionContext): boolean { const entries = ctx.sessionManager.getBranch(); for (let i = entries.length - 1; i >= 0; i--) { const e: any = entries[i]; if (e.type !== "message" || e.message?.role !== "assistant") continue; const calls = Array.isArray(e.message.content) ? e.message.content.filter((b: any) => b?.type === "toolCall") : []; return calls.length > 1 && calls.some((c: any) => c.name === "requirements_plan" && c.arguments?.action === "start"); } return false; }
export function applyPolicy(pi: ExtensionAPI, run: RunSnapshot): void { if (!run.tools_before) run.tools_before = pi.getActiveTools(); pi.setActiveTools([...SUITE_TOOLS]); }
export function restorePolicy(pi: ExtensionAPI, run?: RunSnapshot): void { if (!run?.tools_before) return; const known = new Set(pi.getAllTools().map(t => t.name)); pi.setActiveTools(run.tools_before.filter(t => known.has(t))); }
export function authorizeRead(run: RunSnapshot, raw: string, cwd: string): string { const p = path.resolve(cwd, raw.replace(/^@/, "")); if (!run.allowed_reads.includes(p)) throw Object.assign(new Error(`Read blocked outside the active stage evidence: ${p}`), { code: "PATH_NOT_ALLOWED" }); return p; }
export function toolAllowed(run: RunSnapshot | undefined, name: string): boolean { return !run?.active || SUITE_TOOLS.has(name); }
