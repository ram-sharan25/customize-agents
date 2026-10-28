import type { Stage } from "../domain.ts";
import { clarifyRequirementsPrompt } from "./clarify-requirements.ts";
import { reviewRequirementsPrompt } from "./review-requirements.ts";
import { planImplementationPrompt } from "./plan-implementation.ts";
import { reviewPlanPrompt } from "./review-plan.ts";
export const STAGE_PROMPTS: Record<Stage, string> = {
  "clarify-requirements": clarifyRequirementsPrompt,
  "review-requirements": reviewRequirementsPrompt,
  "plan-implementation": planImplementationPrompt,
  "review-plan": reviewPlanPrompt,
};
export function initialDecision(stage: Stage) { if (stage === "review-requirements" || stage === "review-plan") return { kind: "review-mode", prompt: "Where should the review run?", choices: [{ id: "current", label: "Current conversation" }, { id: "isolated", label: "Isolated branch" }] }; return { kind: "confirm-selection", prompt: "Use this exact planning task and artifact selection?", choices: [{ id: "approve", label: "Yes" }, { id: "reject", label: "No" }] }; }
