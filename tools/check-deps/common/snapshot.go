package common

import "regexp"

// SnapshotTsRe matches a Debian snapshot.debian.org timestamp
// (YYYYMMDDTHHMMSSZ). The pattern is shared by two packages that cannot import
// each other: the resolver side (resolverimpl's newestDebianSnapshot) extracts
// every timestamp from the archive listing, and the extractor side (Stage 3,
// parseAPTSourcesList) pulls a single timestamp out of apt.sources_list uris.
// It therefore lives here, in the one package both sides may import.
var SnapshotTsRe = regexp.MustCompile(`[0-9]{8}T[0-9]{6}Z`)
