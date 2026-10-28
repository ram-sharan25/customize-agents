import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { RunSnapshot } from "../domain.ts";
export const SESSION_ENTRY = "requirements-plan-state";
export function persistRun(pi: ExtensionAPI, run: RunSnapshot | undefined): void { pi.appendEntry(SESSION_ENTRY, run ? { run } : { run: null }); }
export function restoreRun(ctx: ExtensionContext): RunSnapshot | undefined { let run: RunSnapshot | undefined; for (const e of ctx.sessionManager.getBranch()) if (e.type === "custom" && e.customType === SESSION_ENTRY) run = (e.data as any)?.run ?? undefined; return run; }
