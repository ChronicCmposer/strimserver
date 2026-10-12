package extractorimpl

import (
	"encoding/json"
	"maps"
	"path/filepath"
	"slices"
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

// packageManifest is the subset of a package.json this extractor reads: the
// packageManager toolchain pin plus the declared npm dependency ranges and the
// Node engine requirement.
type packageManifest struct {
	PackageManager  string            `json:"packageManager"`
	Dependencies    map[string]string `json:"dependencies"`
	DevDependencies map[string]string `json:"devDependencies"`
	Engines         struct {
		Node string `json:"node"`
	} `json:"engines"`
}

// parsePackageJSON extracts the npm dependency ranges and the pnpm toolchain
// pin from a package.json that is expected to carry a packageManager field; a
// manifest without the field is an unknown. It is the strict parser for a
// known-managed manifest.
func parsePackageJSON(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var manifest packageManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "invalid JSON: " + err.Error()}}
	}
	if manifest.PackageManager == "" {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "no packageManager field"}}
	}
	return manifestFindings(manifest, file)
}

// parseManagedPackageJSON extracts the npm dependency ranges and the pnpm
// toolchain pin from a discovered package.json, silently skipping the pnpm
// finding for a manifest without a packageManager field: a node sub-repo
// discovered via its package.json may legitimately use a different package
// manager, and that is not an extraction failure. The declared npm dependencies
// are still reported, since they are a real dependency tree regardless of the
// package manager. A genuinely malformed manifest still surfaces as an unknown.
func parseManagedPackageJSON(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var manifest packageManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "invalid JSON: " + err.Error()}}
	}
	if manifest.PackageManager == "" {
		return npmDependencyFindings(manifest, file), nil
	}
	return manifestFindings(manifest, file)
}

// manifestFindings combines the npm dependency findings with the pnpm toolchain
// finding for a manifest known to carry a packageManager pin.
func manifestFindings(manifest packageManifest, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	pnpmDeps, unknowns := pnpmToolchainFinding(manifest.PackageManager, file)
	return append(npmDependencyFindings(manifest, file), pnpmDeps...), unknowns
}

// npmDependencyFindings returns one npm-category finding per declared package
// range in the manifest's dependencies and devDependencies, plus engines.node,
// each tagged with the manifest file. The version is the declared range exactly
// as written; resolution is a later phase. Findings are ordered deterministically
// (dependencies before devDependencies, names sorted) so output is stable.
func npmDependencyFindings(manifest packageManifest, file string) []common.Dependency {
	var deps []common.Dependency
	for _, group := range []map[string]string{manifest.Dependencies, manifest.DevDependencies} {
		for _, name := range slices.Sorted(maps.Keys(group)) {
			deps = append(deps, common.Dependency{
				Category: common.CategoryNPM,
				Name:     name,
				Version:  group[name],
				File:     file,
			})
		}
	}
	if manifest.Engines.Node != "" {
		deps = append(deps, common.Dependency{
			Category: common.CategoryNPM,
			Name:     "node",
			Version:  manifest.Engines.Node,
			File:     file,
			Note:     "engines.node requirement",
		})
	}
	return deps
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
