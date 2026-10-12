package resolverimpl

import (
	"fmt"
	"strings"

	"strimserver-check-deps/common"
)

// fish releases are tagged "4.3.1" (an optional leading v is tolerated).
// normalizeFishTag strips it so the result compares against the "4.3.1" the
// extractor recorded from deploy/aws/fish-deploy.sh.
func normalizeFishTag(tag string) (string, error) {
	version := strings.TrimPrefix(tag, "v")
	if version == "" {
		return "", fmt.Errorf("fish tag %q carries no version", tag)
	}
	return version, nil
}

// parseFishRelease is the pure bytes->VersionInfo parser for a fish GitHub
// release body.
func parseFishRelease(data []byte) (common.VersionInfo, error) {
	vi, err := parseGitHubRelease(data)
	if err != nil {
		return common.VersionInfo{}, err
	}
	version, err := normalizeFishTag(vi.Version)
	if err != nil {
		return common.VersionInfo{}, err
	}
	vi.Version = version
	return vi, nil
}

// FishResolve builds the fish-shell/fish-shell release resolver.
func FishResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return resolveGitHubTagged("fish-shell", "fish-shell", parseFishRelease, normalizeFishTag, f)
	}
}
