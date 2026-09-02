package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// This file owns the 24h TTL cache of upstream registry results. The cache
// stores, per dependency, the versionInfo a resolver produced, keyed by the
// pinned current version so that bumping a pin invalidates that entry. A cache
// read failure is never fatal (we fall back to live fetches); a write failure
// is warned, never fatal.

const (
	cacheSchema = 1
	cacheTTL    = 24 * time.Hour
)

// cacheEntry is the serialized form of a resolver's versionInfo.
type cacheEntry struct {
	Version string   `json:"version"`
	Date    string   `json:"date,omitempty"`
	Infos   []string `json:"infos,omitempty"`
	Err     string   `json:"err,omitempty"`
}

// cacheFile is the on-disk shape of deps-cache.json.
type cacheFile struct {
	Schema  int                   `json:"schema"`
	Written time.Time             `json:"written"`
	Entries map[string]cacheEntry `json:"entries"`
}

// cacheDirRel and cacheFileRel locate the cache relative to the repo root.
const (
	cacheDirRel  = "tools/check-deps/.cache"
	cacheFileRel = cacheDirRel + "/deps-cache.json"
)

// cacheKey derives the stable cache key for a dependency. It keys on the
// pinned current version so a pin bump yields a fresh cache slot, and on the
// category/name/source so distinct dependencies never collide.
func cacheKey(dep dependency) string {
	return dep.Category + "\x1f" + dep.Name + "\x1f" + dep.Source + "\x1f" + dep.Version
}

// versionInfoToEntry converts a versionInfo into a serializable cacheEntry.
func versionInfoToEntry(vi versionInfo) cacheEntry {
	e := cacheEntry{
		Version: vi.version,
		Date:    vi.date,
		Infos:   append([]string(nil), vi.infos...),
	}
	if vi.err != nil {
		e.Err = vi.err.Error()
	}
	return e
}

// entryToVersionInfo converts a cached entry back into a versionInfo.
func entryToVersionInfo(e cacheEntry) versionInfo {
	vi := versionInfo{
		version: e.Version,
		date:    e.Date,
		infos:   append([]string(nil), e.Infos...),
	}
	if e.Err != "" {
		vi.err = errors.New(e.Err)
	}
	return vi
}

// loadCache reads and decodes the cache file, returning the live entries. A
// missing, corrupt, or expired cache yields an empty entry map plus a loud
// warning: the caller always proceeds with live fetches (never fatal).
func loadCache(path string) map[string]cacheEntry {
	data, err := os.ReadFile(path)
	if err != nil {
		return map[string]cacheEntry{}
	}
	var cf cacheFile
	if err := json.Unmarshal(data, &cf); err != nil {
		warnf("cache unreadable (%v); refetching live", err)
		return map[string]cacheEntry{}
	}
	if cf.Schema != cacheSchema {
		warnf("cache schema %d unsupported; refetching live", cf.Schema)
		return map[string]cacheEntry{}
	}
	if time.Since(cf.Written) > cacheTTL {
		return map[string]cacheEntry{}
	}
	return cf.Entries
}

// saveCache writes the entries atomically (temp file + rename) so a crash
// never leaves a half-written cache. A write failure is warned, never fatal.
func saveCache(path string, entries map[string]cacheEntry) {
	cf := cacheFile{
		Schema:  cacheSchema,
		Written: time.Now(),
		Entries: entries,
	}
	data, err := json.Marshal(cf)
	if err != nil {
		warnf("cannot encode cache: %v", err)
		return
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		warnf("cannot create cache dir %s: %v", dir, err)
		return
	}
	tmp, err := os.CreateTemp(dir, "deps-cache-*.tmp")
	if err != nil {
		warnf("cannot create temp cache file: %v", err)
		return
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		warnf("cannot write cache: %v", err)
		return
	}
	if err := tmp.Close(); err != nil {
		warnf("cannot close cache: %v", err)
		return
	}
	if err := os.Rename(tmpName, path); err != nil {
		warnf("cannot rename cache into place: %v", err)
	}
}
