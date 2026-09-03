package extractorimpl

import (
	"encoding/json"
	"path/filepath"
	"strings"

	"strimserver-check-deps/common"
)

// ExtractToolchains reads the pinned toolchain versions: Bazel from the root
// .bazelversion and, per discovered node sub-repo, Node from its .nvmrc and
// pnpm from its package.json packageManager field. Discovery replaces the old
// hardcoded root .nvmrc read, so a repo that pins Node only inside a sub-repo
// (e.g. tools/streamdeck-plugin/.nvmrc) yields its Node finding instead of a
// missing-file unknown.
func ExtractToolchains(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	specs := []common.SourceSpec{
		{RelPath: ".bazelversion", Parse: parseBazelVersion},
	}
	for _, subRepo := range common.DiscoverNodeSubRepos(root) {
		specs = append(specs, nodeSubRepoSpecs(root, subRepo)...)
	}
	return common.RunSourceSpecs(root, specs)
}

// ExtractToolchains must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractToolchains

// nodeSubRepoSpecs returns the extraction SourceSpecs for one discovered node
// sub-repo: its .nvmrc pin when present and its package.json packageManager pin
// when present. An unmanaged package.json (no packageManager field) contributes
// no pnpm finding — parseManagedPackageJSON skips it — so it never surfaces as
// a spurious unknown.
func nodeSubRepoSpecs(root, subRepo string) []common.SourceSpec {
	var specs []common.SourceSpec
	if common.NodeConfigFile(root, subRepo, ".nvmrc") {
		specs = append(specs, common.SourceSpec{
			RelPath: filepath.Join(subRepo, ".nvmrc"),
			Parse:   parseNvmrc,
		})
	}
	if common.NodeConfigFile(root, subRepo, "package.json") {
		specs = append(specs, common.SourceSpec{
			RelPath: filepath.Join(subRepo, "package.json"),
			Parse:   parseManagedPackageJSON,
		})
	}
	return specs
}

func parseBazelVersion(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	version := strings.TrimSpace(string(data))
	if version == "" {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "file is empty"}}
	}
	return []common.Dependency{{
		Category: common.CategoryToolchain,
		Name:     "Bazel",
		Version:  version,
		Source:   ".bazelversion",
		File:     file,
	}}, nil
}

func parseNvmrc(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	version := strings.TrimSpace(string(data))
	if version == "" {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "file is empty"}}
	}
	return []common.Dependency{{
		Category: common.CategoryToolchain,
		Name:     "Node",
		Version:  version,
		Source:   ".nvmrc",
		File:     file,
	}}, nil
}

type packageManifest struct {
	PackageManager string `json:"packageManager"`
}

// parsePackageJSON extracts the pnpm toolchain pin from a package.json that is
// expected to carry a packageManager field; a manifest without the field is an
// unknown. It is the strict parser for a known-managed manifest.
func parsePackageJSON(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var manifest packageManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "invalid JSON: " + err.Error()}}
	}
	if manifest.PackageManager == "" {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "no packageManager field"}}
	}
	return pnpmToolchainFinding(manifest.PackageManager, file)
}

// parseManagedPackageJSON extracts the pnpm toolchain pin from a discovered
// package.json, silently skipping a manifest without a packageManager field: a
// node sub-repo discovered via its package.json may legitimately use a
// different package manager, and that is not an extraction failure. A genuinely
// malformed manifest still surfaces as an unknown.
func parseManagedPackageJSON(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var manifest packageManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "invalid JSON: " + err.Error()}}
	}
	if manifest.PackageManager == "" {
		return nil, nil
	}
	return pnpmToolchainFinding(manifest.PackageManager, file)
}

// pnpmToolchainFinding builds the pnpm toolchain finding from a non-empty
// packageManager value, reporting a pin that is not pnpm@<version> as an
// unknown.
func pnpmToolchainFinding(packageManager, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	version, ok := strings.CutPrefix(packageManager, "pnpm@")
	if !ok || version == "" {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "packageManager is not a pnpm@<version> pin: " + packageManager}}
	}
	return []common.Dependency{{
		Category: common.CategoryToolchain,
		Name:     "pnpm",
		Version:  version,
		Source:   "package.json `packageManager`",
		File:     file,
	}}, nil
}
