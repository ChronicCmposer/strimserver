package extractorimpl

import (
	"strings"

	"strimserver-check-deps/common"
)

// pnpmSection* are the top-level lockfile sections this parser understands.
const (
	pnpmSectionImporters = "importers"
	pnpmSectionPackages  = "packages"
	pnpmSectionSnapshots = "snapshots"
)

// pnpmIndent* are the fixed leading-space counts pnpm 9 uses: importer names
// and package keys rest two spaces in, and the package names declared inside an
// importer's dependency maps rest six spaces in. The intermediate four-space
// lines are the dependency map headers (`dependencies:`, `devDependencies:`),
// which are not package names.
const (
	pnpmIndentKey      = 2
	pnpmIndentDeclared = 6
)

// ExtractPnpmLock emits every resolved npm package a pnpm lockfile records only
// transitively: a package that appears in the packages/snapshots sections but
// is not declared as an importer dependency in the same lockfile. Each
// discovered lockfile is parsed independently; a missing lockfile yields
// nothing.
func ExtractPnpmLock(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	return common.AggregateExtract(discoverBeneath(root, "pnpm-lock.yaml"), func(rel string) ([]common.Dependency, []common.ExtractionUnknown) {
		data, absent, unknowns := readOptional(root, rel)
		if absent {
			return nil, nil
		}
		if unknowns != nil {
			return nil, unknowns
		}
		return parsePnpmLock(data, rel)
	})
}

// ExtractPnpmLock must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractPnpmLock

// pnpmInstance is the (name, version) identity of one resolved package key.
type pnpmInstance struct {
	name    string
	version string
}

// parsePnpmLock returns one inventory dependency per unique package instance
// (name, version) in the lockfile's packages and snapshots sections whose name
// is absent from every importer's declared dependency maps. Peer suffixes like
// `(rollup@4.64.5)` are stripped before the name/version split, so a snapshot
// key and its packages key collapse into a single finding. Optional platform
// binaries (e.g. @rollup/rollup-<platform>) are ordinary package instances and
// flow through unchanged. A key that is not `<name>@<version>` is reported as
// an unknown, never a panic.
func parsePnpmLock(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	lines := strings.Split(string(data), "\n")
	declared := declaredPnpmImporterNames(lines)
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	seenKeys := make(map[string]struct{})
	seenInstances := make(map[string]struct{})
	for _, key := range packageKeys(lines) {
		if _, duplicate := seenKeys[key]; duplicate {
			continue
		}
		seenKeys[key] = struct{}{}
		instance, ok := parsePnpmInstance(key)
		if !ok {
			unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "unparsable package key: " + key})
			continue
		}
		if _, isDeclared := declared[instance.name]; isDeclared {
			continue
		}
		if _, duplicate := seenInstances[instance.identity()]; duplicate {
			continue
		}
		seenInstances[instance.identity()] = struct{}{}
		deps = append(deps, common.Dependency{
			Category: common.CategoryNPM,
			Name:     instance.name,
			Version:  instance.version,
			Source:   "pnpm-lock.yaml transitive package",
			File:     file,
			Note:     inventoryNote,
		})
	}
	return deps, unknowns
}

// identity renders the instance as the `name@version` dedupe key.
func (i pnpmInstance) identity() string {
	return i.name + "@" + i.version
}

// declaredPnpmImporterNames returns the package names declared under every
// importers entry's dependency maps.
func declaredPnpmImporterNames(lines []string) map[string]struct{} {
	declared := make(map[string]struct{})
	for _, key := range sectionKeys(lines, pnpmSectionImporters, pnpmIndentDeclared) {
		declared[key] = struct{}{}
	}
	return declared
}

// packageKeys returns the package instance keys declared by the packages and
// snapshots sections, in file order.
func packageKeys(lines []string) []string {
	return append(
		sectionKeys(lines, pnpmSectionPackages, pnpmIndentKey),
		sectionKeys(lines, pnpmSectionSnapshots, pnpmIndentKey)...,
	)
}

// sectionKeys returns the mapping keys at exactly indent spaces inside the
// named top-level section, in file order. Lines outside a recognized section,
// value lines, sequence items, and keys at other indents are ignored, so a
// malformed "YAML-ish" line never reaches the caller.
func sectionKeys(lines []string, name string, indent int) []string {
	var keys []string
	section := ""
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		if leadingSpaces(line) == 0 {
			section = strings.TrimSuffix(strings.TrimSpace(line), ":")
			continue
		}
		if section != name {
			continue
		}
		if key, ok := yamlKey(line, indent); ok {
			keys = append(keys, key)
		}
	}
	return keys
}

// yamlKey returns the mapping key of a line indented by exactly indent spaces
// when the line is a key (a non-empty name followed by ':'), stripping the
// trailing colon and surrounding quotes. Value lines and sequence items return
// ok=false.
func yamlKey(line string, indent int) (string, bool) {
	if leadingSpaces(line) != indent {
		return "", false
	}
	trimmed := strings.TrimSpace(line)
	if len(trimmed) < 2 || !strings.HasSuffix(trimmed, ":") {
		return "", false
	}
	return unquoteYAMLScalar(strings.TrimSuffix(trimmed, ":")), true
}

// parsePnpmInstance splits a lockfile package key into its name and version.
// The key may carry a peer-resolution suffix (`name@version(peer@ver)`), which
// is stripped first; the version then follows the last '@' that is not the
// leading scope marker of a scoped name.
func parsePnpmInstance(key string) (pnpmInstance, bool) {
	base := key
	if paren := strings.IndexByte(base, '('); paren >= 0 {
		base = base[:paren]
	}
	at := strings.LastIndexByte(base, '@')
	if at <= 0 || at == len(base)-1 {
		return pnpmInstance{}, false
	}
	return pnpmInstance{name: base[:at], version: base[at+1:]}, true
}

// unquoteYAMLScalar strips one layer of matching single or double quotes.
func unquoteYAMLScalar(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 {
		if (s[0] == '\'' && s[len(s)-1] == '\'') || (s[0] == '"' && s[len(s)-1] == '"') {
			return s[1 : len(s)-1]
		}
	}
	return s
}

// leadingSpaces counts the leading space characters of a line.
func leadingSpaces(line string) int {
	return len(line) - len(strings.TrimLeft(line, " "))
}
