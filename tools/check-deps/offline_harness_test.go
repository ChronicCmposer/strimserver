package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"strimserver-check-deps/common"
)

// This file is the reusable offline test harness for check-deps: a throwaway
// repo tree on disk plus fakes for the extractor, resolver, and fetcher seams.
// It contains helpers only (no Test functions), so tests in this package can
// drive extraction and resolution deterministically with no network and no
// dependence on the real repository.

// WriteRepoTree writes files (repo-relative path -> content) into a fresh temp
// directory and returns that directory. Parent directories are created, so a
// caller declares only the files a test cares about. The tree is removed
// automatically when the test ends.
func WriteRepoTree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for rel, content := range files {
		path := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("WriteRepoTree: mkdir for %s: %v", rel, err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatalf("WriteRepoTree: write %s: %v", rel, err)
		}
	}
	return root
}

// ReadRepoFile reads a repo-relative file from a tree built by WriteRepoTree,
// failing the test if it cannot be read.
func ReadRepoFile(t *testing.T, root, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, rel))
	if err != nil {
		t.Fatalf("ReadRepoFile: %v", err)
	}
	return string(data)
}

// StaticExtractor returns an extractor that yields the given dependencies and
// unknowns, ignoring the repo root. It drives the pipeline with a fixed,
// filesystem-free dependency set.
func StaticExtractor(deps []common.Dependency, unknowns []common.ExtractionUnknown) common.Extractor {
	return func(string) ([]common.Dependency, []common.ExtractionUnknown) {
		return deps, unknowns
	}
}

// CountingResolver returns a resolver that records each invocation in calls
// (atomically, since resolvers may run concurrently in resolveAll) and answers
// vi. It lets a test prove a resolver did or did not run.
func CountingResolver(vi common.VersionInfo, calls *int64) common.Resolver {
	return func(common.Dependency) common.VersionInfo {
		atomic.AddInt64(calls, 1)
		return vi
	}
}

// FakeFetcher returns a *common.Fetcher backed by an httptest server that
// answers every request with handler. The server is closed automatically when
// the test ends, and the fetcher never sleeps or warns, so resolver tests run
// offline and fast.
func FakeFetcher(t *testing.T, handler http.HandlerFunc) *common.Fetcher {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	return &common.Fetcher{
		Client:     srv.Client(),
		UserAgent:  "check-deps-test",
		MaxBytes:   1 << 20,
		RetryDelay: 0,
		Sleep:      func(time.Duration) {},
		Warn:       func(string, ...any) {},
	}
}
