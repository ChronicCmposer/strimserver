package extractorimpl

import (
	"encoding/json"
	"os"
	"path/filepath"

	"strimserver-check-deps/common"
)

// vendoredPin is the machine-readable schema of a vendored library pin:
// third_party/<lib>/pin.json. It is the boundary type for ExtractVendoredPins;
// parseVendoredPin turns it into the trusted common.Dependency the rest of the
// tool consumes. sha256 and owner_repo are pointers so a JSON null is
// distinguishable from an empty string.
type vendoredPin struct {
	Name      string  `json:"name"`
	Version   string  `json:"version"`
	Upstream  string  `json:"upstream"`
	SHA256    *string `json:"sha256"`
	OwnerRepo *string `json:"owner_repo"`
}

const (
	// vendoredThirdPartyDir is the repo-relative directory that holds every
	// vendored library.
	vendoredThirdPartyDir = "third_party"
	// vendoredPinFileName is the machine-readable pin file inside each library
	// directory.
	vendoredPinFileName = "pin.json"
)

// ExtractVendoredPins reads every machine-readable vendored-library pin under
// third_party/<lib>/pin.json and emits one tool-binary dependency per pin. A
// library directory without a pin.json, and a pin.json that cannot be parsed,
// both become ExtractionUnknown records: coverage gaps and malformed pins stay
// visible rather than silent.
func ExtractVendoredPins(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	entries, err := os.ReadDir(filepath.Join(root, vendoredThirdPartyDir))
	if err != nil {
		return nil, []common.ExtractionUnknown{{
			File:   vendoredThirdPartyDir,
			Reason: "cannot read vendored library directory: " + err.Error(),
		}}
	}

	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		pinFile := filepath.ToSlash(filepath.Join(vendoredThirdPartyDir, entry.Name(), vendoredPinFileName))
		pinDeps, pinUnknowns := common.ReadAndParse(root, pinFile, parseVendoredPin)
		deps, unknowns = common.MergeExtract(deps, unknowns, pinDeps, pinUnknowns)
	}
	return deps, unknowns
}

// ExtractVendoredPins must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractVendoredPins

// parseVendoredPin parses one pin.json into a tool-binary dependency. It fails
// closed: unparseable JSON or a missing required field yields an
// ExtractionUnknown with a descriptive reason rather than a half-populated
// dependency.
func parseVendoredPin(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var pin vendoredPin
	if err := json.Unmarshal(data, &pin); err != nil {
		return nil, unknownPin(file, "malformed pin.json: "+err.Error())
	}
	if reason := missingVendoredField(pin); reason != "" {
		return nil, unknownPin(file, reason)
	}
	return []common.Dependency{vendoredDependency(pin, file)}, nil
}

// missingVendoredField names the first required field the pin omits, or "" when
// every required field is present.
func missingVendoredField(pin vendoredPin) string {
	switch {
	case pin.Name == "":
		return "pin.json missing required field: name"
	case pin.Version == "":
		return "pin.json missing required field: version"
	case pin.Upstream == "":
		return "pin.json missing required field: upstream"
	default:
		return ""
	}
}

// vendoredDependency maps the parsed pin onto the shared dependency contract.
// Source prefers the human-facing owner/repo when present, falling back to the
// upstream URL; the Note records the sha256 (or its absence).
func vendoredDependency(pin vendoredPin, file string) common.Dependency {
	return common.Dependency{
		Category: common.CategoryToolBinary,
		Name:     pin.Name,
		Version:  pin.Version,
		Source:   vendoredSource(pin),
		File:     file,
		Note:     vendoredNote(pin),
	}
}

// vendoredSource returns owner_repo when the pin records one, otherwise the
// upstream URL.
func vendoredSource(pin vendoredPin) string {
	if pin.OwnerRepo != nil && *pin.OwnerRepo != "" {
		return *pin.OwnerRepo
	}
	return pin.Upstream
}

// vendoredNote describes the pin's integrity, naming the sha256 when present
// and explicitly noting when the pin records none.
func vendoredNote(pin vendoredPin) string {
	if pin.SHA256 == nil || *pin.SHA256 == "" {
		return "vendored; sha256 not recorded"
	}
	return "vendored; sha256 " + *pin.SHA256
}

// unknownPin wraps one descriptive reason into the single-element unknown slice
// every fail-closed branch returns.
func unknownPin(file, reason string) []common.ExtractionUnknown {
	return []common.ExtractionUnknown{{File: file, Reason: reason}}
}
