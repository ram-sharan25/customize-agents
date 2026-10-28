import crypto from "node:crypto";
import type { Artifact, Handoff, HandoffFinding, Stage } from "../domain.ts";
import { atomicJson, handoffPath, readJson } from "./store.ts";
export function handoffFromReport(stage: Stage, artifacts: Artifact[], report: string): Handoff {
  const findings: HandoffFinding[] = []; const re = /\[(BLOCKER|HIGH|MEDIUM|LOW)\]\s+([^\n]+)\nProblem:\s*([^\n]+)\nWhy it matters:\s*([^\n]+)/g;
  for (const m of report.matchAll(re)) findings.push({ severity: m[1] as HandoffFinding["severity"], title: m[2].trim(), location: m[3].trim(), impact: m[4].trim(), requested_change: `Resolve: ${m[2].trim()}` });
  const targetKind = stage === "review-plan" ? "plan" : "requirements"; const target = artifacts.find(a => a.kind === targetKind)!;
  return { id: `handoff-${crypto.randomUUID()}`, scope: artifacts.map(a => a.path).join(" and "), verdict: findings.length ? "needs attention" : "no reportable findings", findings, resolution_queue: findings.map(f => f.title ?? f.requested_change), constraints_preferences: [], source_stage: stage, target, created_at: new Date().toISOString() };
}
export async function saveHandoff(h: Handoff): Promise<void> { await atomicJson(handoffPath(h.id), h); }
export async function loadHandoff(id: string): Promise<Handoff | undefined> { return readJson(handoffPath(id)); }
