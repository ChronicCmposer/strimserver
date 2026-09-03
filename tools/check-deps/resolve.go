package main

import (
	"errors"
	"sync"

	"strimserver-check-deps/common"
	"strimserver-check-deps/resolverimpl"
)

// This file routes each Phase 1 dependency to the version-source resolver that
// owns it and combines the resolver's answer with the classifier. Resolvers
// live in the resolverimpl package and each returns a common.VersionInfo; the
// common package's classifier turns that into a resolved record. Every
// network-backed resolver is closure-bound to the Fetcher it should reach
// through, so the resolver slice is testable with an httptest-backed fetcher
// and free of package globals.

// ResolverEntry matches a dependency (usually by category/name) to its
// resolver. Entries are evaluated in order; the first match wins. Network
// marks resolvers that perform upstream I/O worth caching (registry calls,
// scrapers); the no-op resolvers (digest, toolchain) are not network-backed
// and never cached.
type ResolverEntry struct {
	// Match reports whether the entry owns the dependency.
	Match func(common.Dependency) bool
	// Resolve answers the dependency's latest version once matched.
	Resolve common.Resolver
	// Network marks resolvers that perform upstream I/O worth caching.
	Network bool
}

func Matches(category, name string) func(common.Dependency) bool {
	return func(dep common.Dependency) bool {
		return dep.Category == category && dep.Name == name
	}
}

func matchResolver(resolvers []ResolverEntry, dep common.Dependency) (ResolverEntry, bool) {
	for _, e := range resolvers {
		if e.Match(dep) {
			return e, true
		}
	}
	return ResolverEntry{}, false
}

// resolveNoMatch builds the "unknown" record for a dependency that no
// resolver entry owns.
func resolveNoMatch(dep common.Dependency, classifier *common.Classifier) common.Resolved {
	return classifier.Classify(dep, common.VersionInfo{Err: errors.New("no resolver configured for this dependency")})
}

func resolveMatched(e ResolverEntry, dep common.Dependency, classifier *common.Classifier) common.Resolved {
	return classifier.Classify(dep, e.Resolve(dep))
}

// cacheGuard owns the shared mutable cache state and whether it changed during
// the run; resolveAll saves the entries when changed is set. The lock
// discipline is: peek answers under the lock, the network fetch happens
// outside it, and commit writes under the lock.
type cacheGuard struct {
	mu      sync.Mutex
	changed bool
	entries map[string]cacheEntry
}

// newCacheGuard is the single way to build a guard from a loaded entry map. A
// nil map is normalized to an empty one so a first successful cache write
// never panics on a nil map assignment.
func newCacheGuard(entries map[string]cacheEntry) *cacheGuard {
	if entries == nil {
		entries = map[string]cacheEntry{}
	}
	return &cacheGuard{entries: entries}
}

// peek answers a dependency without a network fetch when possible, reporting
// (resolved, true) on a hit and (resolved{}, false) when a fetch is required.
// It owns the lock: cache state is only read under the mutex, and the lock is
// released before returning, so the caller's network fetch runs outside it. It
// resolves directly (and never caches) when no resolver matched or the
// resolver is non-network; a network resolver's present cache entry (and not
// fresh) also answers directly. The bool is the unambiguous miss signal: a
// zero resolved on a miss is never handed back as a result or committed.
func (g *cacheGuard) peek(e ResolverEntry, ok bool, dep common.Dependency, fresh bool, classifier *common.Classifier) (common.Resolved, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !ok {
		return resolveNoMatch(dep, classifier), true
	}
	if !e.Network {
		return resolveMatched(e, dep, classifier), true
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
// classified result; the guard's changed flag records whether a write or an
// eviction actually mutated the cache. It owns the lock: cache state is only
// mutated under the mutex. A transient resolution failure is never written to
// the cache, so a one-off network or rate-limit blip is not replayed as
// "unknown" for the whole TTL; in fresh mode a failed refetch instead evicts
// any stale entry, so the next non-fresh run refetches rather than serving the
// stale value.
func (g *cacheGuard) commit(dep common.Dependency, vi common.VersionInfo, fresh bool, classifier *common.Classifier) common.Resolved {
	g.mu.Lock()
	defer g.mu.Unlock()
	res := classifier.Classify(dep, vi)
	key := cacheKey(dep)
	if vi.Err == nil {
		g.entries[key] = versionInfoToEntry(vi)
		g.changed = true
		return res
	}
	// Fresh mode evicts a stale entry so the next non-fresh run refetches.
	if !fresh {
		return res
	}
	if _, present := g.entries[key]; !present {
		return res
	}
	delete(g.entries, key)
	g.changed = true
	return res
}

// resolveJobWithCache resolves one worker job through the guard: peek answers
// without a fetch when possible, then the matched entry's resolver runs, then
// commit records the outcome.
func resolveJobWithCache(g *cacheGuard, job resolveJob, fresh bool, classifier *common.Classifier) common.Resolved {
	if res, hit := g.peek(job.entry, job.ok, job.dep, fresh, classifier); hit {
		return res
	}
	vi := job.entry.Resolve(job.dep)
	res := g.commit(job.dep, vi, fresh, classifier)
	return res
}

func matchesCategory(category string) func(common.Dependency) bool {
	return func(dep common.Dependency) bool {
		return dep.Category == category
	}
}

// githubDep builds a network-backed resolver entry for a dependency pinned
// from a fixed GitHub owner/repo pair, collapsing the repeated category/name
// -> owner/repo registrations.
func githubDep(category, name, owner, repo string, f *common.Fetcher) ResolverEntry {
	return ResolverEntry{Match: Matches(category, name), Resolve: resolverimpl.GithubResolverFor(owner, repo, f), Network: true}
}

func networkedDep(match func(common.Dependency) bool, resolve common.Resolver) ResolverEntry {
	return ResolverEntry{Match: match, Resolve: resolve, Network: true}
}

// noopDep builds a non-network resolver entry for one match rule: the digest
// and toolchain resolvers short-circuit locally with no upstream I/O and are
// never cached, so they register without the network flag.
func noopDep(match func(common.Dependency) bool, resolve common.Resolver) ResolverEntry {
	return ResolverEntry{Match: match, Resolve: resolve, Network: false}
}

// resolveJob pairs one dependency slot with its already-matched resolver
// entry. The matcher runs exactly once per dependency, in the feeder, and the
// entry is threaded through guard.peek and then resolved directly (commit
// needs only the dependency and its versionInfo), so the matcher is never
// re-run inside the concurrent branch.
type resolveJob struct {
	index int
	dep   common.Dependency
	entry ResolverEntry
	ok    bool
}

// resolveAll resolves every dependency, consulting and updating the TTL cache
// for network-backed resolvers. The caller injects the cacheGuard (built from
// the loaded cache entries) and the []common.BatchResolver list (the native
// go/pnpm resolvers), so the composition root controls construction and owns
// saving: resolveAll only mutates the guard and the caller persists the
// entries when the guard reports a change. A bounded worker pool (the
// MaxConcurrentFetches width, draining a job channel) performs the network
// fetches. Batch resolvers run serially after the worker pool and their
// records append in order, so output stays deterministic.
func resolveAll(opts *Options, guard *cacheGuard, resolvers []ResolverEntry, batchResolvers []common.BatchResolver, deps []common.Dependency, classifier *common.Classifier) []common.Resolved {
	results := make([]common.Resolved, len(deps))

	// Workers own distinct results slots (read only after wg.Wait), so those
	// writes need no lock.
	jobs := make(chan resolveJob)
	var wg sync.WaitGroup
	for w := 0; w < opts.MaxConcurrentFetches; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for job := range jobs {
				results[job.index] = resolveJobWithCache(guard, job, opts.Fresh, classifier)
			}
		}()
	}

	// Match the resolver once per dependency here, in input order.
	for i, dep := range deps {
		entry, ok := matchResolver(resolvers, dep)
		jobs <- resolveJob{index: i, dep: dep, entry: entry, ok: ok}
	}
	close(jobs)
	wg.Wait()

	for _, br := range batchResolvers {
		results = append(results, br(opts.Root, opts.NativeToolTimeout, classifier)...)
	}
	return results
}
