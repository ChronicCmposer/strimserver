package main

const (
   PathIngress0   PathName = "ingress0"
   PathNormalized PathName = "normalized"
)
const (
   StageMediaMTX           StageName = "mediamtx"
   StageNormalize          StageName = "normalize"
   StageScaleAndEgress     StageName = "scale_and_egress"
   StageSingleStageEgress  StageName = "single_stage_egress"
)

const (
   ComponentEgress ControlComponent = "egress"
)

const (
   ActionStart ControlAction = "start"
   ActionStop  ControlAction = "stop"
)

var (
   AllPathNames         = []PathName{PathIngress0, PathNormalized}
   AllStageNames        = []StageName{StageMediaMTX, StageNormalize, StageScaleAndEgress, StageSingleStageEgress}
   AllPathStatuses      = []PathStatus{Unknown, Ready, NotReady}
   AllStageStates       = []StageState{Running, Stopped} // NoTarget excluded by intent
   AllControlComponents = []ControlComponent{ComponentEgress}
   AllControlActions    = []ControlAction{ActionStart, ActionStop}
)

func toStrings[T ~string](in []T) []string {
   out := make([]string, len(in))
   for i, v := range in { out[i] = string(v) }
   return out
}
