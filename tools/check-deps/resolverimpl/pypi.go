package resolverimpl

import (
	"encoding/json"
	"errors"

	"strimserver-check-deps/common"
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

// parsePyPIVersionAndYanked decodes a PyPI JSON body once and returns the
// latest release version plus whether the given current version is flagged
// yanked. A single decode serves both answers, so the resolver never
// unmarshals the same body twice. A malformed body or a missing info.version
// is an error; yanked is informational and simply false when the version has
// no release entry.
func parsePyPIVersionAndYanked(data []byte, currentVersion string) (latest string, yanked bool, err error) {
	var resp pypiResponse
	if err := json.Unmarshal(data, &resp); err != nil {
		return "", false, err
	}
	if resp.Info.Version == "" {
		return "", false, errors.New("PyPI response has no info.version")
	}
	for _, rel := range resp.Releases[currentVersion] {
		if rel.Yanked {
			return resp.Info.Version, true, nil
		}
	}
	return resp.Info.Version, false, nil
}

// PypiResolve builds a resolver that fetches the latest version of dep.Name
// from PyPI, flagging a yanked current pin as an informational note. The parse
// closure captures the yanked flag for the note, so the fetch/parse error
// guards live in the shared fetchAndParse helper and only the note stays
// explicit.
func PypiResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		var yanked bool
		vi := fetchAndParse(f, "https://pypi.org/pypi/"+dep.Name+"/json", func(data []byte) (string, error) {
			version, isYanked, err := parsePyPIVersionAndYanked(data, dep.Version)
			yanked = isYanked
			return version, err
		})
		if yanked {
			vi.Infos = append(vi.Infos, "current version "+dep.Version+" is yanked on PyPI")
		}
		return vi
	}
}
