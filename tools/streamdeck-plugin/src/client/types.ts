// Mirrors ControllerStatus / StageStatus from core/controller/controller.go.
// Keep these literals aligned with the Go const blocks in that file.

export type PathStatus = "unknown" | "ready" | "not-ready";

// NoTarget ("") shouldn't appear over the wire in practice — all stages are
// seeded with a valid Desired/Actual — but include it for completeness.
export type StageState = "running" | "stopped" | "";

export interface StageStatus {
   desired: StageState;
   actual: StageState;
}

export interface ControllerStatus {
   paths: Record<PathName, PathStatus>;
   stages: Record<StageName, StageStatus>;
}

// Names defined in core/controller/main.go (run-time identifiers).
export type PathName  = "ingress0" | "normalized";
export type StageName = "mediamtx" | "normalize" | "scale_and_egress";

export const Paths = {
   Ingress0:   "ingress0"   as const,
   Normalized: "normalized" as const,
};

export const Stages = {
   MediaMTX:       "mediamtx"          as const,
   Normalize:      "normalize"         as const,
   ScaleAndEgress: "scale_and_egress"  as const,
};

// Derived UI state, computed from a StageStatus.
export type StageUIState = "off" | "on" | "starting" | "stopping" | "unknown";

export function stageUIState(s: StageStatus | undefined): StageUIState {
   if (!s) return "unknown";
   if (s.desired === "running" && s.actual === "running") return "on";
   if (s.desired === "stopped" && s.actual === "stopped") return "off";
   if (s.desired === "running" && s.actual === "stopped") return "starting";
   if (s.desired === "stopped" && s.actual === "running") return "stopping";
   return "unknown";
}
