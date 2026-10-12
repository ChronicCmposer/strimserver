package extractorimpl

import (
	"os"
	"path/filepath"
	"strings"

	"strimserver-check-deps/common"
)

// inventoryNote marks a dependency that a lockfile records only transitively,
// not as a top-level pin. A later report pass routes these into the inventory
// section instead of treating them as reviewable dependencies.
const inventoryNote = "inventory:transitive"

// goModPair is one (module, version) pair pinned by a go.mod require directive.
// go.sum transitivity is judged at this granularity: a module's older versions
// may remain in go.sum as transitive go.mod hashes even when the module itself
// is required at a newer version.
type goModPair struct {
	module  string
	version string
}

// ExtractGoSum emits every Go module that appears in a go.sum lockfile only
// transitively: its exact (module, version) pair is absent from every require
// directive of the sibling go.mod. Each discovered go.sum is judged against the
// go.mod in the same directory, so the transitive set always belongs to the
// module that owns it.
func ExtractGoSum(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	return common.AggregateExtract(DiscoverGoSumFiles(root), func(relSum string) ([]common.Dependency, []common.ExtractionUnknown) {
		return extractGoSumFile(root, relSum)
	})
}

// ExtractGoSum must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractGoSum

// extractGoSumFile reads one go.sum and its sibling go.mod and parses the
// transitive set. A missing go.sum or go.mod is normal (not every module ships
// a lockfile) and yields nothing; any other read failure is surfaced as an
// unknown rather than aborting the run.
func extractGoSumFile(root, relSum string) ([]common.Dependency, []common.ExtractionUnknown) {
	sumData, absent, unknowns := readOptional(root, relSum)
	if absent {
		return nil, nil
	}
	if unknowns != nil {
		return nil, unknowns
	}
	modData, absent, modUnknowns := readOptional(root, siblingGoMod(relSum))
	if absent {
		return nil, nil
	}
	if modUnknowns != nil {
		return nil, modUnknowns
	}
	return parseGoSum(sumData, relSum, parseGoModRequirePairs(modData))
}

// siblingGoMod maps a go.sum's repo-relative path to the go.mod in the same
// directory.
func siblingGoMod(relSum string) string {
	return strings.TrimSuffix(relSum, "go.sum") + "go.mod"
}

// parseGoSum returns one inventory dependency per unique (module, version) pair
// in go.sum data that is not present in required. The h1 and /go.mod hash lines
// for a pair collapse into a single dependency; a line that does not carry a
// module and version is reported as an extraction unknown.
func parseGoSum(data []byte, file string, required map[goModPair]struct{}) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	seen := make(map[goModPair]struct{})
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if len(fields) < 2 {
			unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "malformed go.sum line: " + strings.TrimSpace(line)})
			continue
		}
		pair := goModPair{module: fields[0], version: strings.TrimSuffix(fields[1], "/go.mod")}
		if _, required := required[pair]; required {
			continue
		}
		if _, duplicate := seen[pair]; duplicate {
			continue
		}
		seen[pair] = struct{}{}
		deps = append(deps, common.Dependency{
			Category: common.CategoryGo,
			Name:     pair.module,
			Version:  pair.version,
			Source:   "go.sum transitive module",
			File:     file,
			Note:     inventoryNote,
		})
	}
	return deps, unknowns
}

// parseGoModRequirePairs returns the (module, version) pairs pinned by the
// require directives of a go.mod, covering both the single-line form
// (`require path version`) and the block form (`require ( ... )`). Comment and
// blank lines are ignored; the other directive families (module, go, exclude,
// replace, retract) never contribute a pair.
func parseGoModRequirePairs(data []byte) map[goModPair]struct{} {
	pairs := make(map[goModPair]struct{})
	inRequireBlock := false
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "//") {
			continue
		}
		fields := strings.Fields(trimmed)
		if inRequireBlock {
			if strings.HasPrefix(trimmed, ")") {
				inRequireBlock = false
				continue
			}
			if len(fields) >= 2 {
				pairs[goModPair{module: fields[0], version: fields[1]}] = struct{}{}
			}
			continue
		}
		if len(fields) < 2 || fields[0] != "require" {
			continue
		}
		if fields[1] == "(" {
			inRequireBlock = true
			continue
		}
		if len(fields) >= 3 {
			pairs[goModPair{module: fields[1], version: fields[2]}] = struct{}{}
		}
	}
	return pairs
}

// readOptional reads one repo-relative file. A missing file is reported as
// absent so callers can treat an optional lockfile as "nothing to extract"
// rather than a failure; any other read error is surfaced as an extraction
// unknown.
func readOptional(root, rel string) (data []byte, absent bool, unknowns []common.ExtractionUnknown) {
	data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err == nil {
		return data, false, nil
	}
	if os.IsNotExist(err) {
		return nil, true, nil
	}
	return nil, false, []common.ExtractionUnknown{{File: rel, Reason: "cannot read file: " + err.Error()}}
}
