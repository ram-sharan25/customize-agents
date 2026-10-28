import crypto from "node:crypto";
import fs from "node:fs/promises";
import type { PendingDecision } from "../domain.ts";
import { atomicJson, consumedDecisionPath, decisionPath, exclusiveJson, readJson } from "./store.ts";
export async function saveDecision(d: Omit<PendingDecision, "id" | "created_at">): Promise<PendingDecision> { const value: PendingDecision = { ...d, id: `decision-${crypto.randomUUID()}`, created_at: new Date().toISOString() }; await atomicJson(decisionPath(value.id), value); return value; }
export async function loadDecision(id: string): Promise<PendingDecision | undefined> { return readJson(decisionPath(id)); }
export async function consumeDecision(id: string): Promise<PendingDecision> { const d = await loadDecision(id); if (!d) throw Object.assign(new Error("Decision is missing or already consumed."), { code: "INVALID_DECISION" }); if (!(await exclusiveJson(consumedDecisionPath(id), { id, consumed_at: new Date().toISOString() }))) throw Object.assign(new Error("Decision was already consumed."), { code: "DECISION_REUSED" }); await fs.unlink(decisionPath(id)); return d; }
