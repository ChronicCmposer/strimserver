package extractorimpl

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"strimserver-check-deps/common"
)

// scanRepoRule returns the argument text of every call to ruleName in content.
// It is the canonical repo-rule scanner: scanCallArgs delegates to it, so both
// share one balanced-parenthesis, quote/comment-aware implementation. A nested
// call inside an argument (e.g. exports_files([...]) inside build_file_content)
// does not truncate the match at the first ")", and a match whose preceding
// character is a word character is skipped, so scanning for "http_archive"
// never matches the s3_http_archive own-pipeline rule.
func scanRepoRule(content, ruleName string) []string {
	var args []string
	needle := ruleName + "("
	for {
		start := strings.Index(content, needle)
		if start < 0 {
			return args
		}
		if start > 0 && isWordChar(content[start-1]) {
			content = content[start+len(ruleName):]
			continue
		}
		depth := 0
		end := -1
	balanceScan:
		for i := start + len(ruleName); i < len(content); {
			c := content[i]
			switch {
			case c == '\'' || c == '"' || c == '#':
				i = skipStringOrComment(content, i)
				continue
			case c == '(':
				depth++
				i++
			case c == ')':
				depth--
				if depth == 0 {
					end = i
					break balanceScan
				}
				i++
			default:
				i++
			}
		}
		if end < 0 {
			// Unbalanced call; stop scanning rather than loop forever.
			return args
		}
		args = append(args, content[start+len(ruleName)+1:end])
		content = content[end+1:]
	}
}

// firstCapture returns the first capture group of re's match in s, or the whole
// match when re has no capture group. It returns "" when there is no match.
func firstCapture(re *regexp.Regexp, s string) string {
	m := re.FindStringSubmatch(s)
	if m == nil {
		return ""
	}
	if len(m) > 1 {
		return m[1]
	}
	return m[0]
}

// noteWithSHA256 annotates a dependency note with its integrity sha256 without
// introducing a struct field. An empty sha leaves the note unchanged.
func noteWithSHA256(note, sha string) string {
	if sha == "" {
		return note
	}
	if note == "" {
		return "sha256=" + sha
	}
	return note + "; sha256=" + sha
}

// stringListAttr returns the quoted string elements of a `key = ["a", "b"]`
// attribute, in declaration order. The scan is quote/comment-aware through the
// shared skipStringOrComment, so a '#' comment inside the list is skipped and
// the bracketed list terminates at its matching ']'. It returns nil when the
// key is absent or the list is unterminated.
func stringListAttr(args, key string) []string {
	for i := 0; i < len(args); {
		c := args[i]
		if c == '\'' || c == '"' || c == '#' {
			i = skipStringOrComment(args, i)
			continue
		}
		if isWordChar(c) && matchesKeyAt(args, i, key) {
			items, end, ok := listAfterKey(args, i+len(key))
			if ok {
				return items
			}
			i = end
			continue
		}
		i++
	}
	return nil
}

// listAfterKey parses `\s*=\s*[ ... ]` starting just past a matched key and
// returns the quoted elements, the index just past the closing ']', and whether
// the list parsed.
func listAfterKey(args string, i int) ([]string, int, bool) {
	i = skipAttrSpace(args, i)
	if i >= len(args) || args[i] != '=' {
		return nil, i, false
	}
	i = skipAttrSpace(args, i+1)
	if i >= len(args) || args[i] != '[' {
		return nil, i, false
	}
	var items []string
	for i++; i < len(args); {
		c := args[i]
		switch {
		case c == '#':
			i = skipStringOrComment(args, i)
		case c == '\'' || c == '"':
			quote := c
			var b strings.Builder
			for i++; i < len(args) && args[i] != quote; i++ {
				if args[i] == '\\' && i+1 < len(args) {
					i++
				}
				b.WriteByte(args[i])
			}
			if i >= len(args) {
				return items, i, false // unterminated quoted element
			}
			items = append(items, b.String())
			i++
		case c == ']':
			return items, i + 1, true
		default:
			i++
		}
	}
	return items, i, false
}

// repoRuleDraft is one dependency a repo-rule call declares, before the file,
// category, and role are attached by the generic pass.
type repoRuleDraft struct {
	name    string
	version string
	source  string
	sha256  string
}

// repoRuleArtifact names one integrity-pinned artifact inside a multi-artifact
// repo-rule call (amd64_sysroot's libc6/libgcc/linux_libc dev debs). Each has
// its own URL (whose Debian version is the pin) and sha256 attribute.
type repoRuleArtifact struct {
	suffix      string
	versionAttr string
	shaAttr     string
}

// repoRuleDefaults carries out-of-band version defaults that are not present in
// the MODULE.bazel call itself: qemu_x86_64's version is the qemu_version attr
// default in tools/bazel/qemu_x86_64.bzl, not an argument of the call.
type repoRuleDefaults struct {
	qemuVersion string
}

// repoRuleSpec declares how one Bazel repo rule's calls become dependencies.
// The declarative fields cover the common single-artifact shape; artifacts,
// packageListAttr, and versionDefault cover the multi-artifact, package-list,
// and external-default shapes. A call that yields neither a version nor a
// sha256 is fail-closed (an ExtractionUnknown) unless versionless is set.
type repoRuleSpec struct {
	ruleName string
	category string
	role     string
	note     string

	// nameAttr is the attribute holding the dependency name (usually "name").
	nameAttr string
	// versionAttrs lists attributes whose value is searched for a version, in
	// priority order; versionRe extracts the token from each value.
	versionAttrs []string
	versionRe    *regexp.Regexp
	// versionDefault, when set, supplies the version out-of-band (qemu).
	versionDefault func(repoRuleDefaults) string
	// shaAttr is the attribute holding the integrity sha256 (usually "sha256").
	shaAttr string
	// sourceAttr names the attribute holding the source location; fixedSource
	// overrides it for rules whose source is not an argument.
	sourceAttr  string
	fixedSource string

	// artifacts, when non-empty, expands one call into one draft per artifact,
	// named "<nameAttr>:<suffix>".
	artifacts []repoRuleArtifact
	// packageListAttr, when set, expands the call's package list into one
	// versionless draft per package (apt.install).
	packageListAttr string
	// versionless marks a rule whose pins carry no version by design (the
	// pinned snapshot governs), so a call without a version or sha is not a
	// failure.
	versionless bool
}

var (
	// semverCaptureRe and twoPartCaptureRe each carry one capture group so
	// firstCapture returns the version token itself. The two-part form is the
	// fallback for URLs like protoc-36.2-linux-x86_64.zip that carry no x.y.z.
	semverCaptureRe  = regexp.MustCompile(`([0-9]+\.[0-9]+\.[0-9]+)`)
	twoPartCaptureRe = regexp.MustCompile(`([0-9]+\.[0-9]+)`)
	// debVersionRe extracts the Debian version between the package-name and
	// architecture fields of a .deb filename, e.g. .../libprotobuf-dev_3.21.12-11+deb13u1_arm64.deb.
	debVersionRe = regexp.MustCompile(`_([^_/]+)_[^_/]+\.deb`)
	// qemuRepoRuleVersionRe extracts the qemu_version attr default from
	// tools/bazel/qemu_x86_64.bzl.
	qemuRepoRuleVersionRe = regexp.MustCompile(`"qemu_version":\s*attr\.string\(\s*default\s*=\s*"([^"]+)"`)
)

// qemuRepoRuleBzlPath is the repo-relative file declaring the qemu_x86_64
// repo-rule's version default.
const qemuRepoRuleBzlPath = "tools/bazel/qemu_x86_64.bzl"

// repoRuleSpecs is the declarative dispatch table for the MODULE.bazel repo
// rules that carry a pin. Order is the emission order of parseRepoRules.
var repoRuleSpecs = []repoRuleSpec{
	{
		ruleName:     "tarball_strip_symlinks",
		category:     common.CategoryToolBinary,
		nameAttr:     "name",
		versionAttrs: []string{"strip_prefix", "url"},
		versionRe:    semverCaptureRe,
		shaAttr:      "sha256",
		sourceAttr:   "url",
		note:         "vendored C library fetched via tarball_strip_symlinks",
	},
	{
		ruleName:     "deb_extract",
		category:     common.CategoryToolBinary,
		nameAttr:     "name",
		versionAttrs: []string{"url"},
		versionRe:    debVersionRe,
		shaAttr:      "sha256",
		sourceAttr:   "url",
		note:         "Debian dev deb extracted via deb_extract",
	},
	{
		ruleName:  "amd64_sysroot",
		category:  common.CategoryToolchain,
		nameAttr:  "name",
		versionRe: debVersionRe,
		note:      "amd64 cross sysroot dev deb",
		artifacts: []repoRuleArtifact{
			{suffix: "libc6", versionAttr: "libc6_url", shaAttr: "libc6_sha256"},
			{suffix: "libgcc", versionAttr: "libgcc_url", shaAttr: "libgcc_sha256"},
			{suffix: "linux_libc", versionAttr: "linux_libc_url", shaAttr: "linux_libc_sha256"},
		},
	},
	{
		ruleName:        "apt.install",
		category:        common.CategoryBaseImage,
		packageListAttr: "packages",
		versionless:     true,
		note:            "donor package resolved from the pinned Debian snapshot",
	},
	{
		ruleName:     "s3_http_archive",
		category:     common.CategoryToolBinary,
		role:         common.RoleIntegrity,
		nameAttr:     "name",
		versionAttrs: []string{"s3_key"},
		versionRe:    twoPartCaptureRe,
		shaAttr:      "sha256",
		sourceAttr:   "s3_key",
		note:         "self-published S3 artifact",
	},
	{
		ruleName:     "s3_http_file",
		category:     common.CategoryRuntime,
		role:         common.RoleIntegrity,
		nameAttr:     "name",
		versionAttrs: []string{"s3_key"},
		versionRe:    twoPartCaptureRe,
		shaAttr:      "sha256",
		sourceAttr:   "s3_key",
		note:         "self-published S3 artifact",
	},
	{
		ruleName:       "qemu_x86_64",
		category:       common.CategoryToolBinary,
		nameAttr:       "name",
		fixedSource:    "https://download.qemu.org",
		versionDefault: func(d repoRuleDefaults) string { return d.qemuVersion },
		note:           "patched qemu-x86_64 repo rule",
	},
}

// parseRepoRules scans every rule in the spec table and turns each call into
// dependencies (or a fail-closed unknown). The ordered aggregation preserves
// the spec-table order.
func parseRepoRules(content, file string, defaults repoRuleDefaults) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	for _, spec := range repoRuleSpecs {
		for _, args := range scanRepoRule(content, spec.ruleName) {
			drafts := spec.derive(args, defaults)
			if len(drafts) == 0 {
				unknowns = append(unknowns, common.ExtractionUnknown{
					File:   file,
					Reason: spec.ruleName + " without a name: " + args,
				})
				continue
			}
			for _, dr := range drafts {
				if dr.version == "" && dr.sha256 == "" && !spec.versionless {
					unknowns = append(unknowns, common.ExtractionUnknown{
						File:   file,
						Reason: spec.ruleName + " " + dr.name + " without a version or sha256: " + args,
					})
					continue
				}
				deps = append(deps, spec.dependency(dr, file))
			}
		}
	}
	return deps, unknowns
}

// derive turns one call's argument text into the drafts it declares. It returns
// nil when the call has no name, which the caller reports as an unknown.
func (s repoRuleSpec) derive(args string, defaults repoRuleDefaults) []repoRuleDraft {
	if s.packageListAttr != "" {
		return s.packageDrafts(args)
	}
	name := attrValue(args, s.nameAttr)
	if name == "" {
		return nil
	}
	if len(s.artifacts) > 0 {
		return s.artifactDrafts(name, args)
	}
	return []repoRuleDraft{{
		name:    name,
		version: s.deriveVersion(args, defaults),
		source:  s.deriveSource(args),
		sha256:  attrValue(args, s.shaAttr),
	}}
}

func (s repoRuleSpec) deriveVersion(args string, defaults repoRuleDefaults) string {
	if s.versionDefault != nil {
		return s.versionDefault(defaults)
	}
	for _, attr := range s.versionAttrs {
		if v := firstCapture(s.versionRe, attrValue(args, attr)); v != "" {
			return v
		}
	}
	return ""
}

func (s repoRuleSpec) deriveSource(args string) string {
	if s.fixedSource != "" {
		return s.fixedSource
	}
	return attrValue(args, s.sourceAttr)
}

func (s repoRuleSpec) packageDrafts(args string) []repoRuleDraft {
	var drafts []repoRuleDraft
	for _, pkg := range stringListAttr(args, s.packageListAttr) {
		drafts = append(drafts, repoRuleDraft{name: pkg})
	}
	return drafts
}

func (s repoRuleSpec) artifactDrafts(name, args string) []repoRuleDraft {
	var drafts []repoRuleDraft
	for _, a := range s.artifacts {
		url := attrValue(args, a.versionAttr)
		drafts = append(drafts, repoRuleDraft{
			name:    name + ":" + a.suffix,
			version: firstCapture(s.versionRe, url),
			source:  url,
			sha256:  attrValue(args, a.shaAttr),
		})
	}
	return drafts
}

func (s repoRuleSpec) dependency(dr repoRuleDraft, file string) common.Dependency {
	role := s.role
	if role == "" {
		role = integrityRoleForMissingVersion(dr.version, dr.sha256)
	}
	return common.Dependency{
		Category: s.category,
		Name:     dr.name,
		Version:  dr.version,
		Source:   dr.source,
		File:     file,
		Note:     noteWithSHA256(s.note, dr.sha256),
		Role:     role,
	}
}

// readQemuRepoRuleDefault reads the qemu_x86_64 repo rule's version default
// from tools/bazel/qemu_x86_64.bzl. A missing or unreadable file yields "",
// which makes the qemu call fail closed rather than silently inventing a pin.
func readQemuRepoRuleDefault(root string) string {
	data, err := os.ReadFile(filepath.Join(root, qemuRepoRuleBzlPath))
	if err != nil {
		return ""
	}
	return firstCapture(qemuRepoRuleVersionRe, string(data))
}
