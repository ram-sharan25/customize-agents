import path from "node:path";
import fs from "node:fs/promises";
import type { Artifact, Stage, Task } from "./domain.ts";
import { hashFile, readOrg } from "./org.ts";
export const PLANS_ROOT = "/Users/rrimal/Stillness/Agent_Stuffs/Plans";
const RESERVED = new Set(["templates", ".pi"]);
export function stripAt(v: string): string {
  return v
    .trim()
    .replace(/^(?:plan|requirements|path|task|directory)\s*:\s*/i, "")
    .replace(/^@/, "")
    .trim();
}
export function insideRoot(p: string): boolean { const r = path.resolve(p); return r === PLANS_ROOT || r.startsWith(PLANS_ROOT + path.sep); }
export async function assertRoot(): Promise<void> { const s = await fs.stat(PLANS_ROOT); if (!s.isDirectory()) throw new Error(`Planning root is unavailable: ${PLANS_ROOT}`); }
export async function applicableAgents(taskDir: string): Promise<string[]> {
  const out: string[] = []; let p = path.resolve(taskDir);
  while (insideRoot(p)) { const f = path.join(p, "AGENTS.md"); try { if ((await fs.stat(f)).isFile()) { await fs.readFile(f, "utf8"); out.unshift(f); } } catch (e: any) { if (e?.code !== "ENOENT") throw e; } if (p === PLANS_ROOT) break; p = path.dirname(p); }
  return out;
}
async function walk(dir: string, depth = 0): Promise<string[]> {
  if (depth > 3) return []; const out: string[] = [];
  for (const e of await fs.readdir(dir, { withFileTypes: true })) if (e.isDirectory() && !RESERVED.has(e.name)) { const d = path.join(dir, e.name); try { if ((await fs.stat(path.join(d, "requirements.org"))).isFile()) out.push(d); } catch {} out.push(...await walk(d, depth + 1)); }
  return out;
}
export async function findCandidates(reference: string, cwd: string): Promise<string[]> {
  await assertRoot(); const raw = stripAt(reference);
  const direct = path.isAbsolute(raw) ? path.resolve(raw) : path.resolve(cwd, raw);
  const candidates = new Set<string>();
  if (insideRoot(direct)) { let d = direct; if (path.basename(d) === "requirements.org" || path.basename(d) === "plan.org") d = path.dirname(d); try { if ((await fs.stat(d)).isDirectory()) candidates.add(d); } catch {} }
  const rootRelative = path.resolve(PLANS_ROOT, raw); if (insideRoot(rootRelative)) try { if ((await fs.stat(rootRelative)).isDirectory()) candidates.add(rootRelative); } catch {}
  if (!candidates.size) { const needle = raw.toLowerCase(); for (const d of await walk(PLANS_ROOT)) { const rel = path.relative(PLANS_ROOT, d).toLowerCase(); if (rel.includes(needle) || path.basename(d).toLowerCase().includes(needle)) candidates.add(d); } }
  return [...candidates].filter(insideRoot).sort();
}
export function taskFromDir(dir: string): Task { const d = path.resolve(dir); if (!insideRoot(d) || d === PLANS_ROOT) throw new Error("Task directory must be beneath the planning root."); return { id: path.relative(PLANS_ROOT, d), directory: d }; }
export async function artifactsFor(stage: Stage, task: Task): Promise<Artifact[]> {
  const kinds: Artifact["kind"][] = stage === "clarify-requirements" || stage === "review-requirements" ? ["requirements"] : ["requirements", "plan"];
  const out: Artifact[] = [];
  for (const kind of kinds) { const p = path.join(task.directory, `${kind}.org`); try { await readOrg(p); out.push({ kind, path: p, content_hash: await hashFile(p) }); } catch (e: any) { if (e?.code === "ENOENT") out.push({ kind, path: p }); else throw e; } }
  return out;
}
