package resolverimpl

import (
	"errors"
	"fmt"
	"strings"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// The containerd API protos are released as SUBTREE tags (api/v1.12.0) on the
// main containerd/containerd repo, alongside whole-repo v2.x tags. The generic
// githubDep takes tags[0] (a whole-repo tag), which is wrong here, so this
// resolver lists tags and filters the api/v* subtree.
const (
	containerdAPIOwner    = "containerd"
	containerdAPIRepo     = "containerd"
	containerdAPIPrefix   = "api/v"
	containerdAPIPerPage  = 100
	containerdAPIMaxPages = 10
)

// parseContainerdAPITags parses one GitHub tags page and returns the api/v*
// versions it carries (prefix stripped) plus the page's total tag count, which
// the pagination walk uses to detect the last page.
func parseContainerdAPITags(data []byte) (apiVersions []string, pageSize int, err error) {
	names, err := parseGitHubTags(data)
	if err != nil {
		return nil, 0, err
	}
	for _, name := range names {
		if version, ok := strings.CutPrefix(name, containerdAPIPrefix); ok {
			apiVersions = append(apiVersions, version)
		}
	}
	return apiVersions, len(names), nil
}

// latestContainerdAPIVersion returns the newest api/v* version per semver, or a
// descriptive error when the subtree yielded nothing.
func latestContainerdAPIVersion(versions []string) (string, error) {
	if len(versions) == 0 {
		return "", errors.New("containerd repo has no api/v* tags")
	}
	return latestOf(versions, utilities.CompareSemver)
}

// ContainerdAPIResolve builds the containerd api-subtree resolver: it walks the
// repo's tag pages, filters api/v*, and reports the newest.
func ContainerdAPIResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		var versions []string
		for page := 1; page <= containerdAPIMaxPages; page++ {
			url := fmt.Sprintf("https://api.github.com/repos/%s/%s/tags?per_page=%d&page=%d",
				containerdAPIOwner, containerdAPIRepo, containerdAPIPerPage, page)
			data, err := f.FetchBytes(url)
			if err != nil {
				return common.VersionInfo{Err: err}
			}
			pageVersions, pageSize, err := parseContainerdAPITags(data)
			if err != nil {
				return common.VersionInfo{Err: err}
			}
			versions = append(versions, pageVersions...)
			if pageSize < containerdAPIPerPage {
				break
			}
		}
		version, err := latestContainerdAPIVersion(versions)
		if err != nil {
			return common.VersionInfo{Err: err}
		}
		return common.VersionInfo{Version: version}
	}
}
