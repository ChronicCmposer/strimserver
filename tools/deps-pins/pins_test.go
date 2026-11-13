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
	"errors"
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
	// skipIfMissing makes this assertion conditional on the file's existence:
	// when file is absent the sub-test is skipped rather than failed. It models
	// local-only files (e.g. the gitignored .env) that a CI checkout or fresh
	// clone legitimately lacks; when the file is present it is asserted fully.
	skipIfMissing bool
}

// pins is the full upgrade contract. Keep each entry aligned with the
// task's 13 numbered assertions (items 5/6/11 assert two substrings each).
var pins = []pin{
	{
		name:    "rules_go",
		file:    "MODULE.bazel",
		needles: []string{`bazel_dep(name = "rules_go", version = "0.65.0")`},
	},
	{
		name:    "aspect_rules_js",
		file:    "MODULE.bazel",
		needles: []string{`bazel_dep(name = "aspect_rules_js", version = "3.6.0")`},
	},
	{
		name:    "rules_cc",
		file:    "MODULE.bazel",
		needles: []string{`bazel_dep(name = "rules_cc", version = "0.2.28")`},
	},
	{
		name:    "rules_nodejs",
		file:    "MODULE.bazel",
		needles: []string{`bazel_dep(name = "rules_nodejs", version = "6.7.7")`},
	},
	{
		name: "golangci-lint-artifacts",
		file: "MODULE.bazel",
		needles: []string{
			"golangci-lint-2.15.0-linux-amd64.tar.gz",
			"golangci-lint-2.15.0-linux-arm64.tar.gz",
		},
	},
	{
		name: "mediamtx-artifacts",
		file: "MODULE.bazel",
		needles: []string{
			"mediamtx_v1.21.3_linux_amd64.tar.gz",
			"mediamtx_v1.21.3_linux_arm64.tar.gz",
		},
	},
	{
		name:    "c-ares-artifacts",
		file:    "MODULE.bazel",
		needles: []string{"c-ares-1.34.9.tar.gz"},
	},
	{
		name:    "cares-pin-json-version-1.34.9",
		file:    "third_party/cares/pin.json",
		needles: []string{`"version": "1.34.9"`},
	},
	{
		name:    "debian-snapshot",
		file:    "MODULE.bazel",
		needles: []string{`uris = ["https://snapshot.debian.org/archive/debian/20261104T000000Z"]`},
	},
	{
		// D3: the @ffmpeg_dist artifact and the runtime debs converge on one
		// Debian snapshot, so both producer scripts default to 20261104.
		name:    "ffmpeg-dist-build",
		file:    "tools/ffmpeg-dist/build.sh",
		needles: []string{"DEBIAN_SNAPSHOT:=20261104T000000Z"},
	},
	{
		name:    "ffmpeg-dist-publish",
		file:    "tools/ffmpeg-dist/publish.sh",
		needles: []string{"DEBIAN_SNAPSHOT:-20261104T000000Z}"},
	},
	{
		name:    "aws-launch-ami",
		file:    "deploy/aws/launch",
		needles: []string{"ami-0198b63ccfac121e8"},
	},
	{
		// Option B driver floor. lib/nvidia.sh is authored by the driver-core
		// lane; skipIfMissing keeps a concurrent tree without it from
		// hard-failing rather than asserting a file that does not exist yet.
		name:          "nvidia-driver-floor-620.70.06",
		file:          "deploy/aws/lib/nvidia.sh",
		needles:       []string{`NVIDIA_DRIVER_FLOOR="620.70.06"`},
		skipIfMissing: true,
	},
	{
		name:          "nvidia-open-nevra-620.70.06",
		file:          "deploy/aws/lib/nvidia.sh",
		needles:       []string{`NVIDIA_OPEN_NEVRA="nvidia-open-3:620.70.06-1.el9"`},
		skipIfMissing: true,
	},
	{
		// The floor is documented in the deployment runbook's contract table.
		name:    "deploy-aws-readme-driver-floor",
		file:    "deploy/aws/README.md",
		needles: []string{"620.70.06"},
	},
	{
		// The runbook documents both accepted factory DKMS source layouts and
		// the derived `nvidia/620.70.06` identity, so an operator can tell a
		// legacy `nvidia-open-<floor>` tree from the new `nvidia-<floor>` one.
		// Wording only: this asserts the existing 620.70.06 pin, no new version.
		name: "deploy-aws-readme-dkms-source-layouts",
		file: "deploy/aws/README.md",
		needles: []string{
			"usr/src/nvidia-620.70.06/dkms.conf",
			"usr/src/nvidia-open-620.70.06/dkms.conf",
			"nvidia/620.70.06",
		},
	},
	{
		// The staged-version validator contract is documented as an exact-name,
		// noarch, policy-only exemption for nvidia-driver-selinux while
		// kmod-nvidia-open* stays version-asserted at the 620.70.06 floor.
		// This is wording, not a new version pin: there is no NVIDIA entry in
		// the expected-pins fixtures.
		name: "deploy-aws-readme-selinux-exemption",
		file: "deploy/aws/README.md",
		needles: []string{
			"nvidia-driver-selinux",
			"exact-name",
			"policy-only",
			"kmod-nvidia-open*",
			"620.70.06",
		},
	},
	{
		name: "openssh-10.6p2",
		file: "tools/openssh/build.sh",
		needles: []string{
			"V_10_6_P2",
			"10.6p2",
		},
	},
	{
		// The pinned distlib wheel URL only asserts the version-derived file
		// name; its sha256 is not yet known and must not be hardcoded here.
		name:    "qemu-distlib-0.4.4",
		file:    "tools/qemu/build-qemu.sh",
		needles: []string{"distlib-0.4.4-py2.py3-none-any.whl"},
	},
	{
		name:    "streamdeck-rollup",
		file:    "tools/streamdeck-plugin/package.json",
		needles: []string{`"rollup": "4.64.5"`},
	},
	{
		name:    "streamdeck-package-manager",
		file:    "tools/streamdeck-plugin/package.json",
		needles: []string{`"packageManager": "pnpm@12.18.0"`},
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
		name:    "bazelversion-9.3.2",
		file:    ".bazelversion",
		needles: []string{"9.3.2"},
	},
	{
		name:    "nvmrc-26.13.1",
		file:    "tools/streamdeck-plugin/.nvmrc",
		needles: []string{"26.13.1"},
	},
	{
		name:    "controller-gomod-go-1.27.4",
		file:    "core/controller/go.mod",
		needles: []string{"go 1.27.4"},
	},
	{
		name:    "check-deps-gomod-go-1.27.4",
		file:    "tools/check-deps/go.mod",
		needles: []string{"go 1.27.4"},
	},
	{
		name:          "env-project-go-version-tag-go1.27.4",
		file:          ".env",
		needles:       []string{`PROJECT_GO_VERSION_TAG="go1.27.4"`},
		skipIfMissing: true,
	},
	{
		name:    "deps-check-workflow-go-version-1.27.4",
		file:    ".github/workflows/deps-check.yml",
		needles: []string{"go-version: 1.27.4"},
	},
	{
		name:    "deps-strict-workflow-go-version-1.27.4",
		file:    ".github/workflows/deps-strict.yml",
		needles: []string{"go-version: 1.27.4"},
	},
	{
		name:    "controller-gomod-containerd-v2.3.6",
		file:    "core/controller/go.mod",
		needles: []string{"github.com/containerd/containerd/v2 v2.3.6"},
	},
	{
		name:    "controller-gomod-klauspost-compress-v1.20.4",
		file:    "core/controller/go.mod",
		needles: []string{"github.com/klauspost/compress v1.20.4"},
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
				// Local-only file (e.g. gitignored .env) absent from a fresh
				// checkout: skip rather than fail — the committed toolchain
				// pins are asserted by their own sub-tests.
				if p.skipIfMissing && errors.Is(err, os.ErrNotExist) {
					t.Skipf("%s: %s is absent; skipping optional assertion", p.name, p.file)
				}
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
