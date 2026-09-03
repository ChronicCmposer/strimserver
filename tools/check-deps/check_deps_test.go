package main

import (
	"testing"

	"strimserver-check-deps/common"
)

func TestDedupeKeepsFirstPerFileIdentity(t *testing.T) {
	deps := []common.Dependency{
		{Category: common.CategoryScriptPin, Name: "ffmpeg", Version: "8.0", File: "tools/ffmpeg-dist/build.sh"},
		{Category: common.CategoryScriptPin, Name: "ffmpeg", Version: "8.0", File: "tools/ffmpeg-dist/publish.sh"},
		{Category: common.CategoryScriptPin, Name: "qemu", Version: "9.2.4", File: "tools/qemu/build-qemu.sh"},
		// A byte-identical repeat within the same file must still collapse.
		{Category: common.CategoryScriptPin, Name: "qemu", Version: "9.2.4", File: "tools/qemu/build-qemu.sh"},
	}
	got := dedupe(deps)
	// Identity includes File, so the same ffmpeg pin declared in build.sh and
	// publish.sh is kept twice (per-file identity keeps them distinct); only
	// the byte-identical qemu repeat collapses.
	if len(got) != 3 {
		t.Fatalf("dedupe = %v, want 3 entries", got)
	}
	if got[0].File != "tools/ffmpeg-dist/build.sh" {
		t.Errorf("dedupe kept %q first, want the first occurrence (build.sh)", got[0].File)
	}
	if got[1].File != "tools/ffmpeg-dist/publish.sh" {
		t.Errorf("dedupe kept %q second, want publish.sh to stay distinct", got[1].File)
	}
}
