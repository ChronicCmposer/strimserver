package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestUpdateGoldens regenerates the byte-compared e2e goldens when
// UPDATE_GOLDEN=1 is set in the environment. It is skipped by default, so the
// normal suite always byte-compares against the committed fixtures; the
// regression tests (TestE2ERegressionJSON, TestE2ERegressionConsole,
// TestE2EAllRestoresFullFindings) are the real contract.
func TestUpdateGoldens(t *testing.T) {
	if os.Getenv("UPDATE_GOLDEN") != "1" {
		t.Skip("set UPDATE_GOLDEN=1 to regenerate the e2e goldens")
	}

	cases := []struct {
		name string
		mode e2eMode
		all  bool
		path string
	}{
		{"json", e2eJSON, false, "golden-nonet.json"},
		{"all", e2eJSON, true, "golden-nonet-all.json"},
		{"console", e2eConsole, false, "golden-nonet-console.txt"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := newE2EApp(t, tc.mode, "", nil)
			e.opts.All = tc.all
			if err := run(e.opts, e.cache, e.resolvers, nil, e.extractors, e.classifier); err != nil {
				t.Fatalf("run: %v", err)
			}
			path := filepath.Join("testdata", tc.path)
			if err := os.WriteFile(path, e.stdout.Bytes(), 0o644); err != nil {
				t.Fatalf("write %s: %v", path, err)
			}
		})
	}
}
