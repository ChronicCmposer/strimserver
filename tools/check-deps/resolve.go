package main

import (
	"errors"
	"sync"

	"strimserver-check-deps/common"
	"strimserver-check-deps/resolverimpl"
)

// This file routes each Phase 1 dependency to the version-source resolver that
// owns it and combines the resolver's answer with the classifier. Resolvers
// live in the resolverimpl package (bcr.go, dockerhub.go, ...) and each returns
// a common.VersionInfo; the common package's classifier turns that into a
// resolved record. The resolver slice holds the ordered set of resolvers; every
// network-backed resolver is closure-bound to the Fetcher it should reach
// through, so the slice is testable with an httptest-backed fetcher and free of
// package globals.

// matchResolver returns the first resolverEntry matching dep: entries are
// evaluated in order and the first match wins.
func matchResolver(resolvers []common.ResolverEntry, dep common.Dependency) (common.ResolverEntry, bool) {
	for _, e := range resolvers {
		if e.Match(dep) {
			return e, true
		}
	}
	return common.ResolverEntry{}, false
}

// resolveMatched resolves a dependency through an already-matched resolver
// entry, producing an "unknown" record when no entry matched. It is the
// direct, never-cached path shared by guard.peek for no-op/missing resolvers;
// the match is performed once by the caller and threaded in, so the entry is
// never re-matched here.
func resolveMatched(e common.ResolverEntry, ok bool, dep common.Dependency, classifier *common.Classifier) common.Resolved {
	if !ok {
		return classifier.Classify(dep, common.VersionInfo{Err: errors.New("no resolver configured for this dependency")})
	}
	return classifier.Classify(dep, e.Resolve(dep))
}

// cacheGuard owns the shared mutable cache state and the lock discipline
// around it: peek answers under the lock, the network fetch happens outside
// it, and commit writes under the lock. The parallel resolveAll worker path
// receives a guard injected by the caller; the serial resolveOne path builds
// its own, and both route through resolveJobWithCache, so the two share one
// cache-orchestration implementation (peek under the lock, fetch outside it,
// commit under the lock).
type cacheGuard struct {
	mu      sync.Mutex
	changed bool
	entries map[string]cacheEntry
}

// newCacheGuard is the single way to build a guard from a loaded entry map: the
// caller passes the cache entries read at load time, and the guard starts with
// the mutex zero value and changed false, exactly the state a fresh run needs.
func newCacheGuard(entries map[string]cacheEntry) *cacheGuard {
	return &cacheGuard{entries: entries}
}

// peek checks whether a dependency can be answered without a network fetch,
// reporting (resolved, true) when it can and (resolved{}, false) when a
// network fetch is required. It owns the lock: the shared cache state is only
// read under the mutex, and the lock is released before returning. The bool is
// the unambiguous miss signal: a zero resolved on a miss is never handed back
// as a result or committed. It resolves directly (and never caches) when no
// resolver matched or the resolver is non-network; a network resolver's
// present cache entry (and not fresh) also answers directly. The matched entry
// is resolved once by the caller and threaded in, so peek never re-matches.
func (g *cacheGuard) peek(e common.ResolverEntry, ok bool, dep common.Dependency, fresh bool, classifier *common.Classifier) (common.Resolved, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !ok || !e.Network {
		return resolveMatched(e, ok, dep, classifier), true
	}
	if fresh {
		return common.Resolved{}, false
	}
	if cached, hit := g.entries[cacheKey(dep)]; hit {
		return classifier.Classify(dep, entryToVersionInfo(cached)), true
	}
	return common.Resolved{}, false
}

// commit writes a successful resolution into the cache and returns the
// classified result plus whether the cache was mutated. It owns the lock: the
// shared cache state is only mutated under the mutex, and the changed flag is
// set when a write or eviction actually mutates the cache. A transient
// resolution failure is never written to the cache, so a one-off network or
// rate-limit blip is not replayed as "unknown" for the whole TTL; in fresh
// mode a failed refetch instead evicts any stale entry, so the next non-fresh
// run refetches rather than serving the stale value. The cache write and
// classification only need the dependency, versionInfo, and classifier, so the
// matched resolver entry is not threaded in.
func (g *cacheGuard) commit(dep common.Dependency, vi common.VersionInfo, fresh bool, classifier *common.Classifier) (common.Resolved, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if vi.Err != nil {
		if fresh {
			key := cacheKey(dep)
			if _, present := g.entries[key]; present {
				delete(g.entries, key)
				g.changed = true
				return classifier.Classify(dep, vi), true
			}
		}
		return classifier.Classify(dep, vi), false
	}
	g.entries[cacheKey(dep)] = versionInfoToEntry(vi)
	g.changed = true
	return classifier.Classify(dep, vi), true
}

// resolveOne resolves a single dependency and reports whether the cache was
// mutated. It is a single-job wrapper that delegates to resolveJobWithCache,
// so the serial test path and the parallel resolveAll worker path share one
// cache-orchestration implementation (peek under the lock, fetch outside it,
// commit under the lock). The resolver entry is matched once here and threaded
// through, so a dependency is never matched repeatedly.
func resolveOne(resolvers []common.ResolverEntry, dep common.Dependency, cacheEntries map[string]cacheEntry, fresh bool, classifier *common.Classifier) (common.Resolved, bool) {
	guard := newCacheGuard(cacheEntries)
	results := make([]common.Resolved, 1)
	e, ok := matchResolver(resolvers, dep)
	resolveJobWithCache(guard, results, resolveJob{index: 0, dep: dep, entry: e, ok: ok}, fresh, classifier)
	return results[0], guard.changed
}

// resolveJobWithCache resolves one worker job with correct lock boundaries
// around the shared cache: the cacheGuard owns the mutex acquire/release so
// the parallel resolveAll worker body stays a single call. guard.peek answers
// without a fetch (no-op/missing resolver, or a fresh-bypassed present cache
// entry) under the lock; when it misses, peek returns with the lock released
// and the matched entry's resolver runs over the network OUTSIDE it, so
// concurrent fetches stay bounded by the worker pool rather than serialized.
// guard.commit then writes the cache and the changed flag under the lock.
// Results writes need no lock: each worker owns a distinct results slot that
// is only read after the worker pool drains. The matched entry is threaded in
// from the caller, so it is never re-matched here.
func resolveJobWithCache(g *cacheGuard, results []common.Resolved, job resolveJob, fresh bool, classifier *common.Classifier) {
	if res, hit := g.peek(job.entry, job.ok, job.dep, fresh, classifier); hit {
		results[job.index] = res
		return
	}
	vi := job.entry.Resolve(job.dep) // network fetch happens OUTSIDE the lock
	res, _ := g.commit(job.dep, vi, fresh, classifier)
	results[job.index] = res
}

func isBazelModule(dep common.Dependency) bool { return dep.Category == common.CategoryBazelModule }
func isCIAction(dep common.Dependency) bool    { return dep.Category == common.CategoryCIAction }
func isToolchain(dep common.Dependency) bool   { return dep.Category == common.CategoryToolchain }

// githubDep builds a network-backed resolver entry for a dependency pinned
// from a fixed GitHub owner/repo pair. It collapses the repeated category/name
// -> owner/repo registrations so the upstream location sits adjacent to its
// match key.
func githubDep(category, name, owner, repo string, f *common.Fetcher) common.ResolverEntry {
	return common.ResolverEntry{Match: common.Matches(category, name), Resolve: resolverimpl.GithubResolverFor(owner, repo, f), Network: true}
}

// networkedDep builds a network-backed resolver entry for one match rule,
// collapsing the repeated match/resolve/network wiring so registrations read
// as "dep matching this rule is resolved over the network by xResolve".
func networkedDep(match func(common.Dependency) bool, resolve common.ResolverFunc) common.ResolverEntry {
	return common.ResolverEntry{Match: match, Resolve: resolve, Network: true}
}

// noopDep builds a non-network resolver entry for one match rule: the digest
// and toolchain resolvers short-circuit locally with no upstream I/O and are
// never cached, so they register without the network flag.
func noopDep(match func(common.Dependency) bool, resolve common.ResolverFunc) common.ResolverEntry {
	return common.ResolverEntry{Match: match, Resolve: resolve, Network: false}
}

// resolveJob pairs one dependency slot with its already-matched resolver
// entry. The matcher runs exactly once per dependency, in the feeder, and the
// entry is threaded through guard.peek and then resolved directly (commit
// needs only the dependency and its versionInfo), so the matcher is never
// re-run inside the concurrent branch.
type resolveJob struct {
	index int
	dep   common.Dependency
	entry common.ResolverEntry
	ok    bool
}

// resolveAll resolves every dependency, consulting and updating the TTL cache
// for network-backed resolvers and resolving native deps live. The caller
// injects the cacheGuard (built from the loaded cache entries), so the
// composition root controls construction and owns saving: resolveAll only
// mutates the guard and the caller persists the entries when the guard reports
// a change. A bounded worker pool (the MaxConcurrentFetches width, draining a
// job channel) performs the network fetches; the cacheGuard guards only the
// shared cache state (peek and commit), while each fetch runs outside the lock
// so concurrent fetches stay parallel rather than serialized. Result order
// mirrors the input order, so output stays deterministic.
func resolveAll(opts *Options, guard *cacheGuard, resolvers []common.ResolverEntry, deps []common.Dependency, classifier *common.Classifier) []common.Resolved {
	results := make([]common.Resolved, len(deps))

	// Spawn the bounded worker pool up front, then feed every dependency from
	// this goroutine. Workers own distinct results slots (read only after
	// wg.Wait), so those writes need no lock.
	jobs := make(chan resolveJob)
	var wg sync.WaitGroup
	for w := 0; w < opts.MaxConcurrentFetches; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for job := range jobs {
				// resolveJobWithCache delegates the lock boundaries to the
				// cacheGuard: peek and commit run under its lock guarding the
				// shared cache state, while the network fetch runs outside it
				// so concurrent fetches stay bounded by the worker pool rather
				// than serialized.
				resolveJobWithCache(guard, results, job, opts.Fresh, classifier)
			}
		}()
	}

	// Match the resolver once per dependency here, in input order, and hand the
	// matched entry to a worker through the job channel.
	for i, dep := range deps {
		entry, ok := matchResolver(resolvers, dep)
		jobs <- resolveJob{index: i, dep: dep, entry: entry, ok: ok}
	}
	close(jobs)
	wg.Wait()

	if opts.NativeTools {
		results = append(results, resolverimpl.ResolveNativeDeps(opts.Root, opts.NativeToolTimeout, classifier)...)
	}
	return results
}
