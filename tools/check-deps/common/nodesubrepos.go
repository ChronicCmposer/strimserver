package common

import (
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// Node sub-repo discovery. A repository pins its Node toolchain and npm
// dependency tree in one or more node sub-repos, each marked by a .nvmrc or a
// package.json file. Toolchain extraction (ExtractToolchains) and native npm
// resolution (resolvePNPM) both derive their targets from this one helper, so
// the two phases never disagree about which directories are node sub-repos.

// nodeConfigSignals are the file basenames that mark a directory as a node
// sub-repo.
var nodeConfigSignals = []string{".nvmrc", "package.json"}

// nodeSubRepoSkipBases are the directory basenames the discovery walk never
// descends into: VCS metadata, dependency trees, and bazel output trees.
// The bazel-* workspace entries are symlinks into bazel-out (and the real
// bazel-out tree sits beside them); filepath.WalkDir does not follow
// symlinked directories, and the name skip covers the real bazel-out tree.
var nodeSubRepoSkipBases = map[string]bool{
	".git":         true,
	"node_modules": true,
	"bazel-out":    true,
}

// DiscoverNodeSubRepos walks the repository tree from root and returns the
// repo-relative paths of every directory that contains a .nvmrc or a
// package.json file: the node sub-repo roots. The result is sorted and
// deduplicated so callers and their output are deterministic. The walk never
// descends into .git, node_modules, bazel-out, any directory whose name starts
// with bazel-, or the tool's own tools/check-deps/.cache directory, and it
// does not follow symlinked directories (bazel-* workspace symlinks therefore
// cannot escape into bazel-out).
func DiscoverNodeSubRepos(root string) []string {
	var found []string
	filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || !d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if rel != "." && skipNodeSubRepoDir(rel, d.Name()) {
			return filepath.SkipDir
		}
		if nodeConfigFileIn(path) {
			found = append(found, rel)
		}
		return nil
	})
	slices.Sort(found)
	return slices.Compact(found)
}

// skipNodeSubRepoDir reports whether the walk should not descend into the
// directory at repo-relative path rel with basename base.
func skipNodeSubRepoDir(rel, base string) bool {
	if nodeSubRepoSkipBases[base] || strings.HasPrefix(base, "bazel-") {
		return true
	}
	return rel == "tools/check-deps/.cache"
}

// nodeConfigFileIn reports whether the directory contains a node config signal
// file.
func nodeConfigFileIn(dir string) bool {
	for _, name := range nodeConfigSignals {
		if isRegularFile(filepath.Join(dir, name)) {
			return true
		}
	}
	return false
}

// NodeConfigFile reports whether the named node config signal exists as a
// regular file inside the repo-relative directory relDir of the repository at
// root. Callers use it to decide which signal files of a discovered sub-repo to
// read; keeping the existence check here next to discovery keeps the two
// consistent about what counts as a signal.
func NodeConfigFile(root, relDir, name string) bool {
	return isRegularFile(filepath.Join(root, filepath.FromSlash(relDir), name))
}

func isRegularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}
