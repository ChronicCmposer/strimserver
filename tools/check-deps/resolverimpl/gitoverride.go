package resolverimpl

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// Git-override bazel modules never resolve through BCR: the git_override
// redirects the module to a git remote, so the registry's metadata.json 404s.
// This resolver reads the remote from the dependency's Source (stamped by the
// MODULE.bazel extractor), lists the GitHub repo's public tags, and reports
// the newest semver tag whose commit is reachable from the main branch.

const (
	gitOverridePerPage  = 100
	gitOverrideMaxPages = 10
	// gitOverrideMaxCompares caps how far down the newest-tags list the
	// resolver walks looking for a tag that is actually on main, so a repo
	// whose newest tags live on release branches costs a bounded number of
	// compare requests.
	gitOverrideMaxCompares = 5
)

var (
	gitHubRemoteRe = regexp.MustCompile(`^(?:https://|ssh://git@|git@)github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$`)
	semverTagRe    = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$`)
)

// GitHubRemoteOwnerRepo parses a GitHub git remote in its https, ssh://, or
// scp-like form and returns the owner and repo. ok is false for non-GitHub
// remotes and malformed URLs, so the resolver registry can fall through to
// the BCR entry instead of guessing.
func GitHubRemoteOwnerRepo(remote string) (owner, repo string, ok bool) {
	m := gitHubRemoteRe.FindStringSubmatch(remote)
	if m == nil {
		return "", "", false
	}
	return m[1], m[2], true
}

// isSemverTag reports whether a stripped tag name is a semver version, so
// whole-repo date tags or branch-named tags never become "latest".
func isSemverTag(version string) bool {
	return semverTagRe.MatchString(version)
}

// parseGitOverrideTags parses one GitHub tags page and returns the semver tag
// names it carries (leading v stripped) plus the page's total tag count,
// which the pagination walk uses to detect the last page.
func parseGitOverrideTags(data []byte) (versions []string, pageSize int, err error) {
	names, err := parseGitHubTags(data)
	if err != nil {
		return nil, 0, err
	}
	for _, name := range names {
		if version := strings.TrimPrefix(name, "v"); isSemverTag(version) {
			versions = append(versions, version)
		}
	}
	return versions, len(names), nil
}

// sortSemverDescending returns the versions ordered newest-first.
func sortSemverDescending(versions []string) []string {
	sorted := append([]string(nil), versions...)
	sort.Slice(sorted, func(i, j int) bool {
		return utilities.CompareSemver(sorted[i], sorted[j]) > 0
	})
	return sorted
}

// tagIsOnMain reports whether the named tag's commit is reachable from the
// repo's main branch. The compare URL is compare/{tag}...main (base=tag,
// head=main), so "ahead" means main is ahead of the tag, i.e. the tag is an
// ancestor of main and therefore on it. "behind" is the inverse (the tag has
// commits main lacks), and "diverged" means they share no linear history.
func tagIsOnMain(f *common.Fetcher, owner, repo, tag string) bool {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/compare/%s...main", owner, repo, tag)
	data, err := f.FetchBytes(url)
	if err != nil {
		// An unreachable compare is not evidence the tag is off-main;
		// fail closed to the next candidate rather than guessing.
		return false
	}
	var compare struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(data, &compare); err != nil {
		return false
	}
	return compare.Status == "ahead" || compare.Status == "identical"
}

// GitOverrideResolve builds the resolver for a bazel-module dependency whose
// Source is a GitHub git remote: it walks the repo's tag pages, filters
// semver tags, and reports the newest one whose commit is on main.
func GitOverrideResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		owner, repo, ok := GitHubRemoteOwnerRepo(dep.Source)
		if !ok {
			return common.VersionInfo{Err: errors.New("git_override remote is not a GitHub repo: " + dep.Source)}
		}
		var versions []string
		for page := 1; page <= gitOverrideMaxPages; page++ {
			url := fmt.Sprintf("https://api.github.com/repos/%s/%s/tags?per_page=%d&page=%d",
				owner, repo, gitOverridePerPage, page)
			data, err := f.FetchBytes(url)
			if err != nil {
				return common.VersionInfo{Err: err}
			}
			pageVersions, pageSize, err := parseGitOverrideTags(data)
			if err != nil {
				return common.VersionInfo{Err: err}
			}
			versions = append(versions, pageVersions...)
			if pageSize < gitOverridePerPage {
				break
			}
		}
		if len(versions) == 0 {
			return common.VersionInfo{Err: errors.New("GitHub repo " + owner + "/" + repo + " has no semver tags")}
		}
		// Walk the newest semver tags, newest first, and report the first
		// one whose commit is reachable from main.
		descending := sortSemverDescending(versions)
		for i, version := range descending {
			if i >= gitOverrideMaxCompares {
				break
			}
			if tagIsOnMain(f, owner, repo, "v"+version) {
				return common.VersionInfo{Version: version}
			}
		}
		return common.VersionInfo{Err: fmt.Errorf("no semver tag on main among the %d newest tags of %s/%s",
			min(len(descending), gitOverrideMaxCompares), owner, repo)}
	}
}
