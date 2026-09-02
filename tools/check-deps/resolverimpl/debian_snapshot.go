package resolverimpl

import (
	"strings"

	"strimserver-check-deps/common"
)

// snapshot.debian.org informational client. Debian source pins carry an exact
// snapshot timestamp (20260824T082821Z); this is a T3 informational check that
// reports when a newer snapshot exists, it never drives an update decision.
// The timestamp pattern lives in common as SnapshotTsRe because the extractor
// side (parseAPTSourcesList, Stage 3) matches the same pattern and cannot
// import this package.

// parseDebianSnapshotListing extracts every snapshot timestamp from a
// snapshot.debian.org listing body. Pure: takes the HTML body and returns
// timestamp strings.
func parseDebianSnapshotListing(data []byte) []string {
	return common.SnapshotTsRe.FindAllString(string(data), -1)
}

// newestDebianSnapshot best-effort fetches the newest snapshot timestamp from
// the archive listing, returning "" when the listing is unreachable or carries
// no timestamps.
func newestDebianSnapshot(f *common.Fetcher) string {
	data, err := f.FetchBytes("https://snapshot.debian.org/archive/debian/")
	if err != nil {
		return ""
	}
	timestamps := parseDebianSnapshotListing(data)
	// Fixed-width YYYYMMDDTHHMMSSZ timestamps order lexicographically, which is
	// exactly chronological. latestOf errors on an empty list; best-effort here
	// returns "" instead.
	latest, err := latestOf(timestamps, strings.Compare)
	if err != nil {
		return ""
	}
	return latest
}
