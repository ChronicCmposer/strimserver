package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
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
func fetchAPKIndexVersion(branch, pkg string) (string, error) {
	url := fmt.Sprintf("https://dl-cdn.alpinelinux.org/alpine/%s/main/x86_64/APKINDEX.tar.gz", branch)
	data, err := fetchBytes(url)
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

var alpineBranchNoteRe = regexp.MustCompile(`alpine (v[0-9.]+) branch`)

// alpineResolve resolves the iperf3 pin: the version in the pinned branch
// drives the update check, and a newer iperf3 on the latest-stable branch is
// recorded as informational branch staleness.
func alpineResolve(dep dependency) versionInfo {
	branch := "v3.23"
	if m := alpineBranchNoteRe.FindStringSubmatch(dep.Note); m != nil {
		branch = m[1]
	}
	vi := versionInfo{}
	pinned, err := fetchAPKIndexVersion(branch, "iperf3")
	if err != nil {
		vi.err = err
		return vi
	}
	vi.version = pinned
	if stable, err := fetchAPKIndexVersion("v3.24", "iperf3"); err == nil {
		if compareSemver(stable, pinned) > 0 {
			vi.infos = append(vi.infos,
				"latest-stable alpine v3.24 has iperf3 "+stable+" (branch staleness, T3 informational)")
		}
	}
	return vi
}
