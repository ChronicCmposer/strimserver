package common

// Status classifies what action a resolved dependency needs.
type Status string

const (
	// StatusUpdate means a newer upstream version exists and the pin should
	// move forward.
	StatusUpdate Status = "update"
	// StatusUnknown means the latest version could not be determined (a
	// network failure, missing toolchain, or unparseable version). Resolution
	// failures are never fatal: they surface here with a reason.
	StatusUnknown Status = "unknown"
	// StatusOK means the pin is current (or properly pinned with no tag to
	// compare, e.g. a digest).
	StatusOK Status = "ok"
	// StatusHygiene means the pin is valid but floats upstream (a rolling tag
	// or year-major base image); the reviewer should consider a digest or
	// date pin.
	StatusHygiene Status = "hygiene"
)
