package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"strimserver-check-deps/common"
	"strimserver-check-deps/extractorimpl"
	"strimserver-check-deps/resolverimpl"
)

// Options is the single configuration struct for a check-deps run, mirroring
// the controller's Config precedent. main parses flags into an Options and the
// run() composition root consumes it; every external dependency (writers,
// clock) enters here so tests can inject fakes.
type Options struct {
	// JSON emits the JSON report to Stdout.
	JSON bool
	// Console emits the tiered human-readable report (to Stderr when JSON is
	// also set, so stdout stays clean for the machine-readable report).
	Console bool
	// Fresh bypasses the TTL cache and refetches every upstream result.
	Fresh bool
	// CacheTTL is how long resolved upstream results stay cached before refetch.
	CacheTTL time.Duration
	// Ignore applies deps-ignore.json to mark intentional pins as ignored.
	Ignore bool

	// Root is the repository root the run operates on.
	Root string

	// Stdout and Stderr are the injectable output writers; main wires os.Stdout
	// and os.Stderr, tests use in-memory buffers.
	Stdout io.Writer
	Stderr io.Writer

	// Warn is the non-fatal warning sink; main wires warnf, tests capture into
	// a slice. run requires it to be set and fails loudly if it is nil.
	Warn func(string, ...any)

	// Now is the single clock for the whole run: both the cache TTL check and
	// the report date come from here, so a frozen clock makes output
	// deterministic in tests.
	Now func() time.Time

	// NativeToolTimeout bounds each go/pnpm shell-out.
	NativeToolTimeout time.Duration
	// MaxConcurrentFetches bounds how many network resolutions run in parallel;
	// must be positive (run fails loudly if <= 0).
	MaxConcurrentFetches int
	// NativeTools enables the go list -u and pnpm outdated shell-outs. Defaults
	// to true; the e2e test sets it false to keep the pipeline deterministic
	// without a machine-dependent toolchain.
	NativeTools bool
}

// main is the composition root: it parses flags into Options, resolves the repo
// root, wires the warning sink and every collaborator, then runs the pipeline.
// Exit codes: 0 success (updates may exist), 1 operational failure.
func main() {
	jsonFlag := flag.Bool("json", false, "emit the JSON report to stdout")
	consoleFlag := flag.Bool("console", false, "emit the console report")
	freshFlag := flag.Bool("fresh", false, "bypass the cache and refetch upstream results")
	ignoreFlag := flag.Bool("ignore", false, "apply deps-ignore.json to mark intentional pins as ignored")
	flag.Parse()

	opts := Options{
		CacheTTL:             24 * time.Hour,
		NativeToolTimeout:    60 * time.Second,
		MaxConcurrentFetches: runtime.NumCPU(),
		NativeTools:          true,
	}
	opts.JSON = *jsonFlag
	opts.Console = *consoleFlag
	opts.Fresh = *freshFlag
	opts.Ignore = *ignoreFlag
	opts.Stdout = os.Stdout
	opts.Stderr = os.Stderr
	opts.Now = time.Now
	opts.Warn = warnf

	root, err := repoRoot(os.Getenv("BUILD_WORKSPACE_DIRECTORY"))
	if err != nil {
		fail("cannot locate repo root", err)
	}
	opts.Root = root

	fetcher := common.NewFetcher(warnf)

	resolvers := []common.ResolverEntry{
		{Match: isBazelModule, Resolve: resolverimpl.BCRResolve(fetcher), Network: true},
		githubDep(common.CategoryToolBinary, "golangci_lint_linux_amd64", "golangci", "golangci-lint", fetcher),
		githubDep(common.CategoryToolBinary, "mediamtx_dist", "bluenviron", "mediamtx", fetcher),
		networkedDep(common.Matches(common.CategoryRuntime, "iperf3"), resolverimpl.AlpineResolve(fetcher)),
		noopDep(common.Matches(common.CategoryBaseImage, "alpine"), resolverimpl.DigestResolve),
		networkedDep(common.Matches(common.CategoryBaseImage, "debian"), resolverimpl.DebianResolve(fetcher)),
		networkedDep(common.Matches(common.CategoryBaseImage, "amazonlinux"), resolverimpl.AmazonlinuxResolve(fetcher)),
		networkedDep(common.Matches(common.CategoryScriptPin, "qemu"), resolverimpl.QemuScrapeResolve(fetcher)),
		networkedDep(common.Matches(common.CategoryScriptPin, "openssh-portable"), resolverimpl.OpensshScrapeResolve(fetcher)),
		networkedDep(common.Matches(common.CategoryScriptPin, "GNU m4"), resolverimpl.M4ScrapeResolve(fetcher)),
		networkedDep(common.Matches(common.CategoryScriptPin, "ffmpeg"), resolverimpl.FfmpegScrapeResolve(fetcher)),
		githubDep(common.CategoryScriptPin, "nv-codec-headers", "FFmpeg", "nv-codec-headers", fetcher),
		networkedDep(common.Matches(common.CategoryScriptPin, "CUDA"), resolverimpl.NvidiaResolve(fetcher)),
		networkedDep(common.Matches(common.CategoryScriptPin, "distlib"), resolverimpl.PypiResolve(fetcher)),
		networkedDep(isCIAction, resolverimpl.GithubActionResolve(fetcher)),
		noopDep(isToolchain, resolverimpl.ToolchainResolve),
	}

	extractors := []common.Extractor{
		extractorimpl.ExtractModuleBazel,
		extractorimpl.ExtractGoMod,
		extractorimpl.ExtractToolchains,
		extractorimpl.ExtractWorkflows,
		extractorimpl.ExtractScripts,
	}

	err = run(
		&opts,
		newCache(&opts, root),
		resolvers,
		extractors,
	)
	if err != nil {
		fail("check-deps", err)
	}
	os.Exit(0)
}

// repoRoot resolves the repository root. The caller injects the Bazel
// workspace root (main reads it from BUILD_WORKSPACE_DIRECTORY), so the
// function is deterministic and testable without environment access; if the
// workspace is empty, walk up from the working directory until a MODULE.bazel
// file is found. An unresolvable root is an operational failure (exit 1), never
// a silent empty report.
func repoRoot(workspace string) (string, error) {
	if workspace != "" {
		if !isFile(filepath.Join(workspace, "MODULE.bazel")) {
			return "", fmt.Errorf("BUILD_WORKSPACE_DIRECTORY %s contains no MODULE.bazel", workspace)
		}
		return workspace, nil
	}
	dir, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("cannot determine working directory: %w", err)
	}
	for {
		if isFile(filepath.Join(dir, "MODULE.bazel")) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no MODULE.bazel found in %s or any parent directory", dir)
		}
		dir = parent
	}
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// fail reports an operational failure to stderr and exits 1.
func fail(op string, err error) {
	fmt.Fprintf(os.Stderr, "check-deps: %s: %v\n", op, err)
	os.Exit(1)
}

// warnf prints a non-fatal warning to stderr (cache/ignore failures never abort).
func warnf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "check-deps: warning: "+format+"\n", args...)
}

// run executes one full check-deps run: extract -> dedupe -> resolve
// (cache-aware, --fresh) -> native deps -> ignore load -> buildReport -> render
// to the injected writers. Every collaborator is injected so the whole pipeline
// is testable with fakes (the e2e tests call run directly).
func run(opts *Options, cache *Cache, resolvers []common.ResolverEntry, extractors []common.Extractor) error {
	// A non-positive MaxConcurrentFetches would spawn a zero-width worker pool
	// that deadlocks (no worker ever drains the job channel), so fail loudly
	// before any work begins.
	if opts.MaxConcurrentFetches <= 0 {
		return fmt.Errorf("Options.MaxConcurrentFetches must be positive, got %d", opts.MaxConcurrentFetches)
	}

	// Warn is required: every warning sinks here, so a nil sink would silently
	// drop warnings. Callers must wire it (main uses warnf, tests capture).
	if opts.Warn == nil {
		return fmt.Errorf("Options.Warn must be set")
	}

	deps, unknowns := extractAll(extractors, opts.Root)
	guard := newCacheGuard(cache.Load())
	all := resolveAll(opts, guard, resolvers, dedupe(deps))
	if guard.changed {
		cache.Save(guard.entries)
	}

	ignores := parsedIgnoreSet{}
	if opts.Ignore {
		ignores = loadIgnore(opts.Root, opts.Warn)
	}

	rep := buildReport(all, unknowns, ignores, opts.Now())

	return writeReport(rep, opts)
}

// writeReport renders the report in the requested output modes and owns the
// routing rule: JSON goes to Stdout, and the console report goes to Stderr
// when JSON is also emitted (so stdout stays clean for the machine-readable
// report) and to Stdout otherwise. The console is the default when no output
// mode is requested. Each write failure is surfaced with a descriptive wrap so
// the run can exit non-zero.
func writeReport(rep report, opts *Options) error {
	jsonOut := opts.JSON
	consoleOut := opts.Console || !opts.JSON

	if jsonOut {
		data, err := marshalReport(rep)
		if err != nil {
			return fmt.Errorf("cannot serialize JSON report: %w", err)
		}
		if _, err := fmt.Fprintln(opts.Stdout, string(data)); err != nil {
			return fmt.Errorf("cannot write JSON report: %w", err)
		}
	}
	if consoleOut {
		out := opts.Stdout
		if jsonOut {
			out = opts.Stderr // keep stdout clean for JSON
		}
		if _, err := io.WriteString(out, renderConsole(rep, opts.Root)); err != nil {
			return fmt.Errorf("cannot write console report: %w", err)
		}
	}
	return nil
}
