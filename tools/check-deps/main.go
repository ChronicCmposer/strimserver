package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"maps"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
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
	// Offline skips every network-backed resolver entry: matched network deps
	// are reported as skipped rather than fetched. No-op/digest resolvers are
	// unaffected.
	Offline bool
	// Strict makes any extraction unknown or undeterminable pin fail the run
	// with a non-zero exit. It defaults to true: a run that cannot determine a
	// pin's status is a failure unless deps-ignore.json records a reviewed
	// exception (an ignored unknown satisfies strict).
	Strict bool

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
	opts := newOptions()
	bindFlags(flag.CommandLine, &opts)
	flag.Parse()

	root, err := repoRoot(os.Getenv("BUILD_WORKSPACE_DIRECTORY"))
	if err != nil {
		fail("cannot locate repo root", err)
	}
	opts.Root = root

	extractors := []common.Extractor{
		extractorimpl.ExtractModuleBazel,
		extractorimpl.ExtractGoMod,
		extractorimpl.ExtractGoSum,
		extractorimpl.ExtractPnpmLock,
		extractorimpl.ExtractToolchains,
		extractorimpl.ExtractWorkflows,
		extractorimpl.ExtractScripts,
		extractorimpl.ExtractVendoredPins,
		extractorimpl.ExtractAppManifest,
		extractorimpl.ExtractEnv,
		extractorimpl.ExtractBazelrc,
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
		githubMatchDep(MatchesNamePrefix(common.CategoryToolBinary, "golangci_lint_linux_amd64"), "golangci", "golangci-lint", fetcher),
		githubMatchDep(MatchesNamePrefix(common.CategoryToolBinary, "mediamtx_dist"), "bluenviron", "mediamtx", fetcher),
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
		networkedDep(Matches(common.CategoryToolBinary, "curl"), resolverimpl.CurlResolve(fetcher)),
		networkedDep(Matches(common.CategoryToolBinary, "mbedtls"), resolverimpl.MbedtlsResolve(fetcher)),
		networkedDep(Matches(common.CategoryToolBinary, "cares"), resolverimpl.CaresResolve(fetcher)),
		networkedDep(Matches(common.CategoryToolBinary, "libwebsockets"), resolverimpl.LibwebsocketsResolve(fetcher)),
		githubDep(common.CategoryToolBinary, "protobuf_c", "protobuf-c", "protobuf-c", fetcher),
		networkedDep(Matches(common.CategoryToolBinary, "containerd_api"), resolverimpl.ContainerdAPIResolve(fetcher)),
		// The vendored third_party/<lib>/pin.json manifests name the same three
		// libraries with their upstream spelling (c-ares, containerd-api,
		// protobuf-c); register the resolvers under those names too so the
		// vendored pins resolve instead of surfacing as "no resolver".
		networkedDep(Matches(common.CategoryToolBinary, "c-ares"), resolverimpl.CaresResolve(fetcher)),
		networkedDep(Matches(common.CategoryToolBinary, "containerd-api"), resolverimpl.ContainerdAPIResolve(fetcher)),
		githubDep(common.CategoryToolBinary, "protobuf-c", "protobuf-c", "protobuf-c", fetcher),
		networkedDep(Matches(common.CategoryScriptPin, "fish"), resolverimpl.FishResolve(fetcher)),
		networkedDep(Matches(common.CategoryToolchain, "Go"), resolverimpl.GoToolchainResolve(fetcher)),
		networkedDep(Matches(common.CategoryToolchain, "Node"), resolverimpl.NodeToolchainResolve(fetcher)),
		networkedDep(Matches(common.CategoryToolchain, "Bazel"), resolverimpl.BazelToolchainResolve(fetcher)),
		networkedDep(Matches(common.CategoryToolchain, "pnpm"), resolverimpl.PnpmToolchainResolve(fetcher)),
		networkedDep(matchesCategory(common.CategoryCIAction), resolverimpl.GithubActionResolve(fetcher)),
		networkedDep(Matches(common.CategoryAMI, "dlami"), resolverimpl.DLAMIResolve(fetcher, opts.NativeToolTimeout)),
		noopDep(matchesCategory(common.CategoryToolchain), resolverimpl.ToolchainResolve),
	}

	batchResolvers := nativeBatchResolvers(&opts)

	classifier := newClassifier()

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

// newOptions returns Options with every production default applied, so the
// default path (and the flag defaults bindFlags registers) is defined once.
// --strict defaults on: a run that cannot determine a pin's status is a failure
// unless deps-ignore.json records a reviewed exception. --native-tools defaults
// on; CI sets it false for a hermetic, network-free check.
func newOptions() Options {
	return Options{
		CacheTTL:             24 * time.Hour,
		NativeToolTimeout:    60 * time.Second,
		MaxConcurrentFetches: runtime.NumCPU(),
		NativeTools:          true,
		Strict:               true,
		HTTPTimeout:          20 * time.Second,
		MaxResponseBytes:     16 << 20,
		UserAgent:            "strimserver-check-deps",
		RateLimitRetryDelay:  750 * time.Millisecond,
		Stdout:               os.Stdout,
		Stderr:               os.Stderr,
		Now:                  time.Now,
		Warn:                 warnf,
	}
}

// bindFlags registers every CLI flag on fs, reading each default from opts and
// writing the parsed value back into it. Registering against the Options value
// keeps the flag names, defaults, and fields in lockstep, and lets tests parse
// flags without touching the global command line.
func bindFlags(fs *flag.FlagSet, opts *Options) {
	fs.BoolVar(&opts.JSON, "json", opts.JSON, "emit the JSON report to stdout")
	fs.BoolVar(&opts.Console, "console", opts.Console, "emit the console report")
	fs.BoolVar(&opts.Fresh, "fresh", opts.Fresh, "bypass the cache and refetch upstream results")
	fs.BoolVar(&opts.Ignore, "ignore", opts.Ignore, "apply deps-ignore.json to mark intentional pins as ignored")
	fs.BoolVar(&opts.All, "all", opts.All, "include current (ok) dependencies in the findings; by default only update, unknown, and hygiene findings are listed")
	fs.BoolVar(&opts.Offline, "offline", opts.Offline, "skip every network-backed resolver (offline mode)")
	fs.BoolVar(&opts.Strict, "strict", opts.Strict, "fail the run (non-zero exit) when any pin is unknown or undeterminable; an ignored unknown satisfies strict")
	fs.BoolVar(&opts.NativeTools, "native-tools", opts.NativeTools, "run the native go list -u / pnpm outdated batch resolvers; set false for a hermetic, network-free check")
}

// nativeBatchResolvers selects the batch resolvers for a run. --offline takes
// precedence: the real native go/pnpm shell-outs are replaced by
// offlineNativeBatch, which reads the pins from disk and reports them skipped
// with no network access, so --offline alone is hermetic. Online, the real
// native resolver runs when native tools are enabled, and no batch resolver
// runs at all when they are disabled (--native-tools=false).
func nativeBatchResolvers(opts *Options) []common.BatchResolver {
	if opts.Offline {
		return []common.BatchResolver{offlineNativeBatch}
	}
	if opts.NativeTools {
		return []common.BatchResolver{resolverimpl.ResolveNativeDeps}
	}
	return nil
}

// offlineNativeBatch is the offline counterpart of resolverimpl.ResolveNativeDeps:
// it discovers the Go module requires (every go.mod) and the npm package ranges
// (every node sub-repo's package.json) and reports each as skipped. It performs
// no shell-out and no network access, so an --offline run is hermetic while
// still surfacing the native pins it deliberately did not resolve.
func offlineNativeBatch(root string, _ time.Duration, classifier *common.Classifier) []common.Resolved {
	var out []common.Resolved
	out = append(out, offlineGoModules(root, classifier)...)
	out = append(out, offlineNodePackages(root, classifier)...)
	return out
}

// offlineGoModules reports every go.mod require directive as a skipped go pin,
// tagged with the go.mod that declared it.
func offlineGoModules(root string, classifier *common.Classifier) []common.Resolved {
	var out []common.Resolved
	for _, rel := range extractorimpl.DiscoverGoModFiles(root) {
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			continue
		}
		for _, req := range parseRequireDirectives(data) {
			out = append(out, offlineSkipped(common.Dependency{
				Category: common.CategoryGo,
				Name:     req.name,
				Version:  req.version,
				File:     rel,
			}, classifier))
		}
	}
	return out
}

// offlineNodePackages reports every declared dependency and devDependency of
// every node sub-repo's package.json as a skipped npm pin.
func offlineNodePackages(root string, classifier *common.Classifier) []common.Resolved {
	var out []common.Resolved
	for _, subRepo := range common.DiscoverNodeSubRepos(root) {
		if !common.NodeConfigFile(root, subRepo, "package.json") {
			continue
		}
		rel := filepath.ToSlash(filepath.Join(subRepo, "package.json"))
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			continue
		}
		var manifest struct {
			Dependencies    map[string]string `json:"dependencies"`
			DevDependencies map[string]string `json:"devDependencies"`
		}
		if err := json.Unmarshal(data, &manifest); err != nil {
			continue
		}
		for _, group := range []map[string]string{manifest.Dependencies, manifest.DevDependencies} {
			for _, name := range slices.Sorted(maps.Keys(group)) {
				out = append(out, offlineSkipped(common.Dependency{
					Category: common.CategoryNPM,
					Name:     name,
					Version:  group[name],
					File:     rel,
				}, classifier))
			}
		}
	}
	return out
}

// goRequire is one (module, version) pair pinned by a go.mod require directive.
type goRequire struct {
	name    string
	version string
}

// parseRequireDirectives returns the (module, version) pairs pinned by the
// require directives of a go.mod, covering the single-line and block forms.
// Comment and blank lines are ignored; the other directive families (module,
// go, exclude, replace, retract) never contribute a pair. It mirrors the
// extractor-side parser so the offline skip report names the same pins the
// online native resolver would.
func parseRequireDirectives(data []byte) []goRequire {
	var pairs []goRequire
	inRequireBlock := false
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "//") {
			continue
		}
		fields := strings.Fields(trimmed)
		if inRequireBlock {
			if strings.HasPrefix(trimmed, ")") {
				inRequireBlock = false
				continue
			}
			if len(fields) >= 2 {
				pairs = append(pairs, goRequire{name: fields[0], version: fields[1]})
			}
			continue
		}
		if len(fields) < 2 || fields[0] != "require" {
			continue
		}
		if fields[1] == "(" {
			inRequireBlock = true
			continue
		}
		if len(fields) >= 3 {
			pairs = append(pairs, goRequire{name: fields[1], version: fields[2]})
		}
	}
	return pairs
}

// newClassifier builds the production classifier: the ordered tier-policy
// dispatch and the resting-tier base rules. Named base rules sit before their
// category default so a security-critical or blast-radius override always wins
// the first-match dispatch.
func newClassifier() *common.Classifier {
	return common.NewClassifier(
		[]common.TierPolicy{classifyFloatingBaseImage, classifyCIAction, classifyDateTag, classifyAMI, classifySemver},
		[]common.BaseTierRule{
			{Category: common.CategoryBaseImage, Tier: common.TierT1},
			{Category: common.CategoryRuntime, Tier: common.TierT1},
			{Category: common.CategoryAMI, Tier: common.TierT1},
			{Category: common.CategoryBazelModule, Tier: common.TierT2},
			{Category: common.CategoryToolchain, Tier: common.TierT2},
			{Category: common.CategoryCIAction, Tier: common.TierT2},
			// tool-binary is T2 by default. The media server binary and its arm
			// twin are the security-critical T1 exceptions; the image-linked C
			// libraries are named T2 so their blast radius is explicit rather
			// than inherited from the category default.
			{Category: common.CategoryToolBinary, Name: "mediamtx_dist", Tier: common.TierT1},
			{Category: common.CategoryToolBinary, Name: "mediamtx_dist_arm64", Tier: common.TierT1},
			{Category: common.CategoryToolBinary, Name: "curl", Tier: common.TierT2},
			{Category: common.CategoryToolBinary, Name: "mbedtls", Tier: common.TierT2},
			{Category: common.CategoryToolBinary, Name: "cares", Tier: common.TierT2},
			{Category: common.CategoryToolBinary, Name: "libwebsockets", Tier: common.TierT2},
			{Category: common.CategoryToolBinary, Name: "protobuf_c", Tier: common.TierT2},
			{Category: common.CategoryToolBinary, Name: "containerd_api", Tier: common.TierT2},
			{Category: common.CategoryToolBinary, Tier: common.TierT2},
			// script-pin: the network-facing parsers and crypto/security tooling
			// are T1, the emulator and the fish deploy shell are T2, everything
			// else rests at T3.
			{Category: common.CategoryScriptPin, Name: "openssh-portable", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "ffmpeg", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "CUDA", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "nv-codec-headers", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "qemu", Tier: common.TierT2},
			{Category: common.CategoryScriptPin, Name: "fish", Tier: common.TierT2},
			// bzl-pin: the qemu_x86_64 repo-rule default is the cross-stripping
			// emulator for the amd64 mediamtx binary, so it rests at T2 like the
			// other qemu pins; anything else in the category defaults to T3.
			{Category: common.CategoryBzlPin, Name: "qemu", Tier: common.TierT2},
		},
	)
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

	// The ignore set is loaded whenever it can affect the outcome: --ignore
	// marks findings ignored in the report, and --strict consults it so a
	// reviewed unknown satisfies the run. Loading it once and threading it
	// through both keeps the report and the strict verdict consistent.
	ignores := parsedIgnoreSet{}
	if opts.Ignore || opts.Strict {
		ignores = loadIgnore(opts.Root, opts.Warn)
	}

	now := opts.Now()
	rep := buildReport(all, unknowns, ignores, now, opts.All)

	if err := writeReport(rep, opts); err != nil {
		return err
	}
	return strictFailure(opts, all, unknowns, ignores, now)
}

// strictFailure returns a non-zero-exit error when --strict is set and any
// extraction unknown or undeterminable pin remains; it returns nil otherwise.
// The report is written before this check, so the reviewer sees the full
// picture alongside the failure. A run that is not strict is never affected.
//
// An unknown is "satisfied" when a live ignore rule covers it: a resolved
// unknown by its id (category/name) and optional file, a Phase-1 extraction
// unknown (which carries only a file) by a file-scoped rule. Integrity and
// inventory pins are exempt entirely: they carry no review tier and never
// surface as findings, so an ignore rule is never needed for them. A rule whose
// until is malformed or already expired does not satisfy (fail closed).
func strictFailure(opts *Options, all []common.Resolved, unknowns []common.ExtractionUnknown, ignores parsedIgnoreSet, today time.Time) error {
	if !opts.Strict {
		return nil
	}
	calToday := calendarDate(today)

	unsatisfiedUnknowns := 0
	for _, u := range unknowns {
		if ignores.coversFile(u.File, calToday) {
			continue
		}
		unsatisfiedUnknowns++
	}
	if unsatisfiedUnknowns > 0 {
		return fmt.Errorf("strict: %d extraction unknown(s); the run cannot be trusted", unsatisfiedUnknowns)
	}

	undetermined := 0
	for _, r := range all {
		if sectionFor(r) != sectionFinding {
			// Integrity and inventory pins are exempt from strict: they are
			// recorded, not reviewed, and never carry a comparable version.
			continue
		}
		if r.Status != common.StatusUnknown {
			continue
		}
		if ignores.isIgnoredOn(findingID(r.Dep), r.Dep.File, calToday) {
			continue
		}
		undetermined++
	}
	if undetermined > 0 {
		return fmt.Errorf("strict: %d undeterminable pin(s); the run cannot be trusted", undetermined)
	}
	return nil
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
