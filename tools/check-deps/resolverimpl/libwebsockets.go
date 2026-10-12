package resolverimpl

import (
	"fmt"
	"strings"

	"strimserver-check-deps/common"
)

// The canonical upstream is warmcat/libwebsockets, the repo the MODULE.bazel
// tarball_strip_symlinks URL points at. warningfix/libwebsockets is a fork and
// must not be queried.
const (
	libwebsocketsOwner = "warmcat"
	libwebsocketsRepo  = "libwebsockets"
)

// libwebsockets releases are tagged "v5.0.0". normalizeLibwebsocketsTag strips
// the leading v so the result compares against the "5.0.0" the extractor
// recorded.
func normalizeLibwebsocketsTag(tag string) (string, error) {
	version := strings.TrimPrefix(tag, "v")
	if version == "" {
		return "", fmt.Errorf("libwebsockets tag %q carries no version", tag)
	}
	return version, nil
}

// parseLibwebsocketsRelease is the pure bytes->VersionInfo parser for a
// libwebsockets GitHub release body.
func parseLibwebsocketsRelease(data []byte) (common.VersionInfo, error) {
	vi, err := parseGitHubRelease(data)
	if err != nil {
		return common.VersionInfo{}, err
	}
	version, err := normalizeLibwebsocketsTag(vi.Version)
	if err != nil {
		return common.VersionInfo{}, err
	}
	vi.Version = version
	return vi, nil
}

// LibwebsocketsResolve builds the warmcat/libwebsockets release resolver.
func LibwebsocketsResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return resolveGitHubTagged(libwebsocketsOwner, libwebsocketsRepo, parseLibwebsocketsRelease, normalizeLibwebsocketsTag, f)
	}
}
