package extractorimpl

import (
	"regexp"
	"strings"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// scanCallArgs returns the argument text of every call to callName in content.
// It is a thin alias for scanRepoRule, the canonical repo-rule scanner, kept so
// the many existing call sites and tests keep one name for the same behavior.
func scanCallArgs(content, callName string) []string {
	return scanRepoRule(content, callName)
}

// skipStringOrComment advances past the quoted string or '#' comment that
// starts at s[i]. It is the single source of truth for how both scanCallArgs
// and attrValue treat quoting and comments: a '...' or "..." string honors
// backslash escapes and runs to its closing quote, and a '#' comment runs to
// the end of the line. The returned index is just past the span; when s[i] is
// not a quote or '#', it returns i unchanged. The caller must ensure i <
// len(s).
func skipStringOrComment(s string, i int) int {
	switch c := s[i]; {
	case c == '\'' || c == '"':
		quote := c
		for i++; i < len(s); i++ {
			if s[i] == '\\' {
				i++
			} else if s[i] == quote {
				return i + 1
			}
		}
		return i
	case c == '#':
		for i < len(s) && s[i] != '\n' {
			i++
		}
		if i < len(s) {
			i++
		}
		return i
	default:
		return i
	}
}

func isWordChar(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

// attrValue extracts the value of a string attribute from a Starlark call's
// argument text, e.g. attrValue(`name = "alpine"`, "name") == "alpine". The
// scan is quote/comment-aware through the shared skipStringOrComment, so text
// inside "..." or '...' strings (with backslash escapes) and after '#' comments
// is skipped — a `version = "9.9.9"` nested inside build_file_content is never
// matched. The key is matched as a whole word, so "module_name" never satisfies
// key "name" and "names" never satisfies key "name".
func attrValue(args, key string) string {
	for i := 0; i < len(args); {
		c := args[i]
		if c == '\'' || c == '"' || c == '#' {
			i = skipStringOrComment(args, i)
			continue
		}
		if isWordChar(c) && matchesKeyAt(args, i, key) {
			v, end, ok := valueAfterKey(args, i+len(key))
			if ok {
				return v
			}
			i = end
			continue
		}
		i++
	}
	return ""
}

func matchesKeyAt(args string, i int, key string) bool {
	if i > 0 && isWordChar(args[i-1]) {
		return false
	}
	if len(args)-i < len(key) || args[i:i+len(key)] != key {
		return false
	}
	after := i + len(key)
	return after == len(args) || !isWordChar(args[after])
}

// valueAfterKey parses `\s*=\s*"..."` or `\s*=\s*'...'` starting just past a
// matched key and returns the unescaped quoted value, the index just past the
// closing quote, and whether the assignment parsed. Backslash escapes are
// honored inside either quote style.
func valueAfterKey(args string, i int) (string, int, bool) {
	i = skipAttrSpace(args, i)
	if i >= len(args) || args[i] != '=' {
		return "", i, false
	}
	i = skipAttrSpace(args, i+1)
	if i >= len(args) || (args[i] != '\'' && args[i] != '"') {
		return "", i, false
	}
	quote := args[i]
	var value strings.Builder
	for i++; i < len(args) && args[i] != quote; i++ {
		if args[i] == '\\' && i+1 < len(args) {
			i++
		}
		value.WriteByte(args[i])
	}
	if i >= len(args) {
		return "", i, false // unterminated quoted value
	}
	return value.String(), i + 1, true
}

func skipAttrSpace(args string, i int) int {
	for i < len(args) {
		switch args[i] {
		case ' ', '\t', '\n', '\r':
			i++
		default:
			return i
		}
	}
	return i
}

var (
	semverRe       = regexp.MustCompile(`[0-9]+\.[0-9]+\.[0-9]+`)
	urlsAttrRe     = regexp.MustCompile(`urls\s*=\s*\[["']([^"']+)["']`)
	iperfVersionRe = regexp.MustCompile(`iperf3-([0-9][0-9.]*-r[0-9]+)\.apk`)
	alpineBranchRe = regexp.MustCompile(`alpine/v([0-9.]+)/`)
	digestRe       = regexp.MustCompile(`sha256:[0-9a-f]{64}`)
)

// ExtractModuleBazel reads MODULE.bazel and extracts every pinned dependency.
// It also reads tools/bazel/qemu_x86_64.bzl to resolve the qemu_x86_64 repo
// rule's version default, which the call site does not carry.
func ExtractModuleBazel(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	defaults := repoRuleDefaults{qemuVersion: readQemuRepoRuleDefault(root)}
	return common.ReadAndParse(root, "MODULE.bazel", func(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
		return parseModuleBazelWithDefaults(data, file, defaults)
	})
}

// ExtractModuleBazel must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractModuleBazel

// parseModuleBazel is the pure parser used by tests and callers that have only
// the MODULE.bazel bytes; the qemu repo-rule default is absent, so its call
// fails closed unless parseModuleBazelWithDefaults supplies it.
func parseModuleBazel(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	return parseModuleBazelWithDefaults(data, file, repoRuleDefaults{})
}

// parseModuleBazelWithDefaults extracts every pinned dependency declared in
// MODULE.bazel: bazel_dep module registry pins, single_version_override module
// version pins, http_archive/http_file downloads, the apt.sources_list Debian
// snapshot, the digest-pinned oci.pull base image, and the repo-rule pins
// (tarball_strip_symlinks, deb_extract, amd64_sysroot, apt.install,
// s3_http_archive/s3_http_file, qemu_x86_64) driven by the repoRuleSpecs table.
// Each policy is a pure helper that scans the same content for its own call
// form; the ordered aggregation preserves the original declaration order.
func parseModuleBazelWithDefaults(data []byte, file string, defaults repoRuleDefaults) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	passes := []func(string, string) ([]common.Dependency, []common.ExtractionUnknown){
		parseBazelDep,
		parseSingleVersionOverride,
		parseHTTPArchive,
		parseHTTPFile,
		parseAPTSourcesList,
		parseOCIPull,
		func(content, file string) ([]common.Dependency, []common.ExtractionUnknown) {
			return parseRepoRules(content, file, defaults)
		},
	}
	for _, pass := range passes {
		gotDeps, gotUnknowns := pass(content, file)
		deps, unknowns = common.MergeExtract(deps, unknowns, gotDeps, gotUnknowns)
	}
	return deps, unknowns
}

func parseBazelDep(content, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	for _, args := range scanCallArgs(content, "bazel_dep") {
		name := attrValue(args, "name")
		version := attrValue(args, "version")
		if name == "" || version == "" {
			unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "bazel_dep without name or version: " + args})
			continue
		}
		deps = append(deps, common.Dependency{
			Category: common.CategoryBazelModule,
			Name:     name,
			Version:  version,
			File:     file,
		})
	}
	return deps, unknowns
}

func parseSingleVersionOverride(content, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	for _, args := range scanCallArgs(content, "single_version_override") {
		name := attrValue(args, "module_name")
		version := attrValue(args, "version")
		if name == "" || version == "" {
			unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "single_version_override without module_name or version: " + args})
			continue
		}
		deps = append(deps, common.Dependency{
			Category: common.CategoryBazelModule,
			Name:     name,
			Version:  version,
			File:     file,
			Note:     "pinned by single_version_override",
		})
	}
	return deps, unknowns
}

// parseHTTPArchive extracts the http_archive download pins.
func parseHTTPArchive(content, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	for _, args := range scanCallArgs(content, "http_archive") {
		name := attrValue(args, "name")
		// Version extraction is deterministic: consult one structured
		// attribute at a time, in priority order — the version attribute,
		// then a semver inside strip_prefix, then a semver inside url, then a
		// two-part x.y inside url (protoc ships 36.2, not x.y.z). Scraping
		// the whole argument text first could match an unrelated x.y.z (e.g.
		// inside build_file_content), so each step reads the value of a single
		// known attribute and only falls through when it yields no version.
		version := attrValue(args, "version")
		if version == "" {
			version = semverRe.FindString(attrValue(args, "strip_prefix"))
		}
		if version == "" {
			version = semverRe.FindString(attrValue(args, "url"))
		}
		if version == "" {
			version = firstCapture(twoPartCaptureRe, attrValue(args, "url"))
		}
		sha := attrValue(args, "sha256")
		if name == "" || (version == "" && sha == "") {
			unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "http_archive without name or a determinable version or sha256 (version/strip_prefix/url/sha256): " + args})
			continue
		}
		deps = append(deps, common.Dependency{
			Category: common.CategoryToolBinary,
			Name:     name,
			Version:  version,
			Source:   attrValue(args, "url"),
			File:     file,
			Note:     noteWithSHA256("", sha),
			Role:     integrityRoleForMissingVersion(version, sha),
		})
	}
	return deps, unknowns
}

// integrityRoleForMissingVersion returns RoleIntegrity for a sha-only pin (a
// hash with no version to compare) and the empty default role otherwise, so a
// hash-pinned artifact without an upstream version is still emitted rather than
// failed.
func integrityRoleForMissingVersion(version, sha string) string {
	if version == "" && sha != "" {
		return common.RoleIntegrity
	}
	return ""
}

// parseHTTPFile extracts the http_file download pins (the iperf3 apk).
func parseHTTPFile(content, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
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
		if version == "" {
			version = firstCapture(twoPartCaptureRe, url)
		}
		sha := attrValue(args, "sha256")
		if name == "" || (version == "" && sha == "") {
			unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "http_file without name or a determinable version or sha256 in its urls: " + args})
			continue
		}
		note := ""
		branch := ""
		if m := alpineBranchRe.FindStringSubmatch(url); m != nil {
			note = "alpine v" + m[1] + " branch"
			branch = "v" + m[1]
		}
		deps = append(deps, common.Dependency{
			Category: common.CategoryRuntime,
			Name:     "iperf3",
			Version:  version,
			Source:   url,
			File:     file,
			Note:     noteWithSHA256(note, sha),
			Branch:   branch,
			Role:     integrityRoleForMissingVersion(version, sha),
		})
	}
	return deps, unknowns
}

// parseAPTSourcesList extracts the Debian snapshot pin from apt.sources_list.
func parseAPTSourcesList(content, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	if args := scanCallArgs(content, "apt.sources_list"); len(args) > 0 {
		snapshot := utilities.ExtractSnapshotTs(args[0])
		if snapshot == "" {
			unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "apt.sources_list without a Debian snapshot timestamp in its uris"})
		} else {
			deps = append(deps, common.Dependency{
				Category: common.CategoryBaseImage,
				Name:     "debian",
				Version:  snapshot,
				Source:   "https://snapshot.debian.org/archive/debian",
				File:     file,
				Note:     "apt.sources_list snapshot",
			})
		}
	}
	return deps, unknowns
}

// parseOCIPull extracts the digest-pinned oci.pull base images.
func parseOCIPull(content, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	for _, args := range scanCallArgs(content, "oci.pull") {
		name := attrValue(args, "name")
		digest := digestRe.FindString(args)
		if name == "" || digest == "" {
			unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "oci.pull without name or a sha256 digest pin: " + args})
			continue
		}
		image := attrValue(args, "image")
		deps = append(deps, common.Dependency{
			Category:     common.CategoryBaseImage,
			Name:         name,
			Version:      "", // digest-only pins carry no tag reference to compare
			Source:       image + " @ " + digest,
			File:         file,
			DigestPinned: true,
		})
	}
	return deps, unknowns
}
