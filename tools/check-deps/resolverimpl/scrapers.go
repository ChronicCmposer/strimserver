package resolverimpl

import (
	"errors"
	"regexp"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// HTML directory-listing scrapers. Every scraper is two pieces: a PURE parser
// ([]byte -> []string of versions, unit-tested with inline fixtures) and a
// network wrapper that fetches the listing and picks the newest version.

var (
	qemuTarRe    = regexp.MustCompile(`qemu-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.xz`)
	opensshTarRe = regexp.MustCompile(`openssh-([0-9]+(?:\.[0-9]+)+p[0-9]+)\.tar\.gz`)
	m4TarRe      = regexp.MustCompile(`m4-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz`)
	ffmpegTarRe  = regexp.MustCompile(`ffmpeg-([0-9]+\.[0-9]+(?:\.[0-9]+)?)\.tar\.`)
)

func parseListing(data []byte, re *regexp.Regexp) []string {
	var versions []string
	for _, m := range re.FindAllStringSubmatch(string(data), -1) {
		versions = append(versions, m[1])
	}
	return versions
}

// latestOf returns the greatest version per cmp, or an error when versions is
// empty. cmp must return > 0 when a sorts after b.
func latestOf(versions []string, cmp func(a, b string) int) (string, error) {
	if len(versions) == 0 {
		return "", errors.New("no versions to compare")
	}
	latest := versions[0]
	for _, v := range versions[1:] {
		if cmp(v, latest) > 0 {
			latest = v
		}
	}
	return latest, nil
}

func QemuScrapeResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return scrapeListing("https://download.qemu.org/", qemuTarRe, f)
	}
}

func OpensshScrapeResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return scrapeListing("https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/", opensshTarRe, f)
	}
}

func M4ScrapeResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return scrapeListing("https://ftp.gnu.org/gnu/m4/?C=M;O=D", m4TarRe, f)
	}
}

func FfmpegScrapeResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return scrapeListing("https://ffmpeg.org/releases/", ffmpegTarRe, f)
	}
}

// fetchAndParse fetches url through f and runs parse over the body, collapsing
// the fetch-then-parse-then-wrap pattern shared by the resolvers into one
// place: a fetch or parse failure becomes versionInfo{err:...}, and a parsed
// version string becomes versionInfo{version: ...}. Resolvers with bespoke
// post-parse logic (yanked notes, release dates, staleness) pass a parse
// closure that captures what they need and keep that logic explicit after the
// call, so no resolver hand-rolls the fetch/parse error guards.
func fetchAndParse(f *common.Fetcher, url string, parse func([]byte) (string, error)) common.VersionInfo {
	data, err := f.FetchBytes(url)
	if err != nil {
		return common.VersionInfo{Err: err}
	}
	version, err := parse(data)
	if err != nil {
		return common.VersionInfo{Err: err}
	}
	return common.VersionInfo{Version: version}
}

// scrapeListing fetches url through the fetcher, runs parseListing over the
// body, and returns the newest version as a common.VersionInfo.
func scrapeListing(url string, re *regexp.Regexp, f *common.Fetcher) common.VersionInfo {
	return fetchAndParse(f, url, func(data []byte) (string, error) {
		return latestOf(parseListing(data, re), utilities.CompareSemver)
	})
}
