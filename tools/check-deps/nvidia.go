package main

import (
	"errors"
	"regexp"
)

// NVIDIA CUDA redistributable client. CUDA has no "latest" endpoint, so the
// HTML directory listing of redistrib manifests is scraped and the newest
// redistrib_X.Y.Z.json wins via a sort -V style (numeric-aware) compare.

var redistFileRe = regexp.MustCompile(`redistrib_([0-9]+\.[0-9]+\.[0-9]+)\.json`)

// parseNvidiaRedistListing extracts every CUDA version from the redist
// directory listing. Pure: takes the HTML body and returns version strings.
func parseNvidiaRedistListing(data []byte) ([]string, error) {
	var versions []string
	for _, m := range redistFileRe.FindAllStringSubmatch(string(data), -1) {
		versions = append(versions, m[1])
	}
	if len(versions) == 0 {
		return nil, errors.New("no redistrib manifests found in NVIDIA listing")
	}
	return versions, nil
}

// latestNVVersion returns the highest CUDA version using the chunked,
// numeric-aware compare (13.0.2 sorts after 12.4.1).
func latestNVVersion(versions []string) (string, error) {
	if len(versions) == 0 {
		return "", errors.New("no CUDA versions to compare")
	}
	latest := versions[0]
	for _, v := range versions[1:] {
		if compareChunks(v, latest) > 0 {
			latest = v
		}
	}
	return latest, nil
}

// nvidiaResolve fetches the CUDA redist listing and reports the newest
// manifest version.
func nvidiaResolve(dep dependency) versionInfo {
	data, err := fetchBytes("https://developer.download.nvidia.com/compute/cuda/redist/")
	if err != nil {
		return versionInfo{err: err}
	}
	versions, err := parseNvidiaRedistListing(data)
	if err != nil {
		return versionInfo{err: err}
	}
	latest, err := latestNVVersion(versions)
	if err != nil {
		return versionInfo{err: err}
	}
	return versionInfo{version: latest}
}
