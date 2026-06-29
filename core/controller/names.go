package main

const (
   PathIngress0   PathName = "ingress0"
   PathNormalized PathName = "normalized"
)
const (
   StageMediaMTX       StageName = "mediamtx"
   StageNormalize      StageName = "normalize"
   StageScaleAndEgress StageName = "scale_and_egress"
)

const (
   ComponentScaleAndEgress ControlComponent = ControlComponent(StageScaleAndEgress)
)

const (
   ActionStart ControlAction = "start"
   ActionStop  ControlAction = "stop"
)

var (
   AllPathNames         = []PathName{PathIngress0, PathNormalized}
   AllStageNames        = []StageName{StageMediaMTX, StageNormalize, StageScaleAndEgress}
   AllPathStatuses      = []PathStatus{Unknown, Ready, NotReady}
   AllStageStates       = []StageState{Running, Stopped} // NoTarget excluded by intent
   AllControlComponents = []ControlComponent{ComponentScaleAndEgress}
   AllControlActions    = []ControlAction{ActionStart, ActionStop}
)

func toStrings[T ~string](in []T) []string {
   out := make([]string, len(in))
   for i, v := range in { out[i] = string(v) }
   return out
}
