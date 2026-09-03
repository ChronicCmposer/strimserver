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
// graph and pnpm owns the Stream Deck plugin's npm packages. These tools
// already know how to compute current+latest for their ecosystems, so the
// tool shells out to them instead of re-implementing resolution. A missing
// toolchain is an "unknown" record, never a crash.

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
func unknownResolved(category, reason string) common.Resolved {
	return common.Resolved{
		Dep:     common.Dependency{Category: category},
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

// resolveGoModules runs `go list -u -m all -json` in core/controller and turns
// each module into a classified record with current vs latest.
func resolveGoModules(root string, timeout time.Duration, classifier *common.Classifier) []common.Resolved {
	workDir := filepath.Join(root, "core", "controller")
	out, err := runNativeTool(workDir, []string{"go", "list", "-m", "-u", "-json", "all"}, timeout)
	if err != nil {
		return []common.Resolved{unknownResolved(common.CategoryGo, nativeToolReason(err, out, nativeToolMessages{
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
			return []common.Resolved{unknownResolved(common.CategoryGo, "cannot parse go list output: "+err.Error())}
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

type pnpmOutdated map[string]struct {
	Current string `json:"current"`
	Wanted  string `json:"wanted"`
	Latest  string `json:"latest"`
}

// resolvePNPM runs `pnpm outdated --json` in tools/streamdeck-plugin and turns
// each outdated package into a classified record. `pnpm outdated` exits 1 when
// anything is outdated, which is the expected success signal here; only other
// exit codes are failures.
func resolvePNPM(root string, timeout time.Duration, classifier *common.Classifier) []common.Resolved {
	workDir := filepath.Join(root, "tools", "streamdeck-plugin")
	out, err := runNativeTool(workDir, []string{"pnpm", "outdated", "--json"}, timeout)
	if err != nil && !isOutdatedExitOne(err) {
		return []common.Resolved{unknownResolved(common.CategoryNPM, nativeToolReason(err, out, nativeToolMessages{
			dirMissing: "tools/streamdeck-plugin directory not found",
			notFound:   "pnpm not found; node/pnpm toolchain missing",
			timeout:    "pnpm outdated timed out",
			failed:     "pnpm outdated failed",
		}))}
	}

	var outdated pnpmOutdated
	if err := json.Unmarshal(out, &outdated); err != nil {
		// Empty (or non-JSON) output means everything is up to date.
		return []common.Resolved{}
	}

	var res []common.Resolved
	for name, info := range outdated {
		dep := common.Dependency{
			Category: common.CategoryNPM,
			Name:     name,
			Version:  info.Current,
			File:     "tools/streamdeck-plugin/package.json",
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
	// nativeToolErrDirMissing means the command's working directory does not
	// exist, so the tool cannot even be run.
	nativeToolErrDirMissing nativeToolErrKind = iota
	// nativeToolErrNotFound means the tool binary itself is not installed.
	nativeToolErrNotFound
	// nativeToolErrTimeout means the command exceeded its deadline.
	nativeToolErrTimeout
	// nativeToolErrFailed means the command ran but exited unsuccessfully.
	nativeToolErrFailed
)

// nativeToolError is the categorized failure runNativeTool returns. It always
// carries the combined output when the command actually ran.
type nativeToolError struct {
	kind  nativeToolErrKind
	cause error  // underlying command error; nil for dir-missing
	out   []byte // combined stdout+stderr from the command, when it ran
}

// reason renders this error's human-readable failure phrase. Timeout and
// failure reasons append the combined output so the operator sees what the
// tool printed before dying. It is the single formatting point for
// native-tool failures: Error() and nativeToolReason both delegate here with
// their own phrases, so the kind + cause + output formatting never diverges.
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
// render a tool-specific reason. The combined output rides along so timeout
// and failure reasons can show what the tool printed.
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
	dirMissing string // working directory missing
	notFound   string // tool binary missing
	timeout    string // command exceeded the deadline (combined output appended)
	failed     string // command failed (cause and combined output appended)
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

// isOutdatedExitOne reports whether err is the expected "something is
// outdated" exit code (1) from pnpm outdated.
func isOutdatedExitOne(err error) bool {
	var exitErr *exec.ExitError
	return errors.As(err, &exitErr) && exitErr.ExitCode() == 1
}

func isDirectory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
