package resolverimpl

import (
	"errors"
	"regexp"

	"strimserver-check-deps/common"
)

// NVIDIA CUDA redistributable client. CUDA has no "latest" endpoint, so the
// HTML directory listing of redistrib manifests is scraped and the newest
// redistrib_X.Y.Z.json wins via a sort -V style (numeric-aware) compare.

var redistFileRe = regexp.MustCompile(`redistrib_([0-9]+\.[0-9]+\.[0-9]+)\.json`)

// parseNvidiaRedistListing extracts every CUDA version from the redist
// directory listing. Pure: takes the HTML body and returns version strings.
func parseNvidiaRedistListing(data []byte) ([]string, error) {
	versions := parseListing(data, redistFileRe)
	if len(versions) == 0 {
		return nil, errors.New("no redistrib manifests found in NVIDIA listing")
	}
	return versions, nil
}

// NvidiaResolve builds a resolver that fetches the CUDA redist listing and
// reports the newest manifest version.
func NvidiaResolve(f *common.Fetcher) common.ResolverFunc {
	return func(dep common.Dependency) common.VersionInfo {
		return fetchAndParse(f, "https://developer.download.nvidia.com/compute/cuda/redist/", func(data []byte) (string, error) {
			versions, err := parseNvidiaRedistListing(data)
			if err != nil {
				return "", err
			}
			// CompareChunks is the sort -V style numeric-aware compare: 13.0.2
			// sorts after 12.4.1.
			return latestOf(versions, common.CompareChunks)
		})
	}
}
