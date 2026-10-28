import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { withFileMutationQueue } from "@earendil-works/pi-coding-agent";
import type { RunSnapshot } from "./domain.ts";
import { hashFile, readOrg } from "./org.ts";
import { getOwnership, withOperationLock } from "./ownership.ts";
import { insideRoot } from "./paths.ts";
export async function applyApprovedMutation(run: RunSnapshot, target: string, expectedHash: string | undefined, content: string, allowStaleLockSteal = false): Promise<string> {
  target = path.resolve(target); if (!insideRoot(target) || path.dirname(target) !== run.task.directory) throw Object.assign(new Error("Mutation target is outside the active task."), { code: "PATH_NOT_ALLOWED" });
  const allowed = run.stage === "clarify-requirements" ? ["requirements.org", "plan.org"] : run.stage === "plan-implementation" ? ["plan.org"] : [];
  if (!allowed.includes(path.basename(target))) throw Object.assign(new Error("Stage cannot mutate this artifact."), { code: "CAPABILITY_BLOCKED" });
  const owner = await getOwnership(run.task.directory); if (!owner || owner.owner_session_id !== run.session_id) throw Object.assign(new Error("Writable ownership is not held by this session."), { code: "NOT_OWNER" });
  return withOperationLock(run.task.directory, run.session_id, allowStaleLockSteal, () => withFileMutationQueue(target, async () => {
    let exists = true; try { await fs.stat(target); } catch (e: any) { if (e?.code === "ENOENT") exists = false; else throw e; }
    if (exists) { const actual = await hashFile(target); if (!expectedHash || actual !== expectedHash) throw Object.assign(new Error("Artifact changed after approval; request fresh approval."), { code: "STALE_ARTIFACT" }); }
    else if (expectedHash) throw Object.assign(new Error("Approved artifact no longer exists."), { code: "STALE_ARTIFACT" });
    if (!/^#\+title:/im.test(content) || !/^#\+status:\s*(DRAFT|FINAL)\s*$/im.test(content)) throw Object.assign(new Error("Proposed content is not a valid workflow Org document."), { code: "INVALID_ORG" });
    await fs.mkdir(path.dirname(target), { recursive: true }); const tmp = path.join(path.dirname(target), `.${path.basename(target)}.${process.pid}.${crypto.randomUUID()}.tmp`); await fs.writeFile(tmp, content, "utf8"); await fs.rename(tmp, target); await readOrg(target); return hashFile(target);
  }));
}
