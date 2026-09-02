package main

import (
	"encoding/json"
	"errors"
)

// PyPI JSON client. Used for the provisioned distlib wheel (0.4.3).

type pypiInfo struct {
	Version string `json:"version"`
}

type pypiResponse struct {
	Info     pypiInfo                 `json:"info"`
	Releases map[string][]pypiRelease `json:"releases"`
}

type pypiRelease struct {
	Yanked bool `json:"yanked"`
}

// parsePyPI decodes a PyPI JSON body and returns the latest release version.
func parsePyPI(data []byte) (string, error) {
	var resp pypiResponse
	if err := json.Unmarshal(data, &resp); err != nil {
		return "", err
	}
	if resp.Info.Version == "" {
		return "", errors.New("PyPI response has no info.version")
	}
	return resp.Info.Version, nil
}

// parsePyPIYanked reports whether a specific release version is flagged yanked
// on PyPI. Yanked is an informational note, never a resolution failure.
func parsePyPIYanked(data []byte, version string) (bool, error) {
	var resp pypiResponse
	if err := json.Unmarshal(data, &resp); err != nil {
		return false, err
	}
	for _, rel := range resp.Releases[version] {
		if rel.Yanked {
			return true, nil
		}
	}
	return false, nil
}

// pypiResolve fetches the latest version of dep.Name from PyPI, flagging a
// yanked current pin as an informational note.
func pypiResolve(dep dependency) versionInfo {
	data, err := fetchBytes("https://pypi.org/pypi/" + dep.Name + "/json")
	if err != nil {
		return versionInfo{err: err}
	}
	version, err := parsePyPI(data)
	if err != nil {
		return versionInfo{err: err}
	}
	vi := versionInfo{version: version}
	if yanked, err := parsePyPIYanked(data, dep.Version); err == nil && yanked {
		vi.infos = append(vi.infos, "current version "+dep.Version+" is yanked on PyPI")
	}
	return vi
}
