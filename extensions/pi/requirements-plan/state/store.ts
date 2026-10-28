import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { PLANS_ROOT, insideRoot } from "../paths.ts";
export const STORE_ROOT = path.join(PLANS_ROOT, ".pi", "workflow-state");
export const LOCK_STALE_MS = 30 * 60 * 1000;
export function taskKey(taskDir: string): string { const p = path.resolve(taskDir); if (!insideRoot(p) || p === PLANS_ROOT) throw new Error("Invalid task identity."); return crypto.createHash("sha256").update(p).digest("hex"); }
export async function ensureStore(): Promise<void> { const s = await fs.stat(PLANS_ROOT); if (!s.isDirectory()) throw new Error("Planning root unavailable."); await fs.mkdir(STORE_ROOT, { recursive: true, mode: 0o700 }); }
export async function atomicJson(file: string, value: unknown): Promise<void> { await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 }); const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${crypto.randomUUID()}.tmp`); await fs.writeFile(tmp, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 }); await fs.rename(tmp, file); }
export async function readJson<T>(file: string): Promise<T | undefined> { try { return JSON.parse(await fs.readFile(file, "utf8")) as T; } catch (e: any) { if (e?.code === "ENOENT") return undefined; throw e; } }
export async function exclusiveJson(file: string, value: unknown): Promise<boolean> { await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 }); try { const h = await fs.open(file, "wx", 0o600); try { await h.writeFile(JSON.stringify(value, null, 2) + "\n"); } finally { await h.close(); } return true; } catch (e: any) { if (e?.code === "EEXIST") return false; throw e; } }
export async function appendAudit(event: Record<string, unknown>): Promise<void> { await ensureStore(); await fs.appendFile(path.join(STORE_ROOT, "audit.jsonl"), JSON.stringify({ ...event, at: new Date().toISOString() }) + "\n", { mode: 0o600 }); }
export const ownershipPath = (taskDir: string) => path.join(STORE_ROOT, "ownership", `${taskKey(taskDir)}.json`);
export const operationLockPath = (taskDir: string) => path.join(STORE_ROOT, "locks", `${taskKey(taskDir)}.lock`);
export const decisionPath = (id: string) => path.join(STORE_ROOT, "decisions", `${id}.json`);
export const consumedDecisionPath = (id: string) => path.join(STORE_ROOT, "decisions", "consumed", `${id}.json`);
export const handoffPath = (id: string) => path.join(STORE_ROOT, "handoffs", `${id}.json`);
