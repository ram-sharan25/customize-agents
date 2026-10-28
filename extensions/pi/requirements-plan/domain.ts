export const STAGES = ["clarify-requirements", "review-requirements", "plan-implementation", "review-plan"] as const;
export const ACTIONS = ["start", "respond", "status", "complete", "cancel", "release"] as const;
export type Stage = typeof STAGES[number];
export type Action = typeof ACTIONS[number];
export type ResultState = "active" | "pending_human_decision" | "ok" | "cancelled" | "error";
export type Task = { id: string; directory: string };
export type Artifact = { kind: "requirements" | "plan"; path: string; content_hash?: string };
export type Decision = { id: string; kind: string; prompt: string; choices?: Array<{ id: string; label: string; description?: string }> };
export type WorkflowError = { code: string; message: string; retryable: boolean };
export type Outcome =
  | { kind: "stage_active"; run_id: string; summary?: string }
  | { kind: "idle" }
  | { kind: "decision_applied"; decision_id: string; summary?: string }
  | { kind: "stage_completed"; summary: string }
  | { kind: "stage_cancelled"; approved_writes_preserved: true; summary: string }
  | { kind: "ownership_released"; resumable: true; summary: string };
export type Result = {
  action: Action; state: ResultState; session_id: string; stage?: Stage; task?: Task; artifacts?: Artifact[];
} & ({ state: "pending_human_decision"; decision: Decision } | { state: "error"; error: WorkflowError } | { state: "active" | "ok" | "cancelled"; outcome: Outcome });
export type PendingDecision = Decision & {
  run_id: string; session_id: string; stage: Stage; task: Task; artifacts: Artifact[];
  ownership?: { owner_session_id: string; revision: number }; operation: string; data?: Record<string, unknown>; created_at: string;
};
export type HandoffFinding = { severity: "BLOCKER" | "HIGH" | "MEDIUM" | "LOW"; location: string; impact: string; requested_change: string; title?: string };
export type Handoff = { id: string; scope: string; verdict: string; findings: HandoffFinding[]; resolution_queue: string[]; constraints_preferences: string[]; source_stage: Stage; target: Artifact; created_at: string };
export type RunSnapshot = {
  schema_version: 1; active: boolean; resumable?: boolean; run_id: string; session_id: string; stage: Stage; task: Task; artifacts: Artifact[];
  instructions: string[]; allowed_reads: string[]; pending_decision_id?: string; review_mode?: "current" | "isolated"; origin_id?: string;
  tools_before?: string[]; handoff_id?: string; last_error?: WorkflowError; updated_at: string;
};
export const isWritableStage = (stage: Stage) => stage === "clarify-requirements" || stage === "plan-implementation";
