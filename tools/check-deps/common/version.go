package common

// VersionInfo is the pure datum a resolver produces: the latest upstream
// version, an optional release date, informational notes, and the error when
// resolution failed (never fatal, always surfaced as "unknown"). The fields
// are exported because resolvers construct this value directly; Classify
// treats it as an untrusted boundary input and clones the slice before
// storing it.
type VersionInfo struct {
	// Version is the latest/wanted version ("" when there is none to compare).
	Version string
	// Date is an optional upstream release date.
	Date string
	// Infos are informational notes (yanked, deprecated, staleness, exemptions).
	Infos []string
	// Err is the resolution failure; nil means success.
	Err error
}
