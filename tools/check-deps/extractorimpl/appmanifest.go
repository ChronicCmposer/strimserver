package extractorimpl

import (
	"encoding/json"
	"strings"

	"strimserver-check-deps/common"
)

// appManifestPath is the Stream Deck plugin manifest template: the source of
// the plugin's SDK/software/Node.js/OS version requirements.
const appManifestPath = "tools/streamdeck-plugin/com.chroniccmposer.strimserver.sdPlugin/manifest.json.tpl"

// manifestVersion is a version field that may be written as a JSON number
// (SDKVersion: 2) or a JSON string ("6.6"). Both normalize to their literal
// text so the manifest's version fields parse uniformly.
type manifestVersion string

// UnmarshalJSON parses a number or string version literal into its text form.
// null and the empty literal normalize to "".
func (v *manifestVersion) UnmarshalJSON(data []byte) error {
	text := strings.TrimSpace(string(data))
	if text == "" || text == "null" {
		*v = ""
		return nil
	}
	if len(text) >= 2 && text[0] == '"' && text[len(text)-1] == '"' {
		text = text[1 : len(text)-1]
	}
	*v = manifestVersion(text)
	return nil
}

// appManifest is the subset of the Stream Deck plugin manifest this extractor
// reads. The version fields are opaque (not semver): SDKVersion is an API
// major, the rest are minimum supported versions.
type appManifest struct {
	SDKVersion manifestVersion `json:"SDKVersion"`
	Software   struct {
		MinimumVersion string `json:"MinimumVersion"`
	} `json:"Software"`
	Nodejs struct {
		Version string `json:"Version"`
	} `json:"Nodejs"`
	OS []struct {
		Platform       string `json:"Platform"`
		MinimumVersion string `json:"MinimumVersion"`
	} `json:"OS"`
}

// ExtractAppManifest reads the Stream Deck plugin manifest template and reports
// its declared SDK, software, Node.js, and first-OS minimum versions as
// toolchain dependencies.
func ExtractAppManifest(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	return common.ReadAndParse(root, appManifestPath, parseAppManifest)
}

// ExtractAppManifest must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractAppManifest

// parseAppManifest extracts the manifest's four version requirements. These are
// opaque platform requirements, not resolvable semver pins, so each finding
// carries a Note describing its nature. A manifest that declares none of them
// is an unknown rather than a silent empty result.
func parseAppManifest(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var manifest appManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "invalid JSON: " + err.Error()}}
	}

	var deps []common.Dependency
	deps = appendManifestFinding(deps, file, "Stream Deck SDK", string(manifest.SDKVersion), "`SDKVersion`", "Stream Deck SDK API major version")
	deps = appendManifestFinding(deps, file, "Stream Deck software", manifest.Software.MinimumVersion, "`Software.MinimumVersion`", "minimum Stream Deck application version")
	deps = appendManifestFinding(deps, file, "Stream Deck Node.js", manifest.Nodejs.Version, "`Nodejs.Version`", "Stream Deck plugin Node.js major version")
	if len(manifest.OS) > 0 {
		deps = appendManifestFinding(deps, file, "Stream Deck macOS", manifest.OS[0].MinimumVersion, "`OS[0].MinimumVersion`", "minimum macOS version")
	}

	if len(deps) == 0 {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "no SDK/software/Node.js/OS version requirements found"}}
	}
	return deps, nil
}

// appendManifestFinding appends one toolchain finding when version is non-empty,
// tagging it with the manifest field it came from.
func appendManifestFinding(deps []common.Dependency, file, name, version, field, note string) []common.Dependency {
	if version == "" {
		return deps
	}
	return append(deps, common.Dependency{
		Category: common.CategoryToolchain,
		Name:     name,
		Version:  version,
		Source:   file + " " + field,
		File:     file,
		Note:     note,
	})
}
