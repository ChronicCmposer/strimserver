package main

import (
	"regexp"
)

// snapshot.debian.org informational client. Debian source pins carry an exact
// snapshot timestamp (20260824T082821Z); this is a T3 informational check that
// reports when a newer snapshot exists, it never drives an update decision.

var snapshotTsRe = regexp.MustCompile(`[0-9]{8}T[0-9]{6}Z`)

// parseDebianSnapshotListing extracts every snapshot timestamp from a
// snapshot.debian.org listing body. Pure: takes the HTML body and returns
// timestamp strings.
func parseDebianSnapshotListing(data []byte) []string {
	return snapshotTsRe.FindAllString(string(data), -1)
}

// newestDebianSnapshot best-effort fetches the newest snapshot timestamp from
// the archive listing, returning "" when the listing is unreachable or carries
// no timestamps.
func newestDebianSnapshot() string {
	data, err := fetchBytes("https://snapshot.debian.org/archive/debian/")
	if err != nil {
		return ""
	}
	timestamps := parseDebianSnapshotListing(data)
	if len(timestamps) == 0 {
		return ""
	}
	newest := timestamps[0]
	for _, ts := range timestamps[1:] {
		if ts > newest {
			newest = ts
		}
	}
	return newest
}
