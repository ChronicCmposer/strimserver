package main

import (
	"encoding/json"
	"errors"
	"strings"
)

// GitHub client. Used for golangci-lint, mediamtx, nv-codec-headers, and the
// GitHub Actions refs. Prefers /releases/latest and falls back to /tags on
// rate-limit or absence; a rate limit (403/429) is an "unknown" reason, never
// fatal.

type githubRelease struct {
	TagName     string `json:"tag_name"`
	PublishedAt string `json:"published_at"`
}

type githubTag struct {
	Name string `json:"name"`
}

// parseGitHubRelease decodes a /releases/latest body into a versionInfo.
func parseGitHubRelease(data []byte) (versionInfo, error) {
	var rel githubRelease
	if err := json.Unmarshal(data, &rel); err != nil {
		return versionInfo{}, err
	}
	if rel.TagName == "" {
		return versionInfo{}, errors.New("release body has no tag_name")
	}
	return versionInfo{version: rel.TagName, date: rel.PublishedAt}, nil
}

// parseGitHubTags decodes a /tags body into the ordered list of tag names.
func parseGitHubTags(data []byte) ([]string, error) {
	var tags []githubTag
	if err := json.Unmarshal(data, &tags); err != nil {
		return nil, err
	}
	names := make([]string, 0, len(tags))
	for _, t := range tags {
		names = append(names, t.Name)
	}
	return names, nil
}

// fetchGitHubLatest resolves the newest tag for owner/repo, trying
// /releases/latest first and falling back to the newest /tags entry. The first
// tag GitHub returns is newest-first, so tags[0] is the latest.
func fetchGitHubLatest(owner, repo string) versionInfo {
	if vi, err := fetchGitHubRelease(owner, repo); err == nil {
		return vi
	}
	data, err := fetchBytes("https://api.github.com/repos/" + owner + "/" + repo + "/tags")
	if err != nil {
		return versionInfo{err: err}
	}
	names, err := parseGitHubTags(data)
	if err != nil {
		return versionInfo{err: err}
	}
	if len(names) == 0 {
		return versionInfo{err: errors.New("GitHub repo has no tags")}
	}
	return versionInfo{version: names[0]}
}

func fetchGitHubRelease(owner, repo string) (versionInfo, error) {
	data, err := fetchBytes("https://api.github.com/repos/" + owner + "/" + repo + "/releases/latest")
	if err != nil {
		return versionInfo{}, err
	}
	return parseGitHubRelease(data)
}

// githubResolverFor builds a resolver for a fixed owner/repo pair.
func githubResolverFor(owner, repo string) resolverFunc {
	return func(dep dependency) versionInfo {
		return fetchGitHubLatest(owner, repo)
	}
}

// githubActionResolve resolves a ci-action dependency whose Name is
// "owner/repo"; the pin (dep.Version) is the @ref after the action name.
func githubActionResolve(dep dependency) versionInfo {
	owner, repo, found := strings.Cut(dep.Name, "/")
	if !found || owner == "" || repo == "" {
		return versionInfo{err: errors.New("malformed action name " + dep.Name)}
	}
	return fetchGitHubLatest(owner, repo)
}
