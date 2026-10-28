import test from "node:test";
import assert from "node:assert/strict";
import { validateInput, validateResult } from "../contracts.ts";
const base = { action: "status", session_id: "s" } as const;
test("accepts exact idle status contract", () => assert.equal(validateResult({ ...base, state: "ok", outcome: { kind: "idle" } }), true));
test("rejects illegal action/state", () => assert.equal(validateResult({ action: "cancel", state: "ok", session_id: "s", outcome: { kind: "idle" } }), false));
test("rejects missing and multiple payloads", () => { assert.equal(validateResult({ ...base, state: "ok" }), false); assert.equal(validateResult({ ...base, state: "ok", outcome: { kind: "idle" }, error: {} }), false); });
test("optional fields are omittable", () => { const x = { ...base, state: "ok", outcome: { kind: "idle" } }; assert.equal("stage" in x, false); assert.equal(validateResult(x), true); });
test("strict action requirements", () => { assert.equal(validateInput({ action: "start" }).ok, false); assert.equal(validateInput({ action: "respond", decision_id: "d" }).ok, false); assert.equal(validateInput({ action: "start", stage: "review-plan", reference: "x" }).ok, true); });
