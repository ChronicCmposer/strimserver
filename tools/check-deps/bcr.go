package main

import (
	"encoding/json"
	"errors"
)

// BCR (Bazel Central Registry) client. Every bazel-module dependency (rules_go,
// gazelle, platforms, ...) resolves its latest non-yanked version from
// metadata.json.

type bcrMetadata struct {
	Versions []string          `json:"versions"`
	Yanked   map[string]string `json:"yanked_versions"`
}

// parseBCRMetadata decodes a BCR metadata.json into its version list and yanked
// map. Pure: takes the raw body and returns typed data.
func parseBCRMetadata(data []byte) (versions []string, yanked map[string]string, err error) {
	var meta bcrMetadata
	if err := json.Unmarshal(data, &meta); err != nil {
		return nil, nil, err
	}
	return meta.Versions, meta.Yanked, nil
}

// latestNonYanked returns the highest version in versions that is not present
// in the yanked map.
func latestNonYanked(versions []string, yanked map[string]string) (string, error) {
	if len(versions) == 0 {
		return "", errors.New("BCR metadata lists no versions")
	}
	latest := ""
	for _, v := range versions {
		if _, isYanked := yanked[v]; isYanked {
			continue
		}
		if latest == "" || compareSemver(v, latest) > 0 {
			latest = v
		}
	}
	if latest == "" {
		return "", errors.New("BCR lists only yanked versions")
	}
	return latest, nil
}

// bcrResolve fetches the BCR metadata for dep.Name and reports the latest
// non-yanked version, flagging a current pin that itself has been yanked as an
// informational note (never a failure).
func bcrResolve(dep dependency) versionInfo {
	data, err := fetchBytes("https://bcr.bazel.build/modules/" + dep.Name + "/metadata.json")
	if err != nil {
		return versionInfo{err: err}
	}
	versions, yanked, err := parseBCRMetadata(data)
	if err != nil {
		return versionInfo{err: err}
	}
	vi := versionInfo{}
	if _, isYanked := yanked[dep.Version]; isYanked {
		vi.infos = append(vi.infos, "current version "+dep.Version+" is yanked in BCR")
	}
	latest, err := latestNonYanked(versions, yanked)
	if err != nil {
		vi.err = err
		return vi
	}
	vi.version = latest
	return vi
}
