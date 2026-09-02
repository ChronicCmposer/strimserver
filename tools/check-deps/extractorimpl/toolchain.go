package extractorimpl

import (
	"encoding/json"
	"strings"

	"strimserver-check-deps/common"
)

// ExtractToolchains reads the pinned toolchain versions: Bazel from
// .bazelversion, Node from the root .nvmrc, and pnpm from the Stream Deck
// plugin's package.json packageManager field.
func ExtractToolchains(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	// Registration order is the output order: Bazel, Node, then pnpm.
	return common.RunSourceSpecs(root, []common.SourceSpec{
		{RelPath: ".bazelversion", Parse: parseBazelVersion},
		{RelPath: ".nvmrc", Parse: parseNvmrc},
		{RelPath: "tools/streamdeck-plugin/package.json", Parse: parsePackageJSON},
	})
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

func parsePackageJSON(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var manifest packageManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "invalid JSON: " + err.Error()}}
	}
	if manifest.PackageManager == "" {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "no packageManager field"}}
	}
	version, ok := strings.CutPrefix(manifest.PackageManager, "pnpm@")
	if !ok || version == "" {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "packageManager is not a pnpm@<version> pin: " + manifest.PackageManager}}
	}
	return []common.Dependency{{
		Category: common.CategoryToolchain,
		Name:     "pnpm",
		Version:  version,
		Source:   "tools/streamdeck-plugin/package.json `packageManager`",
		File:     file,
	}}, nil
}
