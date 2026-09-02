package main

import (
	"errors"
	"regexp"
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

// parseQemuListing extracts every qemu-X.Y.Z.tar.xz version from download.qemu.org.
func parseQemuListing(data []byte) []string {
	return findAllVersions(data, qemuTarRe)
}

// parseOpenSSHListing extracts every openssh-X.YpZ.tar.gz version from the
// OpenBSD portable directory.
func parseOpenSSHListing(data []byte) []string {
	return findAllVersions(data, opensshTarRe)
}

// parseGnuM4Listing extracts every m4-X.Y.Z.tar.gz version from ftp.gnu.org.
func parseGnuM4Listing(data []byte) []string {
	return findAllVersions(data, m4TarRe)
}

// parseFFmpegListing extracts every ffmpeg-X.Y(.Z) tarball version from
// ffmpeg.org/releases.
func parseFFmpegListing(data []byte) []string {
	return findAllVersions(data, ffmpegTarRe)
}

func findAllVersions(data []byte, re *regexp.Regexp) []string {
	var versions []string
	for _, m := range re.FindAllStringSubmatch(string(data), -1) {
		versions = append(versions, m[1])
	}
	return versions
}

// latestOf returns the highest version in the list via the semver compare.
func latestOf(versions []string) (string, error) {
	if len(versions) == 0 {
		return "", errors.New("no versions found in listing")
	}
	latest := versions[0]
	for _, v := range versions[1:] {
		if compareSemver(v, latest) > 0 {
			latest = v
		}
	}
	return latest, nil
}

func qemuScrapeResolve(dep dependency) versionInfo {
	return scrapeListing("https://download.qemu.org/", parseQemuListing)
}

func opensshScrapeResolve(dep dependency) versionInfo {
	return scrapeListing("https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/", parseOpenSSHListing)
}

func m4ScrapeResolve(dep dependency) versionInfo {
	return scrapeListing("https://ftp.gnu.org/gnu/m4/?C=M;O=D", parseGnuM4Listing)
}

func ffmpegScrapeResolve(dep dependency) versionInfo {
	return scrapeListing("https://ffmpeg.org/releases/", parseFFmpegListing)
}

// scrapeListing fetches url, runs the pure parser, and returns the newest
// version as a versionInfo.
func scrapeListing(url string, parse func([]byte) []string) versionInfo {
	data, err := fetchBytes(url)
	if err != nil {
		return versionInfo{err: err}
	}
	versions := parse(data)
	latest, err := latestOf(versions)
	if err != nil {
		return versionInfo{err: err}
	}
	return versionInfo{version: latest}
}
