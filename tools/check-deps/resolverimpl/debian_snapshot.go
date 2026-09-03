package resolverimpl

import (
	"strings"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// snapshot.debian.org informational client. Debian source pins carry an exact
// snapshot timestamp (20260824T082821Z); this is a T3 informational check that
// reports when a newer snapshot exists, it never drives an update decision.
// The timestamp pattern lives in utilities behind the
// ExtractSnapshotTs/ExtractSnapshotTsAll accessors (the regexp is private)
// because the extractor side (extractorimpl's parseAPTSourcesList) matches the
// same pattern and cannot import this package.

func parseDebianSnapshotListing(data []byte) []string {
	return utilities.ExtractSnapshotTsAll(string(data))
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
	// exactly chronological.
	latest, err := latestOf(timestamps, strings.Compare)
	if err != nil {
		return ""
	}
	return latest
}
