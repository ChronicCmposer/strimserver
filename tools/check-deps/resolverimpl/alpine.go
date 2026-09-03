package resolverimpl

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"strings"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// Alpine APKINDEX client. iperf3 is pinned from a specific Alpine branch
// (v3.23); the pinned branch's APKINDEX gives the "wanted" version while the
// latest-stable branch (v3.24) is an informational staleness note.

// parseAPKIndex parses the APKINDEX text format (P: name / V: version blocks
// separated by blank lines) into a name -> version map. Pure: takes the raw
// index text and returns typed data.
func parseAPKIndex(data []byte) (map[string]string, error) {
	pkgs := make(map[string]string)
	var name, version string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimRight(line, "\r")
		switch {
		case strings.HasPrefix(line, "P:"):
			name = strings.TrimSpace(strings.TrimPrefix(line, "P:"))
		case strings.HasPrefix(line, "V:"):
			version = strings.TrimSpace(strings.TrimPrefix(line, "V:"))
			if name != "" {
				pkgs[name] = version
			}
		case line == "":
			name, version = "", ""
		}
	}
	if len(pkgs) == 0 {
		return nil, errors.New("APKINDEX contains no P:/V: blocks")
	}
	return pkgs, nil
}

// fetchAPKIndexVersion downloads and extracts the APKINDEX for one Alpine
// branch and returns the version of pkg within it.
func fetchAPKIndexVersion(branch, pkg string, f *common.Fetcher) (string, error) {
	url := fmt.Sprintf("https://dl-cdn.alpinelinux.org/alpine/%s/main/x86_64/APKINDEX.tar.gz", branch)
	data, err := f.FetchBytes(url)
	if err != nil {
		return "", err
	}
	gz, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return "", err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	var index []byte
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
		if hdr.Name == "APKINDEX" {
			index, err = io.ReadAll(tr)
			if err != nil {
				return "", err
			}
			break
		}
	}
	if index == nil {
		return "", errors.New("no APKINDEX entry in " + url)
	}
	pkgs, err := parseAPKIndex(index)
	if err != nil {
		return "", err
	}
	version, ok := pkgs[pkg]
	if !ok {
		return "", errors.New("package " + pkg + " not found in Alpine branch " + branch)
	}
	return version, nil
}

// alpineLatestStableBranch is the newest Alpine stable branch used for the
// iperf3 staleness note. Bump this when Alpine releases a new stable branch.
const alpineLatestStableBranch = "v3.24"

// alpinePinnedDefaultBranch is the Alpine branch the repo's iperf3 apk is
// pinned from when the extractor recorded no structured branch.
const alpinePinnedDefaultBranch = "v3.23"

// AlpineResolve builds a resolver for the iperf3 pin: the version in the
// pinned branch drives the update check, and a newer iperf3 on the
// latest-stable branch is recorded as informational branch staleness. The
// pinned branch comes from the structured dependency.Branch field, falling
// back to the default v3.23 when the extractor did not record one.
func AlpineResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		branch := dep.Branch
		if branch == "" {
			branch = alpinePinnedDefaultBranch
		}
		vi := common.VersionInfo{}
		pinned, err := fetchAPKIndexVersion(branch, "iperf3", f)
		if err != nil {
			vi.Err = err
			return vi
		}
		vi.Version = pinned
		if stable, err := fetchAPKIndexVersion(alpineLatestStableBranch, "iperf3", f); err == nil {
			if utilities.CompareSemver(stable, pinned) > 0 {
				vi.Infos = append(vi.Infos,
					"latest-stable alpine "+alpineLatestStableBranch+" has iperf3 "+stable+" (branch staleness, T3 informational)")
			}
		}
		return vi
	}
}
