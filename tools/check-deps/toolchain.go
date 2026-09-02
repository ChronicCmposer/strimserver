package main

import (
	"encoding/json"
	"strings"
)

// extractToolchains reads the pinned toolchain versions: Bazel from
// .bazelversion, Node from the root .nvmrc, and pnpm from the Stream Deck
// plugin's package.json packageManager field.
func extractToolchains(root string) ([]dependency, []unknown) {
	var deps []dependency
	var unknowns []unknown

	gotDeps, gotUnknowns := readAndParse(root, ".bazelversion", parseBazelVersion)
	deps = append(deps, gotDeps...)
	unknowns = append(unknowns, gotUnknowns...)

	gotDeps, gotUnknowns = readAndParse(root, ".nvmrc", parseNvmrc)
	deps = append(deps, gotDeps...)
	unknowns = append(unknowns, gotUnknowns...)

	gotDeps, gotUnknowns = readAndParse(root, "tools/streamdeck-plugin/package.json", parsePackageJSON)
	deps = append(deps, gotDeps...)
	unknowns = append(unknowns, gotUnknowns...)

	return deps, unknowns
}

func parseBazelVersion(data []byte, file string) ([]dependency, []unknown) {
	version := strings.TrimSpace(string(data))
	if version == "" {
		return nil, []unknown{{File: file, Reason: "file is empty"}}
	}
	return []dependency{{
		Category: "toolchain",
		Name:     "Bazel",
		Version:  version,
		Source:   ".bazelversion",
		File:     file,
	}}, nil
}

func parseNvmrc(data []byte, file string) ([]dependency, []unknown) {
	version := strings.TrimSpace(string(data))
	if version == "" {
		return nil, []unknown{{File: file, Reason: "file is empty"}}
	}
	return []dependency{{
		Category: "toolchain",
		Name:     "Node",
		Version:  version,
		Source:   ".nvmrc",
		File:     file,
	}}, nil
}

type packageManifest struct {
	PackageManager string `json:"packageManager"`
}

func parsePackageJSON(data []byte, file string) ([]dependency, []unknown) {
	var manifest packageManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, []unknown{{File: file, Reason: "invalid JSON: " + err.Error()}}
	}
	version, ok := strings.CutPrefix(manifest.PackageManager, "pnpm@")
	if manifest.PackageManager == "" {
		return nil, []unknown{{File: file, Reason: "no packageManager field"}}
	}
	if !ok || version == "" {
		return nil, []unknown{{File: file, Reason: "packageManager is not a pnpm@<version> pin: " + manifest.PackageManager}}
	}
	return []dependency{{
		Category: "toolchain",
		Name:     "pnpm",
		Version:  version,
		Source:   "tools/streamdeck-plugin/package.json `packageManager`",
		File:     file,
	}}, nil
}
