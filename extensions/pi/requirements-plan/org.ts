import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
export type OrgDocument = { content: string; title: string; status: "DRAFT" | "FINAL" };
export async function hashFile(file: string): Promise<string> { return `sha256:${crypto.createHash("sha256").update(await fs.readFile(file)).digest("hex")}`; }
export async function readOrg(file: string): Promise<OrgDocument> {
  const content = await fs.readFile(file, "utf8"); const title = content.match(/^#\+title:\s*(.+)$/im)?.[1]?.trim(); const status = content.match(/^#\+status:\s*(DRAFT|FINAL)\s*$/im)?.[1]?.toUpperCase();
  if (!title || (status !== "DRAFT" && status !== "FINAL")) throw Object.assign(new Error(`Invalid Org directives in ${file}: #+title and #+status DRAFT|FINAL are required.`), { code: "INVALID_ORG" });
  return { content, title, status };
}
export function replaceStatus(content: string, expected: "DRAFT" | "FINAL", next: "DRAFT" | "FINAL"): string { const re = new RegExp(`^#\\+status:[ \\t]*${expected}[ \\t]*$`, "im"); if (!re.test(content)) throw new Error(`Expected Org status ${expected}.`); return content.replace(re, `#+status: ${next}`); }
export function literalReferences(content: string, baseDir: string): string[] {
  const refs = new Set<string>(); const patterns = [/(?:^|[\s=(])((?:\/|\.\.?\/)[^\s\]\[()=,]+)(?=$|[\s)\],])/gm, /\[\[file:([^\]]+)\]/gim];
  for (const re of patterns) for (const m of content.matchAll(re)) { const raw = (m[1] ?? "").replace(/[.,;:]$/, ""); if (raw) refs.add(path.isAbsolute(raw) ? path.resolve(raw) : path.resolve(baseDir, raw)); }
  return [...refs];
}
