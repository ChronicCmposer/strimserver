package main

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
)

// Native tool integration: the Go toolchain (go list -u) owns the Go module
// graph and pnpm owns the Stream Deck plugin's npm packages. These tools
// already know how to compute current+latest for their ecosystems, so the
// tool shells out to them instead of re-implementing resolution. A missing
// toolchain is an "unknown" record, never a crash.

const nativeToolTimeout = 60 * time.Second

// resolveNativeDeps discovers Go module and npm package pins that Phase 1 did
// not extract (their pins live in lockfiles, not the build files) and returns
// them already classified.
func resolveNativeDeps(root string) []resolved {
	var out []resolved
	out = append(out, resolveGoModules(root)...)
	out = append(out, resolvePNPM(root)...)
	return out
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
func resolveGoModules(root string) []resolved {
	workDir := filepath.Join(root, "core", "controller")
	if !isDirectory(workDir) {
		return []resolved{unknownResolved("go", "core/controller directory not found")}
	}
	ctx, cancel := context.WithTimeout(context.Background(), nativeToolTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "go", "list", "-m", "-u", "-json", "all")
	cmd.Dir = workDir
	out, err := cmd.CombinedOutput()
	if err != nil {
		switch {
		case errors.Is(err, exec.ErrNotFound):
			return []resolved{unknownResolved("go", "go toolchain not found")}
		case ctx.Err() != nil:
			return []resolved{unknownResolved("go", "go list -u timed out: "+string(out))}
		default:
			return []resolved{unknownResolved("go", "go list -u failed: "+err.Error()+"\n"+string(out))}
		}
	}

	var res []resolved
	dec := json.NewDecoder(bytes.NewReader(out))
	for {
		var mod goModuleJSON
		if err := dec.Decode(&mod); err != nil {
			if err == io.EOF {
				break
			}
			return []resolved{unknownResolved("go", "cannot parse go list output: "+err.Error())}
		}
		if mod.Path == "" || mod.Version == "" {
			continue
		}
		dep := dependency{
			Category: "go",
			Name:     mod.Path,
			Version:  mod.Version,
			File:     "core/controller/go.mod",
		}
		vi := versionInfo{version: mod.Version}
		if mod.Update.Version != "" {
			vi.version = mod.Update.Version
			vi.date = mod.Update.Time
		}
		res = append(res, classify(dep, vi))
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
func resolvePNPM(root string) []resolved {
	workDir := filepath.Join(root, "tools", "streamdeck-plugin")
	if !isDirectory(workDir) {
		return []resolved{unknownResolved("npm", "tools/streamdeck-plugin directory not found")}
	}
	ctx, cancel := context.WithTimeout(context.Background(), nativeToolTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "pnpm", "outdated", "--json")
	cmd.Dir = workDir
	out, err := cmd.CombinedOutput()
	if err != nil && !isOutdatedExitOne(err) {
		switch {
		case errors.Is(err, exec.ErrNotFound):
			return []resolved{unknownResolved("npm", "pnpm not found; node/pnpm toolchain missing")}
		case ctx.Err() != nil:
			return []resolved{unknownResolved("npm", "pnpm outdated timed out")}
		default:
			return []resolved{unknownResolved("npm", "pnpm outdated failed: "+err.Error())}
		}
	}

	var outdated pnpmOutdated
	if err := json.Unmarshal(out, &outdated); err != nil {
		// Empty (or non-JSON) output means everything is up to date.
		return []resolved{}
	}

	var res []resolved
	for name, info := range outdated {
		dep := dependency{
			Category: "npm",
			Name:     name,
			Version:  info.Current,
			File:     "tools/streamdeck-plugin/package.json",
		}
		r := classify(dep, versionInfo{version: info.Latest})
		if name == "@rollup/rollup-linux-arm64-gnu" {
			// Intentional platform-locked pin; tolerated, not an update.
			r.Status = statusOK
			r.Tier = tierT3
			r.Infos = append(r.Infos, "intentional platform pin @4.62.2")
		}
		res = append(res, r)
	}
	return res
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
