package main

import (
	"regexp"
	"strings"
)

// scanCallArgs returns the argument text of every call to callName in content,
// e.g. "http_archive" or "apt.sources_list". Parentheses are balanced so a
// nested call inside an argument (like exports_files([...]) inside
// build_file_content) does not truncate the match at the first ")". A match
// whose preceding character is a word character is skipped, so searching for
// "http_archive" never matches the s3_http_archive/s3_http_file own-pipeline
// rules.
func scanCallArgs(content, callName string) []string {
	var args []string
	needle := callName + "("
	for {
		start := strings.Index(content, needle)
		if start < 0 {
			return args
		}
		if start > 0 && isWordChar(content[start-1]) {
			content = content[start+len(callName):]
			continue
		}
		depth := 0
		end := -1
	balanceScan:
		for i := start + len(callName); i < len(content); i++ {
			switch content[i] {
			case '(':
				depth++
			case ')':
				depth--
				if depth == 0 {
					end = i
					break balanceScan
				}
			}
		}
		if end < 0 {
			// Unbalanced call; stop scanning rather than loop forever.
			return args
		}
		args = append(args, content[start+len(callName)+1:end])
		content = content[end+1:]
	}
}

func isWordChar(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

// attrValue extracts the value of a string attribute from a Starlark call's
// argument text, e.g. attrValue(`name = "alpine"`, "name") == "alpine".
func attrValue(args, key string) string {
	re := regexp.MustCompile(`(?m)\b` + regexp.QuoteMeta(key) + `\s*=\s*"([^"]+)"`)
	if m := re.FindStringSubmatch(args); m != nil {
		return m[1]
	}
	return ""
}

var (
	semverRe       = regexp.MustCompile(`[0-9]+\.[0-9]+\.[0-9]+`)
	urlsAttrRe     = regexp.MustCompile(`urls\s*=\s*\["([^"]+)"`)
	snapshotRe     = regexp.MustCompile(`[0-9]{8}T[0-9]{6}Z`)
	iperfVersionRe = regexp.MustCompile(`iperf3-([0-9][0-9.]*-r[0-9]+)\.apk`)
	alpineBranchRe = regexp.MustCompile(`alpine/v([0-9.]+)/`)
	digestRe       = regexp.MustCompile(`sha256:[0-9a-f]{64}`)
)

// extractModuleBazel reads MODULE.bazel at the repo root.
func extractModuleBazel(root string) ([]dependency, []unknown) {
	return readAndParse(root, "MODULE.bazel", parseModuleBazel)
}

// parseModuleBazel extracts every pinned dependency declared in MODULE.bazel:
// bazel_dep module registry pins, single_version_override module version pins,
// http_archive/http_file downloads (golangci-lint, mediamtx, iperf3), the
// apt.sources_list Debian snapshot, and the digest-pinned oci.pull base image.
// Self-published s3_http_archive/s3_http_file artifacts are deliberately not
// extracted: they are governed by the repo's own publish pipeline.
func parseModuleBazel(data []byte, file string) ([]dependency, []unknown) {
	content := string(data)
	var deps []dependency
	var unknowns []unknown

	for _, args := range scanCallArgs(content, "bazel_dep") {
		name := attrValue(args, "name")
		version := attrValue(args, "version")
		if name == "" || version == "" {
			unknowns = append(unknowns, unknown{File: file, Reason: "bazel_dep without name or version: " + args})
			continue
		}
		deps = append(deps, dependency{
			Category: "bazel-module",
			Name:     name,
			Version:  version,
			File:     file,
		})
	}

	for _, args := range scanCallArgs(content, "single_version_override") {
		name := attrValue(args, "module_name")
		version := attrValue(args, "version")
		if name == "" || version == "" {
			unknowns = append(unknowns, unknown{File: file, Reason: "single_version_override without module_name or version: " + args})
			continue
		}
		deps = append(deps, dependency{
			Category: "bazel-module",
			Name:     name,
			Version:  version,
			File:     file,
			Note:     "pinned by single_version_override",
		})
	}

	for _, args := range scanCallArgs(content, "http_archive") {
		name := attrValue(args, "name")
		version := semverRe.FindString(args)
		if name == "" || version == "" {
			unknowns = append(unknowns, unknown{File: file, Reason: "http_archive without name or a version in its url/strip_prefix: " + args})
			continue
		}
		deps = append(deps, dependency{
			Category: "tool-binary",
			Name:     name,
			Version:  version,
			Source:   attrValue(args, "url"),
			File:     file,
		})
	}

	for _, args := range scanCallArgs(content, "http_file") {
		name := attrValue(args, "name")
		url := ""
		if m := urlsAttrRe.FindStringSubmatch(args); m != nil {
			url = m[1]
		}
		version := ""
		if url != "" {
			if m := iperfVersionRe.FindStringSubmatch(url); m != nil {
				version = m[1]
			}
		}
		if name == "" || version == "" {
			unknowns = append(unknowns, unknown{File: file, Reason: "http_file without name or an iperf3 version in its urls: " + args})
			continue
		}
		note := ""
		if m := alpineBranchRe.FindStringSubmatch(url); m != nil {
			note = "alpine v" + m[1] + " branch"
		}
		deps = append(deps, dependency{
			Category: "runtime",
			Name:     "iperf3",
			Version:  version,
			Source:   url,
			File:     file,
			Note:     note,
		})
	}

	if args := scanCallArgs(content, "apt.sources_list"); len(args) > 0 {
		snapshot := snapshotRe.FindString(args[0])
		if snapshot == "" {
			unknowns = append(unknowns, unknown{File: file, Reason: "apt.sources_list without a Debian snapshot timestamp in its uris"})
		} else {
			deps = append(deps, dependency{
				Category: "base-image",
				Name:     "debian",
				Version:  snapshot,
				Source:   "https://snapshot.debian.org/archive/debian",
				File:     file,
				Note:     "apt.sources_list snapshot",
			})
		}
	}

	for _, args := range scanCallArgs(content, "oci.pull") {
		name := attrValue(args, "name")
		digest := digestRe.FindString(args)
		if name == "" || digest == "" {
			unknowns = append(unknowns, unknown{File: file, Reason: "oci.pull without name or a sha256 digest pin: " + args})
			continue
		}
		image := attrValue(args, "image")
		deps = append(deps, dependency{
			Category: "base-image",
			Name:     name,
			Version:  "", // digest-only pins carry no tag reference to compare
			Source:   image + " @ " + digest,
			File:     file,
			Note:     "digest-pinned",
		})
	}

	return deps, unknowns
}
