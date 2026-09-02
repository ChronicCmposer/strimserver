package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// These tests prove the injected Warn sink is exercised on the non-fatal
// failure paths: a corrupt cache and a malformed deps-ignore.json both warn
// loudly and fall back to empty data rather than crashing.

// TestCacheWarnsOnCorruptJSON asserts Load warns "cache unreadable" and returns
// an empty entry map when the cache file is not valid JSON.
func TestCacheWarnsOnCorruptJSON(t *testing.T) {
	path := filepath.Join(t.TempDir(), cacheFileRel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("create cache dir: %v", err)
	}
	if err := os.WriteFile(path, []byte(`not json`), 0o644); err != nil {
		t.Fatalf("write corrupt cache: %v", err)
	}
	var warns []string
	c := &Cache{Path: path, TTL: testCacheTTL, Now: frozenNow, Warn: captureWarn(&warns)}

	if got := c.Load(); len(got) != 0 {
		t.Errorf("Load returned %d entries, want empty on corrupt JSON", len(got))
	}
	if joined := strings.Join(warns, "\n"); !strings.Contains(joined, "cache unreadable") {
		t.Errorf("corrupt cache should warn 'cache unreadable', got %v", warns)
	}
}

// TestLoadIgnoreWarnsOnMalformed asserts loadIgnore warns "ignoring malformed"
// and returns an empty non-nil set when deps-ignore.json is not valid JSON.
func TestLoadIgnoreWarnsOnMalformed(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ignoreFileName), []byte(`not json`), 0o644); err != nil {
		t.Fatalf("write malformed ignore: %v", err)
	}
	var warns []string

	if got := loadIgnore(dir, captureWarn(&warns)); got == nil || len(got) != 0 {
		t.Errorf("loadIgnore returned %v, want empty non-nil on malformed JSON", got)
	}
	if joined := strings.Join(warns, "\n"); !strings.Contains(joined, "ignoring malformed") {
		t.Errorf("malformed ignore should warn 'ignoring malformed', got %v", warns)
	}
}
