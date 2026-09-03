package common

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Unit tests for node sub-repo discovery. Every case builds a synthetic repo
// tree in a temp dir, so the walk is deterministic and filesystem-free of the
// real repository.

func writeFixture(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("creating fixture directory: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("writing fixture file: %v", err)
	}
}

func TestDiscoverNodeSubReposFindsConfigSignals(t *testing.T) {
	root := t.TempDir()
	// A .nvmrc-only sub-repo and a package.json-only sub-repo both qualify;
	// a dir with both qualifies once.
	writeFixture(t, filepath.Join(root, "tools", "streamdeck-plugin", ".nvmrc"), "24.13.0\n")
	writeFixture(t, filepath.Join(root, "tools", "streamdeck-plugin", "package.json"), `{"packageManager":"pnpm@9.15.9"}`)
	writeFixture(t, filepath.Join(root, "web", "package.json"), `{}`)
	writeFixture(t, filepath.Join(root, "node-pin", ".nvmrc"), "22.0.0\n")

	got := DiscoverNodeSubRepos(root)
	want := []string{"node-pin", "tools/streamdeck-plugin", "web"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("DiscoverNodeSubRepos = %v, want %v (sorted, deduplicated)", got, want)
	}
}

func TestDiscoverNodeSubReposSkipList(t *testing.T) {
	root := t.TempDir()
	// Every skip-list entry hides a package.json (or .nvmrc) deeper inside that
	// must never be discovered.
	writeFixture(t, filepath.Join(root, "node_modules", "dep", "package.json"), `{}`)
	writeFixture(t, filepath.Join(root, ".git", "hooks", "package.json"), `{}`)
	writeFixture(t, filepath.Join(root, "bazel-out", "k8-fastbuild", "bin", "package.json"), `{}`)
	writeFixture(t, filepath.Join(root, "bazel-bin", "x", "package.json"), `{}`)
	writeFixture(t, filepath.Join(root, "bazel-testlogs", "y", ".nvmrc"), "1.0.0\n")
	writeFixture(t, filepath.Join(root, "tools", "check-deps", ".cache", "z", "package.json"), `{}`)

	if got := DiscoverNodeSubRepos(root); len(got) != 0 {
		t.Errorf("DiscoverNodeSubRepos descended into skip-list dirs: %v, want none", got)
	}
}

func TestDiscoverNodeSubReposDoesNotFollowSymlinkedDirs(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	writeFixture(t, filepath.Join(outside, "package.json"), `{}`)
	link := filepath.Join(root, "escaped")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}

	got := DiscoverNodeSubRepos(root)
	if len(got) != 0 {
		t.Errorf("DiscoverNodeSubRepos followed a symlinked dir: %v, want none", got)
	}
}

func TestDiscoverNodeSubReposDeterministic(t *testing.T) {
	root := t.TempDir()
	for _, dir := range []string{"tools/a", "tools/b", "z", "m/n"} {
		writeFixture(t, filepath.Join(root, dir, "package.json"), `{}`)
	}
	first := DiscoverNodeSubRepos(root)
	second := DiscoverNodeSubRepos(root)
	if !reflect.DeepEqual(first, second) {
		t.Errorf("DiscoverNodeSubRepos not deterministic: %v then %v", first, second)
	}
	if !reflect.DeepEqual(first, []string{"m/n", "tools/a", "tools/b", "z"}) {
		t.Errorf("DiscoverNodeSubRepos = %v, want lexical order", first)
	}
}

func TestNodeConfigFile(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, "tools", "sd", ".nvmrc"), "24.13.0\n")

	if !NodeConfigFile(root, "tools/sd", ".nvmrc") {
		t.Error("NodeConfigFile(.nvmrc) = false, want true")
	}
	if NodeConfigFile(root, "tools/sd", "package.json") {
		t.Error("NodeConfigFile(package.json) = true, want false")
	}
	if NodeConfigFile(root, "tools/sd", "bogus") {
		t.Error("NodeConfigFile(bogus) = true, want false")
	}
	if NodeConfigFile(root, "absent", ".nvmrc") {
		t.Error("NodeConfigFile in absent dir = true, want false")
	}
}
