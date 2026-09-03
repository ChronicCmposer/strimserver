package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"time"

	"strimserver-check-deps/common"
)

// This file owns the TTL cache of upstream registry results. The cache stores,
// per dependency, the versionInfo a resolver produced, keyed by the pinned
// current version so that bumping a pin invalidates that entry. The freshness
// TTL is injected via Options.CacheTTL; read/write failures are warned, never
// fatal (a read failure falls back to live fetches).

// cacheSchema is the on-disk format version of deps-cache.json.
const cacheSchema = 1

// Cache reads and writes the on-disk dependency cache. All collaborators
// (path, TTL, clock, warning sink) are injected so the behavior is testable
// and free of package-global state.
type Cache struct {
	Path string
	TTL  time.Duration
	Now  func() time.Time
	Warn func(string, ...any)
}

func newCache(opts *Options, root string) *Cache {
	return &Cache{
		Path: filepath.Join(root, cacheFileRel),
		TTL:  opts.CacheTTL,
		Now:  opts.Now,
		Warn: opts.Warn,
	}
}

type cacheEntry struct {
	Version string   `json:"version"`
	Date    string   `json:"date,omitempty"`
	Infos   []string `json:"infos,omitempty"`
}

type cacheFile struct {
	Schema  int                   `json:"schema"`
	Written time.Time             `json:"written"`
	Entries map[string]cacheEntry `json:"entries"`
}

const (
	cacheDirRel  = "tools/check-deps/.cache"
	cacheFileRel = cacheDirRel + "/deps-cache.json"
)

// cacheKey derives the stable cache key for a dependency. It keys on the
// pinned current version so a pin bump yields a fresh cache slot, and on the
// category/name/source so distinct dependencies never collide. The key is
// produced by common.DepIdentity, so dedupe and the cache share one identity
// definition.
func cacheKey(dep common.Dependency) string {
	return common.DepIdentity(dep).String()
}

// versionInfoToEntry converts a versionInfo into a serializable cacheEntry.
// Only successful resolutions are ever cached, so the error field is never
// written.
func versionInfoToEntry(vi common.VersionInfo) cacheEntry {
	return cacheEntry{
		Version: vi.Version,
		Date:    vi.Date,
		Infos:   slices.Clone(vi.Infos),
	}
}

func entryToVersionInfo(e cacheEntry) common.VersionInfo {
	return common.VersionInfo{
		Version: e.Version,
		Date:    e.Date,
		Infos:   slices.Clone(e.Infos),
	}
}

// Load reads and decodes the cache file, returning the live entries. A missing
// file is silent; corruption, schema mismatch, and expiry warn loudly. The
// caller always proceeds with live fetches (never fatal).
func (c *Cache) Load() map[string]cacheEntry {
	data, err := os.ReadFile(c.Path)
	if err != nil {
		return emptyCacheEntries()
	}
	var cf cacheFile
	if err := json.Unmarshal(data, &cf); err != nil {
		c.Warn("cache unreadable (%v); refetching live", err)
		return emptyCacheEntries()
	}
	if cf.Schema != cacheSchema {
		c.Warn("cache schema %d unsupported; refetching live", cf.Schema)
		return emptyCacheEntries()
	}
	if c.Now().Sub(cf.Written) > c.TTL {
		c.Warn("cache expired; refetching live")
		return emptyCacheEntries()
	}
	if cf.Entries == nil {
		return emptyCacheEntries()
	}
	return cf.Entries
}

func emptyCacheEntries() map[string]cacheEntry {
	return map[string]cacheEntry{}
}

// Save writes the entries atomically (temp file + rename) so a crash never
// leaves a half-written cache. A write failure is warned through Warn, never
// fatal.
func (c *Cache) Save(entries map[string]cacheEntry) {
	cf := cacheFile{
		Schema:  cacheSchema,
		Written: c.Now(),
		Entries: entries,
	}
	data, err := json.Marshal(cf)
	if err != nil {
		c.Warn("cannot encode cache: %v", err)
		return
	}
	dir := filepath.Dir(c.Path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		c.Warn("cannot create cache dir %s: %v", dir, err)
		return
	}
	tmp, err := os.CreateTemp(dir, "deps-cache-*.tmp")
	if err != nil {
		c.Warn("cannot create temp cache file: %v", err)
		return
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		c.Warn("cannot write cache: %v", err)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		c.Warn("cannot close cache: %v", err)
		return
	}
	if err := os.Rename(tmpName, c.Path); err != nil {
		os.Remove(tmpName)
		c.Warn("cannot rename cache into place: %v", err)
	}
}
