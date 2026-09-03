package resolverimpl

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"strimserver-check-deps/common"
)

// Native tool integration: the Go toolchain (go list -u) owns the Go module
// graph and corepack pnpm owns each discovered node sub-repo's npm packages.
// These tools already know how to compute current+latest for their ecosystems,
// so the tool shells out to them instead of re-implementing resolution. A
// missing toolchain is an "unknown" record, never a crash.

// ResolveNativeDeps discovers Go module and npm package pins that Phase 1 did
// not extract (their pins live in lockfiles, not the build files) and returns
// them already classified. It matches the common.BatchResolver shape so main's
// wiring can register it alongside the per-client resolvers.
func ResolveNativeDeps(root string, timeout time.Duration, classifier *common.Classifier) []common.Resolved {
	var out []common.Resolved
	out = append(out, resolveGoModules(root, timeout, classifier)...)
	out = append(out, resolvePNPM(root, timeout, classifier)...)
	return out
}

// ResolveNativeDeps must keep satisfying the common.BatchResolver contract so
// the composition root can register it in the batch-resolver list.
var _ common.BatchResolver = ResolveNativeDeps

// unknownResolved builds a resolved record for a dependency whose latest
// version could not be resolved at all (missing toolchain, missing directory).
// file tags the record with the repo-relative source file it belongs to, so a
// per-sub-repo failure is attributable to that sub-repo.
func unknownResolved(category, file, reason string) common.Resolved {
	return common.Resolved{
		Dep:     common.Dependency{Category: category, File: file},
		Tier:    common.TierT3,
		Status:  common.StatusUnknown,
		Reasons: []string{reason},
	}
}

type goModuleJSON struct {
	Path    string `json:"Path"`
	Version string `json:"Version"`
	Update  struct {
		Version string `json:"Version"`
		Time    string `json:"Time"`
	} `json:"Update"`
}

func resolveGoModules(root string, timeout time.Duration, classifier *common.Classifier) []common.Resolved {
	workDir := filepath.Join(root, "core", "controller")
	out, err := runNativeTool(workDir, []string{"go", "list", "-m", "-u", "-json", "all"}, timeout)
	if err != nil {
		return []common.Resolved{unknownResolved(common.CategoryGo, "core/controller/go.mod", nativeToolReason(err, out, nativeToolMessages{
			dirMissing: "core/controller directory not found",
			notFound:   "go toolchain not found",
			timeout:    "go list -u timed out",
			failed:     "go list -u failed",
		}))}
	}

	var res []common.Resolved
	dec := json.NewDecoder(bytes.NewReader(out))
	for {
		var mod goModuleJSON
		if err := dec.Decode(&mod); err != nil {
			if err == io.EOF {
				break
			}
			return []common.Resolved{unknownResolved(common.CategoryGo, "core/controller/go.mod", "cannot parse go list output: "+err.Error())}
		}
		if mod.Path == "" || mod.Version == "" {
			continue
		}
		dep := common.Dependency{
			Category: common.CategoryGo,
			Name:     mod.Path,
			Version:  mod.Version,
			File:     "core/controller/go.mod",
		}
		vi := common.VersionInfo{Version: mod.Version}
		if mod.Update.Version != "" {
			vi.Version = mod.Update.Version
			vi.Date = mod.Update.Time
		}
		res = append(res, classifier.Classify(dep, vi))
	}
	return res
}

// pnpmOutdated is the JSON shape of `pnpm outdated --json`. pnpm 9 reports
// wanted (the version the current range resolves to) and latest per package and
// no longer emits current, so wanted is the closest available pin.
type pnpmOutdated map[string]struct {
	Wanted string `json:"wanted"`
	Latest string `json:"latest"`
}

// resolvePNPM runs `corepack pnpm outdated --json` in every discovered node
// sub-repo that has a package.json and turns each outdated package into a
// classified record tagged with that sub-repo's package.json. `pnpm outdated`
// exits 1 when anything is outdated, which is the expected success signal here;
// only other exit codes are failures. corepack provisions pnpm from the
// sub-repo's packageManager pin (or its default when the manifest has none), so
// no globally installed pnpm is required.
func resolvePNPM(root string, timeout time.Duration, classifier *common.Classifier) []common.Resolved {
	var res []common.Resolved
	for _, subRepo := range common.DiscoverNodeSubRepos(root) {
		if !common.NodeConfigFile(root, subRepo, "package.json") {
			// A .nvmrc-only sub-repo pins Node but has no npm dependency tree.
			continue
		}
		res = append(res, resolvePNPMSubRepo(root, subRepo, timeout, classifier)...)
	}
	return res
}

// resolvePNPMSubRepo resolves one node sub-repo's npm dependency tree via
// corepack pnpm.
func resolvePNPMSubRepo(root, subRepo string, timeout time.Duration, classifier *common.Classifier) []common.Resolved {
	packageJSON := filepath.Join(subRepo, "package.json")
	out, err := runNativeTool(filepath.Join(root, subRepo), []string{"corepack", "pnpm", "outdated", "--json"}, timeout)
	if err != nil && !isOutdatedExitOne(err) {
		return []common.Resolved{unknownResolved(common.CategoryNPM, packageJSON, nativeToolReason(err, out, nativeToolMessages{
			dirMissing: subRepo + " directory not found",
			notFound:   "corepack/node not found; node toolchain missing",
			timeout:    "corepack pnpm outdated timed out",
			failed:     "corepack pnpm outdated failed",
		}))}
	}

	var outdated pnpmOutdated
	// node may emit deprecation warnings on stderr, which runNativeTool merges
	// into the combined output ahead of the JSON; the report is the JSON
	// object, so parse from the first '{'. Output with no object (including
	// empty output) means everything is up to date.
	if start := bytes.IndexByte(out, '{'); start > 0 {
		out = out[start:]
	}
	if err := json.Unmarshal(out, &outdated); err != nil {
		// Empty (or non-JSON) output means everything is up to date.
		return []common.Resolved{}
	}

	var res []common.Resolved
	for name, info := range outdated {
		dep := common.Dependency{
			Category: common.CategoryNPM,
			Name:     name,
			Version:  info.Wanted,
			File:     packageJSON,
		}
		r := classifier.Classify(dep, common.VersionInfo{Version: info.Latest})
		res = append(res, r)
	}
	return res
}

// nativeToolErrKind classifies a native tool invocation failure so callers can
// render tool-specific "unknown" reasons without re-deriving the category.
type nativeToolErrKind int

const (
	nativeToolErrDirMissing nativeToolErrKind = iota
	nativeToolErrNotFound
	nativeToolErrTimeout
	nativeToolErrFailed
)

// nativeToolError is the categorized failure runNativeTool returns. It always
// carries the combined output when the command actually ran.
type nativeToolError struct {
	kind  nativeToolErrKind
	cause error  // underlying command error; nil for dir-missing
	out   []byte // combined stdout+stderr from the command, when it ran
}

// Unwrap exposes the underlying command error so errors.As can reach the
// *exec.ExitError inside a nativeToolError — isOutdatedExitOne relies on this
// to recognize pnpm's exit-1 "outdated" success signal.
func (e *nativeToolError) Unwrap() error {
	return e.cause
}

// reason renders this error's human-readable failure phrase. It is the single
// formatting point for native-tool failures: Error() and nativeToolReason both
// delegate here with their own phrases, so the kind + cause + output
// formatting never diverges.
func (e *nativeToolError) reason(msgs nativeToolMessages) string {
	switch e.kind {
	case nativeToolErrDirMissing:
		return msgs.dirMissing
	case nativeToolErrNotFound:
		return msgs.notFound
	case nativeToolErrTimeout:
		return msgs.timeout + ": " + string(e.out)
	default:
		return msgs.failed + ": " + e.cause.Error() + "\n" + string(e.out)
	}
}

func (e *nativeToolError) Error() string {
	return e.reason(nativeToolMessages{
		dirMissing: "working directory not found",
		notFound:   "tool not found",
		timeout:    "timed out",
		failed:     "failed",
	})
}

// runNativeTool runs args in workDir with the given timeout and returns the
// combined output. A missing workdir, a missing binary, a timeout, and a
// failing command are each classified into a nativeToolError so the caller can
// render a tool-specific reason.
func runNativeTool(workDir string, args []string, timeout time.Duration) ([]byte, error) {
	if !isDirectory(workDir) {
		return nil, &nativeToolError{kind: nativeToolErrDirMissing}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Dir = workDir
	out, err := cmd.CombinedOutput()
	if err != nil {
		switch {
		case errors.Is(err, exec.ErrNotFound):
			return out, &nativeToolError{kind: nativeToolErrNotFound, out: out}
		case ctx.Err() != nil:
			return out, &nativeToolError{kind: nativeToolErrTimeout, out: out}
		default:
			return out, &nativeToolError{kind: nativeToolErrFailed, cause: err, out: out}
		}
	}
	return out, nil
}

// nativeToolMessages carries the tool-specific human-readable failure phrases
// each resolver surfaces as its "unknown" reason.
type nativeToolMessages struct {
	dirMissing string
	notFound   string
	timeout    string
	failed     string
}

// nativeToolReason maps a runNativeTool error to its human-readable reason,
// delegating to the error type's single reason method so the rendering never
// diverges from Error(). The non-nativeToolError fallback is defensive only:
// runNativeTool always returns a nativeToolError, so it is unreachable in
// practice.
func nativeToolReason(err error, out []byte, msgs nativeToolMessages) string {
	var nte *nativeToolError
	if !errors.As(err, &nte) {
		return msgs.failed + ": " + err.Error() + "\n" + string(out)
	}
	return nte.reason(msgs)
}

func isOutdatedExitOne(err error) bool {
	var exitErr *exec.ExitError
	return errors.As(err, &exitErr) && exitErr.ExitCode() == 1
}

func isDirectory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
