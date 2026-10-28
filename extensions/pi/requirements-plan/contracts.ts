import type { Action, Result, ResultState, Stage } from "./domain.ts";
import { ACTIONS, STAGES } from "./domain.ts";

const LEGAL: Record<Action, ResultState[]> = {
  start: ["active", "pending_human_decision", "error"], respond: ["active", "pending_human_decision", "ok", "cancelled", "error"],
  status: ["active", "pending_human_decision", "ok", "error"], complete: ["ok", "pending_human_decision", "error"],
  cancel: ["cancelled", "error"], release: ["ok", "error"],
};
export type PublicInput = { action: Action; stage?: Stage; reference?: string; decision_id?: string; answer?: string; review_mode?: "current" | "isolated" };
export function validateInput(v: unknown): { ok: true; value: PublicInput } | { ok: false; message: string } {
  if (!v || typeof v !== "object") return { ok: false, message: "Input must be an object." };
  const x = v as Record<string, unknown>;
  if (!ACTIONS.includes(x.action as Action)) return { ok: false, message: "Unknown action." };
  if (x.stage !== undefined && !STAGES.includes(x.stage as Stage)) return { ok: false, message: "Unknown stage." };
  if (x.action === "start" && x.stage === undefined) return { ok: false, message: "start requires stage." };
  if (x.action === "respond" && (typeof x.decision_id !== "string" || typeof x.answer !== "string")) return { ok: false, message: "respond requires decision_id and answer." };
  for (const key of ["reference", "decision_id", "answer"] as const) if (x[key] !== undefined && typeof x[key] !== "string") return { ok: false, message: `${key} must be a string.` };
  if (x.review_mode !== undefined && x.review_mode !== "current" && x.review_mode !== "isolated") return { ok: false, message: "Invalid review_mode." };
  return { ok: true, value: x as PublicInput };
}
export function validateResult(v: unknown): v is Result {
  if (!v || typeof v !== "object" || Array.isArray(v)) return false;
  const x = v as Record<string, any>; const action = x.action as Action; const state = x.state as ResultState;
  if (!ACTIONS.includes(action) || !LEGAL[action]?.includes(state) || typeof x.session_id !== "string" || !x.session_id) return false;
  if (x.stage !== undefined && !STAGES.includes(x.stage as Stage)) return false;
  if (x.task !== undefined && (!x.task || typeof x.task.id !== "string" || typeof x.task.directory !== "string" || !x.task.directory.startsWith("/"))) return false;
  if (x.artifacts !== undefined && (!Array.isArray(x.artifacts) || x.artifacts.some((a: any) => !a || !["requirements", "plan"].includes(a.kind) || typeof a.path !== "string" || !a.path.startsWith("/") || (a.content_hash !== undefined && (typeof a.content_hash !== "string" || !a.content_hash.startsWith("sha256:")))))) return false;
  const payloads = ["decision", "error", "outcome"].filter(k => x[k] !== undefined);
  if (payloads.length !== 1) return false;
  if (state === "pending_human_decision") { const d = x.decision; return payloads[0] === "decision" && !!d && typeof d.id === "string" && typeof d.kind === "string" && typeof d.prompt === "string" && (d.choices === undefined || (Array.isArray(d.choices) && d.choices.every((c: any) => c && typeof c.id === "string" && typeof c.label === "string" && (c.description === undefined || typeof c.description === "string")))); }
  if (state === "error") { const e = x.error; return payloads[0] === "error" && !!e && typeof e.code === "string" && typeof e.message === "string" && typeof e.retryable === "boolean"; }
  if (payloads[0] !== "outcome" || !x.outcome || typeof x.outcome.kind !== "string") return false;
  const o = x.outcome;
  if (o.kind === "stage_active") return typeof o.run_id === "string" && (o.summary === undefined || typeof o.summary === "string");
  if (o.kind === "idle") return true;
  if (o.kind === "decision_applied") return typeof o.decision_id === "string" && (o.summary === undefined || typeof o.summary === "string");
  if (o.kind === "stage_completed") return typeof o.summary === "string";
  if (o.kind === "stage_cancelled") return o.approved_writes_preserved === true && typeof o.summary === "string";
  if (o.kind === "ownership_released") return o.resumable === true && typeof o.summary === "string";
  return false;
}
export function errorResult(action: Action, session_id: string, code: string, message: string, retryable = false, stage?: Stage): Result {
  return { action, state: "error", session_id, ...(stage ? { stage } : {}), error: { code, message, retryable } };
}
export function json(result: Result): string { return JSON.stringify(result); }
