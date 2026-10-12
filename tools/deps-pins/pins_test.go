// Package pins is an offline oracle for the dependency-pin upgrade.
//
// It asserts that each target version/string from the 11-item upgrade, plus
// every Option-A target pin, appears in its owning file. It is deliberately
// written as the failing "RED" test: until the upgrade is applied every
// sub-test reports a mismatch. All mismatches are collected and reported in a
// single run so the operator sees the full delta, not just the first failure.
//
// It resolves the repository root the same way tools/check-deps does:
// BUILD_WORKSPACE_DIRECTORY when set, else walk up from the working directory
// until MODULE.bazel is found.
package pins

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// pin names one expected substring in one repository-relative file. A single
// file may be asserted more than once; every assertion is an independent
// sub-test.
type pin struct {
	// name is the human-readable sub-test name.
	name string
	// file is the repository-relative path to inspect.
	file string
	// needles are the exact substrings that must all appear in file.
	needles []string
	// presentIf, when non-empty, makes this assertion conditional: the pin is
	// checked only if file already contains this substring. It models optional
	// modules (e.g. the otel /metric and /trace sub-modules) that are pinned
	// only when the project already depends on them.
	presentIf string
}

// pins is the full upgrade contract. Keep each entry aligned with the
// task's 13 numbered assertions (items 5/6/11 assert two substrings each).
var pins = []pin{
	{
		name:    "rules_go",
		file:    "MODULE.bazel",
		needles: []string{`bazel_dep(name = "rules_go", version = "0.64.2")`},
	},
	{
		name:    "aspect_rules_js",
		file:    "MODULE.bazel",
		needles: []string{`bazel_dep(name = "aspect_rules_js", version = "3.5.1")`},
	},
	{
		name:    "rules_cc",
		file:    "MODULE.bazel",
		needles: []string{`bazel_dep(name = "rules_cc", version = "0.2.26")`},
	},
	{
		name:    "rules_nodejs",
		file:    "MODULE.bazel",
		needles: []string{`bazel_dep(name = "rules_nodejs", version = "6.7.6")`},
	},
	{
		name: "golangci-lint-artifacts",
		file: "MODULE.bazel",
		needles: []string{
			"golangci-lint-2.14.0-linux-amd64.tar.gz",
			"golangci-lint-2.14.0-linux-arm64.tar.gz",
		},
	},
	{
		name: "mediamtx-artifacts",
		file: "MODULE.bazel",
		needles: []string{
			"mediamtx_v1.21.2_linux_amd64.tar.gz",
			"mediamtx_v1.21.2_linux_arm64.tar.gz",
		},
	},
	{
		name:    "debian-snapshot",
		file:    "MODULE.bazel",
		needles: []string{`uris = ["https://snapshot.debian.org/archive/debian/20261005T000000Z"]`},
	},
	{
		name:    "ffmpeg-dist-build",
		file:    "tools/ffmpeg-dist/build.sh",
		needles: []string{"DEBIAN_SNAPSHOT:=20261005T000000Z"},
	},
	{
		name:    "ffmpeg-dist-publish",
		file:    "tools/ffmpeg-dist/publish.sh",
		needles: []string{"DEBIAN_SNAPSHOT:-20261005T000000Z}"},
	},
	{
		name:    "aws-launch-ami",
		file:    "deploy/aws/launch",
		needles: []string{"ami-0b1794752c0d4fa6c"},
	},
	{
		name: "openssh-10.6p1",
		file: "tools/openssh/build.sh",
		needles: []string{
			"V_10_6_P1",
			"10.6p1",
		},
	},
	{
		name:    "streamdeck-rollup",
		file:    "tools/streamdeck-plugin/package.json",
		needles: []string{`"rollup": "4.64.5"`},
	},
	{
		name:    "go-winio",
		file:    "core/controller/go.mod",
		needles: []string{"github.com/Microsoft/go-winio v0.6.3"},
	},

	// --- Option-A target pins -------------------------------------------
	// Each sub-test names the owning file plus the expected string so a
	// failure identifies both the file and the exact value still missing.

	{
		name:    "bazelversion-9.3.0",
		file:    ".bazelversion",
		needles: []string{"9.3.0"},
	},
	{
		name:    "nvmrc-24.21.0",
		file:    "tools/streamdeck-plugin/.nvmrc",
		needles: []string{"24.21.0"},
	},
	{
		name:    "controller-gomod-go-1.27.2",
		file:    "core/controller/go.mod",
		needles: []string{"go 1.27.2"},
	},
	{
		name:    "check-deps-gomod-go-1.27.2",
		file:    "tools/check-deps/go.mod",
		needles: []string{"go 1.27.2"},
	},
	{
		name:    "env-project-go-version-tag-go1.27.2",
		file:    ".env",
		needles: []string{`PROJECT_GO_VERSION_TAG="go1.27.2"`},
	},
	{
		name:    "deps-check-workflow-go-version-1.27.2",
		file:    ".github/workflows/deps-check.yml",
		needles: []string{"go-version: 1.27.2"},
	},
	{
		name:    "deps-strict-workflow-go-version-1.27.2",
		file:    ".github/workflows/deps-strict.yml",
		needles: []string{"go-version: 1.27.2"},
	},
	{
		name:    "controller-gomod-containerd-v2.3.6",
		file:    "core/controller/go.mod",
		needles: []string{"github.com/containerd/containerd/v2 v2.3.6"},
	},
	{
		name:    "controller-gomod-klauspost-compress-v1.20.1",
		file:    "core/controller/go.mod",
		needles: []string{"github.com/klauspost/compress v1.20.1"},
	},
	{
		name:    "controller-gomod-otel-v1.47.0",
		file:    "core/controller/go.mod",
		needles: []string{"go.opentelemetry.io/otel v1.47.0"},
	},
	{
		name:      "controller-gomod-otel-metric-v1.47.0",
		file:      "core/controller/go.mod",
		needles:   []string{"go.opentelemetry.io/otel/metric v1.47.0"},
		presentIf: "go.opentelemetry.io/otel/metric",
	},
	{
		name:      "controller-gomod-otel-trace-v1.47.0",
		file:      "core/controller/go.mod",
		needles:   []string{"go.opentelemetry.io/otel/trace v1.47.0"},
		presentIf: "go.opentelemetry.io/otel/trace",
	},
	{
		name:    "fish-deploy-4.9.3",
		file:    "deploy/aws/fish-deploy.sh",
		needles: []string{"fish-4.9.3-linux-x86_64.tar.xz"},
	},
}

// TestPins asserts every pin in a single run. The root is resolved once;
// resolution failure is fatal because no assertion can be evaluated without
// it.
func TestPins(t *testing.T) {
	root, err := repoRoot()
	if err != nil {
		t.Fatalf("resolve repository root: %v", err)
	}

	// Read each distinct file once; assertions on the same file share content.
	cache := map[string]string{}
	read := func(rel string) (string, error) {
		if content, ok := cache[rel]; ok {
			return content, nil
		}
		content, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			return "", err
		}
		cache[rel] = string(content)
		return cache[rel], nil
	}

	for _, p := range pins {
		t.Run(p.name, func(t *testing.T) {
			content, err := read(p.file)
			if err != nil {
				t.Errorf("%s: cannot read %s: %v", p.name, p.file, err)
				return
			}
			// Optional module: nothing to assert when the project does not
			// already depend on it.
			if p.presentIf != "" && !strings.Contains(content, p.presentIf) {
				return
			}
			for _, needle := range p.needles {
				if !strings.Contains(content, needle) {
					t.Errorf("%s: %s does not contain %q", p.name, p.file, needle)
				}
			}
		})
	}
}

// repoRoot resolves the repository root. It mirrors
// tools/check-deps/main.go:199-220: honor BUILD_WORKSPACE_DIRECTORY when set
// (an explicit workspace without MODULE.bazel is an operational error),
// otherwise walk up from the working directory until a MODULE.bazel file is
// found. An unresolvable root is an error, never a silent empty result.
func repoRoot() (string, error) {
	if workspace := os.Getenv("BUILD_WORKSPACE_DIRECTORY"); workspace != "" {
		if !isFile(filepath.Join(workspace, "MODULE.bazel")) {
			return "", fmt.Errorf("BUILD_WORKSPACE_DIRECTORY %s contains no MODULE.bazel", workspace)
		}
		return workspace, nil
	}
	dir, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("cannot determine working directory: %w", err)
	}
	for {
		if isFile(filepath.Join(dir, "MODULE.bazel")) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no MODULE.bazel found in %s or any parent directory", dir)
		}
		dir = parent
	}
}

// isFile reports whether path exists and is a regular (non-directory) file.
func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}
