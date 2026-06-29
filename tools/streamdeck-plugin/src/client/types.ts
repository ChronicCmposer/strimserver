import type { StageStatus } from "./types.generated";
export * from "./types.generated";

export type StageUIState = "off" | "on" | "starting" | "stopping" | "unknown";

export function stageUIState(s: StageStatus | undefined): StageUIState {
   if (!s) return "unknown";
   if (s.desired === "running" && s.actual === "running") return "on";
   if (s.desired === "stopped" && s.actual === "stopped") return "off";
   if (s.desired === "running" && s.actual === "stopped") return "starting";
   if (s.desired === "stopped" && s.actual === "running") return "stopping";
   return "unknown";
}
