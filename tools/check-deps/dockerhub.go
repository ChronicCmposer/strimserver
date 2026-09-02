package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
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

// parseDockerHubTags decodes one page of the tags API.
func parseDockerHubTags(data []byte) ([]dockerTag, error) {
	var page dockerHubTagsPage
	if err := json.Unmarshal(data, &page); err != nil {
		return nil, err
	}
	return page.Results, nil
}

// fetchDockerHubTags walks the tag pages for ns/repo until a page returns
// fewer than pageSize results or maxPages is reached.
func fetchDockerHubTags(ns, repo string, maxPages int) ([]dockerTag, error) {
	const pageSize = 100
	var all []dockerTag
	for page := 1; page <= maxPages; page++ {
		url := fmt.Sprintf("https://hub.docker.com/v2/repositories/%s/%s/tags?page=%d&page_size=%d", ns, repo, page, pageSize)
		data, err := fetchBytes(url)
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

var trixieDateTagRe = regexp.MustCompile(`^trixie-([0-9]{8})-slim$`)

// debianResolve resolves the Debian base-image pin: it finds the newest
// trixie-YYYYMMDD-slim tag (a date-tag compare) and, best-effort, notes when
// snapshot.debian.org has moved past the pinned snapshot (T3 informational).
// Docker Hub lists tags newest-first, so the recent trixie date tags sit in
// the first few pages; five pages is plenty and keeps the anonymous rate
// limit happy.
func debianResolve(dep dependency) versionInfo {
	tags, err := fetchDockerHubTags("library", "debian", 5)
	if err != nil {
		return versionInfo{err: err}
	}
	latestDate := ""
	for _, t := range tags {
		m := trixieDateTagRe.FindStringSubmatch(t.Name)
		if m == nil {
			continue
		}
		date := m[1]
		if latestDate == "" || date > latestDate {
			latestDate = date
		}
	}
	vi := versionInfo{}
	if latestDate == "" {
		vi.err = errors.New("no trixie-YYYYMMDD-slim tag found on Docker Hub")
		return vi
	}
	vi.version = latestDate
	if snap := newestDebianSnapshot(); snap != "" {
		if cur := extractDate(dep.Version); cur != "" && snap > cur {
			vi.infos = append(vi.infos,
				"snapshot.debian.org has newer snapshot "+snap+" (T3 informational)")
		}
	}
	return vi
}

// amazonlinuxResolve resolves the amazonlinux base-image pin. The tag is a
// floating year-major (2023), so the classifier reports hygiene; here we just
// confirm the tag still exists upstream.
func amazonlinuxResolve(dep dependency) versionInfo {
	tags, err := fetchDockerHubTags("library", "amazonlinux", 3)
	if err != nil {
		return versionInfo{err: err}
	}
	found := ""
	for _, t := range tags {
		if t.Name == dep.Version {
			found = dep.Version
			break
		}
	}
	vi := versionInfo{version: dep.Version}
	if found == "" {
		vi.infos = append(vi.infos, "tag "+dep.Version+" not found in the first pages of Docker Hub tags; verify")
	} else {
		vi.infos = append(vi.infos, "tag "+dep.Version+" present upstream")
	}
	return vi
}
