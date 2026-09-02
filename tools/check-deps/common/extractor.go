package common

// Extractor reads the source file (or directory) it owns under the repo root
// and returns the dependencies found plus any entries that could not be
// extracted. Extractors are the only place that touches the filesystem for
// their own source; parsing itself is delegated to pure functions.
type Extractor func(root string) ([]Dependency, []ExtractionUnknown)
