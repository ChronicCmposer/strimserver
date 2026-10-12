package resolverimpl

import (
	"fmt"
	"strings"

	"strimserver-check-deps/common"
)

// c-ares releases are tagged "v1.34.8". normalizeCaresTag strips the leading v
// so the result compares against the "1.34.8" the extractor recorded.
func normalizeCaresTag(tag string) (string, error) {
	version := strings.TrimPrefix(tag, "v")
	if version == "" {
		return "", fmt.Errorf("c-ares tag %q carries no version", tag)
	}
	return version, nil
}

// parseCaresRelease is the pure bytes->VersionInfo parser for a c-ares GitHub
// release body.
func parseCaresRelease(data []byte) (common.VersionInfo, error) {
	vi, err := parseGitHubRelease(data)
	if err != nil {
		return common.VersionInfo{}, err
	}
	version, err := normalizeCaresTag(vi.Version)
	if err != nil {
		return common.VersionInfo{}, err
	}
	vi.Version = version
	return vi, nil
}

// CaresResolve builds the c-ares/c-ares release resolver.
func CaresResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return resolveGitHubTagged("c-ares", "c-ares", parseCaresRelease, normalizeCaresTag, f)
	}
}
