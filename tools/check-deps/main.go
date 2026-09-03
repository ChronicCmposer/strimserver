package main

import (
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"strimserver-check-deps/common"
	"strimserver-check-deps/extractorimpl"
	"strimserver-check-deps/resolverimpl"
)

// Options is the single configuration struct for a check-deps run. Every
// external dependency (writers, clock) enters here so tests can inject fakes.
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
	// All includes ok (current) dependencies in the findings list. By default
	// only update, unknown, and hygiene findings are listed; ok pins are
	// filtered from findings while counts still cover the full inventory.
	// --all restores the complete findings list.
	All bool

	// Root is the repository root the run operates on.
	Root string

	// Stdout and Stderr are the injectable output writers; main wires os.Stdout
	// and os.Stderr, tests use in-memory buffers.
	Stdout io.Writer
	Stderr io.Writer

	// Warn is the non-fatal warning sink. run fails loudly if it is nil.
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
	// NativeTools enables the go list -u and corepack pnpm outdated shell-outs.
	// Defaults to true; the e2e test sets it false to keep the pipeline
	// deterministic without a machine-dependent toolchain.
	NativeTools bool
	// HTTPTimeout bounds each upstream GET performed by the shared Fetcher.
	HTTPTimeout time.Duration
	// MaxResponseBytes caps the largest response body the Fetcher will accept.
	MaxResponseBytes int64
	// UserAgent is sent on every Fetcher request.
	UserAgent string
	// RateLimitRetryDelay is the backoff before the Fetcher's single rate-limit retry.
	RateLimitRetryDelay time.Duration
}

// main parses flags into Options, resolves the repo root, wires the warning
// sink and every collaborator, then runs the pipeline. Exit codes: 0 success
// (updates may exist), 1 operational failure.
func main() {
	jsonFlag := flag.Bool("json", false, "emit the JSON report to stdout")
	consoleFlag := flag.Bool("console", false, "emit the console report")
	freshFlag := flag.Bool("fresh", false, "bypass the cache and refetch upstream results")
	ignoreFlag := flag.Bool("ignore", false, "apply deps-ignore.json to mark intentional pins as ignored")
	allFlag := flag.Bool("all", false, "include current (ok) dependencies in the findings; by default only update, unknown, and hygiene findings are listed")
	flag.Parse()

	opts := Options{
		CacheTTL:             24 * time.Hour,
		NativeToolTimeout:    60 * time.Second,
		MaxConcurrentFetches: runtime.NumCPU(),
		NativeTools:          true,
		HTTPTimeout:          20 * time.Second,
		MaxResponseBytes:     16 << 20,
		UserAgent:            "strimserver-check-deps",
		RateLimitRetryDelay:  750 * time.Millisecond,
	}
	opts.JSON = *jsonFlag
	opts.Console = *consoleFlag
	opts.Fresh = *freshFlag
	opts.Ignore = *ignoreFlag
	opts.All = *allFlag
	opts.Stdout = os.Stdout
	opts.Stderr = os.Stderr
	opts.Now = time.Now
	opts.Warn = warnf

	root, err := repoRoot(os.Getenv("BUILD_WORKSPACE_DIRECTORY"))
	if err != nil {
		fail("cannot locate repo root", err)
	}
	opts.Root = root

	extractors := []common.Extractor{
		extractorimpl.ExtractModuleBazel,
		extractorimpl.ExtractGoMod,
		extractorimpl.ExtractToolchains,
		extractorimpl.ExtractWorkflows,
		extractorimpl.ExtractScripts,
	}

	fetcher := &common.Fetcher{
		Client:     &http.Client{Timeout: opts.HTTPTimeout},
		UserAgent:  opts.UserAgent,
		MaxBytes:   opts.MaxResponseBytes,
		RetryDelay: opts.RateLimitRetryDelay,
		Sleep:      time.Sleep,
		Warn:       opts.Warn,
	}

	resolvers := []ResolverEntry{
		networkedDep(matchesCategory(common.CategoryBazelModule), resolverimpl.BCRResolve(fetcher)),
		githubDep(common.CategoryToolBinary, "golangci_lint_linux_amd64", "golangci", "golangci-lint", fetcher),
		githubDep(common.CategoryToolBinary, "mediamtx_dist", "bluenviron", "mediamtx", fetcher),
		networkedDep(Matches(common.CategoryRuntime, "iperf3"), resolverimpl.AlpineResolve(fetcher)),
		noopDep(Matches(common.CategoryBaseImage, "alpine"), resolverimpl.DigestResolve),
		networkedDep(Matches(common.CategoryBaseImage, "debian"), resolverimpl.DebianResolve(fetcher)),
		networkedDep(Matches(common.CategoryBaseImage, "amazonlinux"), resolverimpl.AmazonlinuxResolve(fetcher)),
		networkedDep(Matches(common.CategoryScriptPin, "qemu"), resolverimpl.QemuScrapeResolve(fetcher)),
		networkedDep(Matches(common.CategoryBzlPin, "qemu"), resolverimpl.QemuScrapeResolve(fetcher)),
		networkedDep(Matches(common.CategoryScriptPin, "openssh-portable"), resolverimpl.OpensshScrapeResolve(fetcher)),
		networkedDep(Matches(common.CategoryScriptPin, "GNU m4"), resolverimpl.M4ScrapeResolve(fetcher)),
		networkedDep(Matches(common.CategoryScriptPin, "ffmpeg"), resolverimpl.FfmpegScrapeResolve(fetcher)),
		githubDep(common.CategoryScriptPin, "nv-codec-headers", "FFmpeg", "nv-codec-headers", fetcher),
		networkedDep(Matches(common.CategoryScriptPin, "CUDA"), resolverimpl.NvidiaResolve(fetcher)),
		networkedDep(Matches(common.CategoryScriptPin, "distlib"), resolverimpl.PypiResolve(fetcher)),
		networkedDep(matchesCategory(common.CategoryCIAction), resolverimpl.GithubActionResolve(fetcher)),
		noopDep(matchesCategory(common.CategoryToolchain), resolverimpl.ToolchainResolve),
	}

	batchResolvers := []common.BatchResolver{}
	if opts.NativeTools {
		batchResolvers = append(batchResolvers, resolverimpl.ResolveNativeDeps)
	}

	classifier := common.NewClassifier(
		[]common.TierPolicy{classifyFloatingBaseImage, classifyCIAction, classifyDateTag, classifySemver},
		[]common.BaseTierRule{
			{Category: common.CategoryBaseImage, Tier: common.TierT1},
			{Category: common.CategoryRuntime, Tier: common.TierT1},
			{Category: common.CategoryBazelModule, Tier: common.TierT2},
			{Category: common.CategoryToolchain, Tier: common.TierT2},
			{Category: common.CategoryCIAction, Tier: common.TierT2},
			// tool-binary is T2 by default; the media server binary is the one
			// security-critical exception.
			{Category: common.CategoryToolBinary, Name: "mediamtx_dist", Tier: common.TierT1},
			{Category: common.CategoryToolBinary, Tier: common.TierT2},
			// script-pin: the network-facing parsers and crypto/security tooling are
			// T1, the emulator is T2, everything else rests at T3.
			{Category: common.CategoryScriptPin, Name: "openssh-portable", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "ffmpeg", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "CUDA", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "nv-codec-headers", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "qemu", Tier: common.TierT2},
			// bzl-pin: the qemu_x86_64 repo-rule default is the cross-stripping
			// emulator for the amd64 mediamtx binary, so it rests at T2 like the
			// other qemu pins; anything else in the category defaults to T3.
			{Category: common.CategoryBzlPin, Name: "qemu", Tier: common.TierT2},
		},
	)

	err = run(
		&opts,
		newCache(&opts, root),
		resolvers,
		batchResolvers,
		extractors,
		classifier,
	)
	if err != nil {
		fail("check-deps", err)
	}
	os.Exit(0)
}

// repoRoot resolves the repository root. The caller injects the Bazel
// workspace root (main reads it from BUILD_WORKSPACE_DIRECTORY); when empty,
// walk up from the working directory until a MODULE.bazel file is found. An
// unresolvable root is an operational failure (exit 1), never a silent empty
// report.
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

// warnf prints a non-fatal warning to stderr; cache/ignore failures never abort.
func warnf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "check-deps: warning: "+format+"\n", args...)
}

// run executes one full check-deps run: extract -> dedupe -> resolve ->
// ignore load -> buildReport -> render to the injected writers. Every
// collaborator is injected so the whole pipeline is testable with fakes (the
// e2e tests call run directly).
func run(opts *Options, cache *Cache, resolvers []ResolverEntry, batchResolvers []common.BatchResolver, extractors []common.Extractor, classifier *common.Classifier) error {
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
	all := resolveAll(opts, guard, resolvers, batchResolvers, dedupe(deps), classifier)
	if guard.changed {
		cache.Save(guard.entries)
	}

	ignores := parsedIgnoreSet{}
	if opts.Ignore {
		ignores = loadIgnore(opts.Root, opts.Warn)
	}

	rep := buildReport(all, unknowns, ignores, opts.Now(), opts.All)

	return writeReport(rep, opts)
}

// writeReport renders the report in the requested output modes and owns the
// routing rule: JSON goes to Stdout, and the console report goes to Stderr
// when JSON is also emitted (so stdout stays clean for the machine-readable
// report) and to Stdout otherwise. The console is the default when no output
// mode is requested.
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
			out = opts.Stderr
		}
		if _, err := io.WriteString(out, renderConsole(rep, opts.Root)); err != nil {
			return fmt.Errorf("cannot write console report: %w", err)
		}
	}
	return nil
}
