package resolverimpl

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// Docker Hub tags client. Used for the Debian trixie date-stamped base image
// (date-tag compare) and the amazonlinux:2023 floating tag (hygiene). The API
// is paginated at 100 tags/page; stop when a page comes back short.

type dockerTag struct {
	Name          string `json:"name"`
	LastUpdated   string `json:"last_updated"`
	TagLastPushed string `json:"tag_last_pushed"`
}

type dockerHubTagsPage struct {
	Results []dockerTag `json:"results"`
}

func parseDockerHubTags(data []byte) ([]dockerTag, error) {
	var page dockerHubTagsPage
	if err := json.Unmarshal(data, &page); err != nil {
		return nil, err
	}
	return page.Results, nil
}

// fetchDockerHubTags walks the tag pages for ns/repo until a page returns
// fewer than pageSize results or maxPages is reached.
func fetchDockerHubTags(ns, repo string, maxPages int, f *common.Fetcher) ([]dockerTag, error) {
	const pageSize = 100
	var all []dockerTag
	for page := 1; page <= maxPages; page++ {
		url := fmt.Sprintf("https://hub.docker.com/v2/repositories/%s/%s/tags?page=%d&page_size=%d", ns, repo, page, pageSize)
		data, err := f.FetchBytes(url)
		if err != nil {
			return nil, err
		}
		tags, err := parseDockerHubTags(data)
		if err != nil {
			return nil, err
		}
		all = append(all, tags...)
		if len(tags) < pageSize {
			break
		}
	}
	return all, nil
}

// newestDockerHubTag walks the library/<repo> tag pages and returns the first
// tag for which match reports ok (Docker Hub lists tags newest-first, so the
// first match is the newest matching tag). ok reports whether a match was
// found; a fetch error is returned as-is.
func newestDockerHubTag(repo string, maxPages int, match func(t dockerTag) bool, f *common.Fetcher) (tag dockerTag, ok bool, err error) {
	tags, err := fetchDockerHubTags("library", repo, maxPages, f)
	if err != nil {
		return dockerTag{}, false, err
	}
	for _, t := range tags {
		if match(t) {
			return t, true, nil
		}
	}
	return dockerTag{}, false, nil
}

var trixieDateTagRe = regexp.MustCompile(`^trixie-([0-9]{8})-slim$`)

// DebianResolve builds a resolver for the Debian base-image pin: it finds the
// newest trixie-YYYYMMDD-slim tag (a date-tag compare) and, best-effort, notes
// when snapshot.debian.org has moved past the pinned snapshot (T3
// informational). Docker Hub lists tags newest-first, so the first
// trixie-YYYYMMDD-slim match is the newest; five pages is plenty and keeps the
// anonymous rate limit happy.
func DebianResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		tag, found, err := newestDockerHubTag("debian", 5, func(t dockerTag) bool {
			return trixieDateTagRe.MatchString(t.Name)
		}, f)
		if err != nil {
			return common.VersionInfo{Err: err}
		}
		vi := common.VersionInfo{}
		if !found {
			vi.Err = errors.New("no trixie-YYYYMMDD-slim tag found on Docker Hub")
			return vi
		}
		vi.Version = utilities.ExtractDate(tag.Name)
		if snap := newestDebianSnapshot(f); snap != "" {
			if cur := utilities.ExtractDate(dep.Version); cur != "" && snap > cur {
				vi.Infos = append(vi.Infos,
					"snapshot.debian.org has newer snapshot "+snap+" (T3 informational)")
			}
		}
		return vi
	}
}

// AmazonlinuxResolve builds a resolver for the amazonlinux base-image pin. The
// tag is a floating year-major (2023), so the classifier reports hygiene; here
// we just confirm the tag still exists upstream by scanning the shared
// newestDockerHubTag helper for an exact name match.
func AmazonlinuxResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		_, found, err := newestDockerHubTag("amazonlinux", 3, func(t dockerTag) bool {
			return t.Name == dep.Version
		}, f)
		if err != nil {
			return common.VersionInfo{Err: err}
		}
		vi := common.VersionInfo{Version: dep.Version}
		if !found {
			vi.Infos = append(vi.Infos, "tag "+dep.Version+" not found in the first pages of Docker Hub tags; verify")
		} else {
			vi.Infos = append(vi.Infos, "tag "+dep.Version+" present upstream")
		}
		return vi
	}
}
