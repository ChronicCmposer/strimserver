package extractorimpl

import (
	"io/fs"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"strimserver-check-deps/common"
)

var goDirectiveRe = regexp.MustCompile(`(?m)^go\s+([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$`)

// discoverySkipBases are the directory basenames the module-file walk never
// descends into: VCS metadata, dependency trees, and bazel output trees. It
// mirrors common's node sub-repo skip set so every discovery pass agrees about
// which directories are out of bounds.
var discoverySkipBases = map[string]bool{
	".git":         true,
	"node_modules": true,
	"bazel-out":    true,
}

// ExtractGoMod emits the Go toolchain version from the `go` directive of every
// go.mod in the repository. Discovery replaces the hard-coded
// core/controller/go.mod path, so the tool's own tools/check-deps/go.mod is
// covered as well; each finding is tagged with the file that declared it.
func ExtractGoMod(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	return common.AggregateExtract(DiscoverGoModFiles(root), func(rel string) ([]common.Dependency, []common.ExtractionUnknown) {
		return common.ReadAndParse(root, rel, parseGoMod)
	})
}

// ExtractGoMod must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractGoMod

// DiscoverGoModFiles returns the sorted, repo-relative slash paths of every
// go.mod beneath root.
func DiscoverGoModFiles(root string) []string {
	return discoverBeneath(root, "go.mod")
}

// DiscoverGoSumFiles returns the sorted, repo-relative slash paths of every
// go.sum beneath root, using the same skip rules as DiscoverGoModFiles so the
// two discovery passes pair siblings consistently.
func DiscoverGoSumFiles(root string) []string {
	return discoverBeneath(root, "go.sum")
}

// discoverBeneath walks root and returns the sorted, repo-relative slash paths
// of every regular file named base. The walk does not descend into .git,
// node_modules, bazel-out, a directory whose name starts with bazel-, or the
// tool's own tools/check-deps/.cache directory, and it does not follow
// symlinked directories (bazel-* workspace symlinks therefore cannot escape
// into bazel-out).
func discoverBeneath(root, base string) []string {
	var found []string
	filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, relErr := filepath.Rel(root, path)
		if relErr != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if rel != "." && skipDiscoveryDir(rel, d.Name()) {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Name() == base {
			found = append(found, rel)
		}
		return nil
	})
	slices.Sort(found)
	return slices.Compact(found)
}

// skipDiscoveryDir reports whether the walk should not descend into the
// directory at repo-relative path rel with basename base.
func skipDiscoveryDir(rel, base string) bool {
	if discoverySkipBases[base] || strings.HasPrefix(base, "bazel-") {
		return true
	}
	return rel == "tools/check-deps/.cache"
}

// parseGoMod extracts the Go toolchain version from the `go` directive. The
// individual Go module requires are checked in a later phase via `go list -u`.
func parseGoMod(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	m := goDirectiveRe.FindSubmatch(data)
	if m == nil {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "no `go` directive found"}}
	}
	return []common.Dependency{{
		Category: common.CategoryToolchain,
		Name:     "Go",
		Version:  string(m[1]),
		Source:   "go.mod `go` directive",
		File:     file,
	}}, nil
}
