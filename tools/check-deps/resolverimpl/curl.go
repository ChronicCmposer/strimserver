package resolverimpl

import (
	"errors"
	"fmt"
	"strings"

	"strimserver-check-deps/common"
)

// curl releases are tagged "curl-8_22_0": a curl- prefix and underscores where
// the version has dots. normalizeCurlTag strips the prefix and turns the
// underscores into dots so the result compares against the "8.22.0" the
// extractor recorded.
func normalizeCurlTag(tag string) (string, error) {
	version := strings.TrimPrefix(tag, "curl-")
	if version == "" {
		return "", fmt.Errorf("curl tag %q carries no version", tag)
	}
	return strings.ReplaceAll(version, "_", "."), nil
}

// parseCurlRelease is the pure bytes->VersionInfo parser for a curl GitHub
// release body: it normalizes the tag and keeps the release date.
func parseCurlRelease(data []byte) (common.VersionInfo, error) {
	vi, err := parseGitHubRelease(data)
	if err != nil {
		return common.VersionInfo{}, err
	}
	version, err := normalizeCurlTag(vi.Version)
	if err != nil {
		return common.VersionInfo{}, err
	}
	vi.Version = version
	return vi, nil
}

// resolveGitHubTagged resolves owner/repo's newest release and normalizes the
// raw tag through normalize, falling back to the newest tag when the release
// endpoint is absent (404) or its body does not parse. It mirrors
// fetchGitHubLatest but applies the per-project tag normalization the raw-tag
// helper cannot express; the release date is preserved when the release
// endpoint answers.
func resolveGitHubTagged(owner, repo string, parseRelease func([]byte) (common.VersionInfo, error), normalize func(string) (string, error), f *common.Fetcher) common.VersionInfo {
	if data, err := f.FetchBytes("https://api.github.com/repos/" + owner + "/" + repo + "/releases/latest"); err == nil {
		if vi, parseErr := parseRelease(data); parseErr == nil {
			return vi
		}
	}
	return fetchAndParse(f, "https://api.github.com/repos/"+owner+"/"+repo+"/tags", func(data []byte) (string, error) {
		names, err := parseGitHubTags(data)
		if err != nil {
			return "", err
		}
		if len(names) == 0 {
			return "", errors.New("GitHub repo has no tags")
		}
		return normalize(names[0])
	})
}

// CurlResolve builds the curl/curl release resolver.
func CurlResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return resolveGitHubTagged("curl", "curl", parseCurlRelease, normalizeCurlTag, f)
	}
}
