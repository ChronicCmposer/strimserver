package main

import (
	"testing"

	"strimserver-check-deps/common"
)

func TestDedupeKeepsFirst(t *testing.T) {
	deps := []common.Dependency{
		{Category: common.CategoryScriptPin, Name: "ffmpeg", Version: "8.0", File: "tools/ffmpeg-dist/build.sh"},
		{Category: common.CategoryScriptPin, Name: "ffmpeg", Version: "8.0", File: "tools/ffmpeg-dist/publish.sh"},
		{Category: common.CategoryScriptPin, Name: "qemu", Version: "9.2.4", File: "tools/qemu/build-qemu.sh"},
	}
	got := dedupe(deps)
	if len(got) != 2 {
		t.Fatalf("dedupe = %v, want 2 entries", got)
	}
	if got[0].File != "tools/ffmpeg-dist/build.sh" {
		t.Errorf("dedupe kept %q, want the first occurrence", got[0].File)
	}
}
