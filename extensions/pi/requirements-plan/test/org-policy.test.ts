import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { literalReferences, replaceStatus } from "../org.ts";
import { authorizeRead, assistantHasMixedStart, toolAllowed } from "../policy.ts";
import { stripAt } from "../paths.ts";
const run: any = { active: true, stage: "review-requirements", allowed_reads: ["/allowed"] };
test("normalizes labeled and @-prefixed artifact references", () => {
  assert.equal(stripAt("Plan: /tmp/plan.org"), "/tmp/plan.org");
  assert.equal(stripAt("Requirements: @/tmp/requirements.org"), "/tmp/requirements.org");
});
test("Org status update preserves all other content", () => { const before = "#+title: T\n#+status: DRAFT\n\n* X\nBody\n"; assert.equal(replaceStatus(before, "DRAFT", "FINAL"), "#+title: T\n#+status: FINAL\n\n* X\nBody\n"); });
test("extracts literal paths only", () => { const refs = literalReferences("See /tmp/a.org and [[file:./b.org][b]].", "/root"); assert.deepEqual(refs.sort(), ["/root/b.org", "/tmp/a.org"]); });
test("policy denies unknown tools and reads", () => { assert.equal(toolAllowed(run, "read"), false); assert.equal(toolAllowed(run, "requirements_plan_read"), true); assert.throws(() => authorizeRead(run, "/denied", "/")); assert.equal(authorizeRead(run, "/allowed", "/"), "/allowed"); });
test("detects mixed start assistant batch", () => { const ctx: any = { sessionManager: { getBranch: () => [{ type: "message", message: { role: "assistant", content: [{ type: "toolCall", name: "requirements_plan", arguments: { action: "start" } }, { type: "toolCall", name: "read", arguments: {} }] } }] } }; assert.equal(assistantHasMixedStart(ctx), true); });
