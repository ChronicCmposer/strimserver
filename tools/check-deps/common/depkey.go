package common

import "strings"

// DepKey is the single identity tuple for a dependency: (category, name,
// source, version). It is the shared key both dedupe and the cache use, so a
// "deduplicated" set and a "cached" set always mean the same thing.
type DepKey [4]string

// depKeySep is the unit separator (\x1f) that joins the identity fields into
// the stable JSON cache key. It cannot appear in a version string, so the
// joined key is unambiguous and deterministic.
const depKeySep = "\x1f"

// String renders the identity as the stable cache key: category, name, source,
// and version joined by depKeySep. Field order is deliberate and fixed, so the
// string form is byte-identical for identical dependencies.
func (k DepKey) String() string {
	return strings.Join(k[:], depKeySep)
}

// DepIdentity returns dep's identity key; see DepKey.
func DepIdentity(dep Dependency) DepKey {
	return DepKey{dep.Category, dep.Name, dep.Source, dep.Version}
}
