package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

// main wires the pipeline: extract pins -> resolve upstream versions through a
// TTL cache -> classify -> assemble the report -> render JSON and/or console.
// Exit codes: 0 means the tool ran successfully (updates may exist); 1 means
// an operational failure (repo root unresolvable, JSON serialization failed).
// Update detection never changes the exit code.
func main() {
	jsonFlag := flag.Bool("json", false, "emit the JSON report to stdout")
	consoleFlag := flag.Bool("console", false, "emit the console report")
	freshFlag := flag.Bool("fresh", false, "bypass the cache and refetch upstream results")
	ignoreFlag := flag.Bool("ignore", false, "apply deps-ignore.json to mark intentional pins as ignored")
	flag.Parse()

	if !*jsonFlag && !*consoleFlag {
		*consoleFlag = true // default behavior: console report
	}

	root, err := repoRoot()
	if err != nil {
		fail("cannot locate repo root", err)
	}

	deps, unknowns := runAll(root)
	all := resolveAll(root, dedupe(deps), *freshFlag)

	var ignores ignoreSet
	if *ignoreFlag {
		ignores = loadIgnore(root)
	}

	rep := buildReport(all, unknowns, ignores, time.Now())

	if *jsonFlag {
		data, err := marshalReport(rep)
		if err != nil {
			fail("cannot serialize JSON report", err)
		}
		os.Stdout.Write(data)
		os.Stdout.Write([]byte("\n"))
	}
	if *consoleFlag {
		out := os.Stdout
		if *jsonFlag {
			// Keep stdout clean for the JSON report; console goes to stderr.
			out = os.Stderr
		}
		io.WriteString(out, renderConsole(rep, root))
	}
	os.Exit(0)
}

// resolveAll resolves every extracted dependency, consulting and updating the
// TTL cache for network-backed resolvers and resolving native deps live.
func resolveAll(root string, deps []dependency, fresh bool) []resolved {
	cachePath := filepath.Join(root, cacheFileRel)
	entries := loadCache(cachePath)
	changed := false

	var all []resolved
	for _, dep := range deps {
		all = append(all, resolveOne(dep, entries, fresh, &changed))
	}
	all = append(all, resolveNativeDeps(root)...)

	if changed {
		saveCache(cachePath, entries)
	}
	return all
}

// resolveOne resolves a single dependency. Network-backed resolvers go through
// the cache (unless --fresh); no-op and missing resolvers resolve directly and
// are never cached.
func resolveOne(dep dependency, entries map[string]cacheEntry, fresh bool, changed *bool) resolved {
	entry, ok := matchResolver(dep)
	if !ok || !entry.network {
		return resolveDep(dep)
	}
	key := cacheKey(dep)
	if !fresh {
		if cached, hit := entries[key]; hit {
			return classify(dep, entryToVersionInfo(cached))
		}
	}
	vi := entry.resolve(dep)
	entries[key] = versionInfoToEntry(vi)
	*changed = true
	return classify(dep, vi)
}

// fail reports an operational failure to stderr and exits 1. Callers pass the
// failing operation and the underlying error so the message is actionable.
func fail(op string, err error) {
	fmt.Fprintf(os.Stderr, "check-deps: %s: %v\n", op, err)
	os.Exit(1)
}

// warnf prints a non-fatal warning to stderr (cache/ignore failures never abort
// a run).
func warnf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "check-deps: warning: "+format+"\n", args...)
}
