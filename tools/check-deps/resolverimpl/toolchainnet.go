package resolverimpl

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// Toolchain resolvers query the upstream channel each toolchain pin tracks:
// the Go download index, the Node dist index, the Bazel GitHub releases, and
// the pnpm npm packument. Each is a PURE parser (bytes -> version/error) plus a
// thin fetchAndParse wrapper; a network failure degrades to VersionInfo{Err}.

// --- Go ---------------------------------------------------------------------

// goRelease is one entry of the go.dev/dl/?mode=json index.
type goRelease struct {
	Version string `json:"version"`
	Stable  bool   `json:"stable"`
}

// parseGoReleases returns the newest stable Go version with the "go" prefix
// stripped (e.g. go1.26.4 -> 1.26.4). A body with no stable release is a
// fail-loud error.
func parseGoReleases(data []byte) (string, error) {
	var releases []goRelease
	if err := json.Unmarshal(data, &releases); err != nil {
		return "", err
	}
	var stable []string
	for _, release := range releases {
		if release.Stable {
			stable = append(stable, utilities.StripTagPrefix(release.Version))
		}
	}
	if len(stable) == 0 {
		return "", errors.New("go.dev/dl lists no stable releases")
	}
	return latestOf(stable, utilities.CompareSemver)
}

// GoToolchainResolve builds the Go toolchain resolver.
func GoToolchainResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return fetchAndParse(f, "https://go.dev/dl/?mode=json", parseGoReleases)
	}
}

// --- Node -------------------------------------------------------------------

// nodeRelease is one entry of nodejs.org/dist/index.json. lts is either a
// codename string or the boolean false, so it is decoded raw and classified by
// isNodeLTS.
type nodeRelease struct {
	Version string          `json:"version"`
	LTS     json.RawMessage `json:"lts"`
}

// parseNodeReleases returns the newest LTS Node version (leading v stripped).
// It falls back to the newest current release only when the index carries no
// LTS entries at all.
func parseNodeReleases(data []byte) (string, error) {
	var releases []nodeRelease
	if err := json.Unmarshal(data, &releases); err != nil {
		return "", err
	}
	var lts, all []string
	for _, release := range releases {
		version := strings.TrimPrefix(release.Version, "v")
		all = append(all, version)
		if isNodeLTS(release.LTS) {
			lts = append(lts, version)
		}
	}
	if len(lts) > 0 {
		return latestOf(lts, utilities.CompareSemver)
	}
	return latestOf(all, utilities.CompareSemver)
}

// isNodeLTS reports whether the raw index lts field is an LTS codename rather
// than the boolean false / null / empty.
func isNodeLTS(raw json.RawMessage) bool {
	value := strings.TrimSpace(string(raw))
	return value != "" && value != "false" && value != "null"
}

// NodeToolchainResolve builds the Node toolchain resolver.
func NodeToolchainResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return fetchAndParse(f, "https://nodejs.org/dist/index.json", parseNodeReleases)
	}
}

// --- Bazel ------------------------------------------------------------------

// Bazel releases are tagged "9.2.0" (an optional leading v is tolerated).
func normalizeBazelTag(tag string) (string, error) {
	version := strings.TrimPrefix(tag, "v")
	if version == "" {
		return "", fmt.Errorf("bazel tag %q carries no version", tag)
	}
	return version, nil
}

// parseBazelRelease is the pure bytes->VersionInfo parser for a Bazel GitHub
// release body.
func parseBazelRelease(data []byte) (common.VersionInfo, error) {
	vi, err := parseGitHubRelease(data)
	if err != nil {
		return common.VersionInfo{}, err
	}
	version, err := normalizeBazelTag(vi.Version)
	if err != nil {
		return common.VersionInfo{}, err
	}
	vi.Version = version
	return vi, nil
}

// BazelToolchainResolve builds the Bazel toolchain resolver from
// bazelbuild/bazel GitHub releases.
func BazelToolchainResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return resolveGitHubTagged("bazelbuild", "bazel", parseBazelRelease, normalizeBazelTag, f)
	}
}

// --- pnpm -------------------------------------------------------------------

// npmPackument carries the dist-tags map of an npm packument; the pnpm
// resolver reads dist-tags.latest.
type npmPackument struct {
	DistTags map[string]string `json:"dist-tags"`
}

// parseNpmDistTags returns the packument's dist-tags.latest, or a fail-loud
// error when it is absent.
func parseNpmDistTags(data []byte) (string, error) {
	var packument npmPackument
	if err := json.Unmarshal(data, &packument); err != nil {
		return "", err
	}
	latest := packument.DistTags["latest"]
	if latest == "" {
		return "", errors.New("npm packument has no dist-tags.latest")
	}
	return latest, nil
}

// PnpmToolchainResolve builds the pnpm toolchain resolver from the npm
// registry packument.
func PnpmToolchainResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return fetchAndParse(f, "https://registry.npmjs.org/pnpm", parseNpmDistTags)
	}
}
