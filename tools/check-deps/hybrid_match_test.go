package main

import (
	"testing"

	"strimserver-check-deps/common"
)

// This file covers the hybrid resolver matching added in Steps 63-64: the
// exact Matches is unchanged, and two new matchers are layered on top of it —
// a per-architecture name-prefix matcher and an opt-in URL-derived GitHub
// matcher — while first-match-wins order is preserved.

// TestMatchesRemainsExact proves the original exact matcher did not loosen: a
// name prefix alone must not match.
func TestMatchesRemainsExact(t *testing.T) {
	m := Matches(common.CategoryToolBinary, "mediamtx_dist")
	if !m(common.Dependency{Category: common.CategoryToolBinary, Name: "mediamtx_dist"}) {
		t.Error("Matches did not match its exact category/name")
	}
	if m(common.Dependency{Category: common.CategoryToolBinary, Name: "mediamtx_dist_arm64"}) {
		t.Error("Matches matched a prefix, want exact-only")
	}
	if m(common.Dependency{Category: common.CategoryScriptPin, Name: "mediamtx_dist"}) {
		t.Error("Matches ignored the category")
	}
}

// TestMatchesNamePrefixArchVariants proves the prefix matcher folds the
// per-architecture variants onto one entry: the amd64 golangci entry owns the
// arm64 name, and mediamtx_dist owns mediamtx_dist_arm64.
func TestMatchesNamePrefixArchVariants(t *testing.T) {
	cases := []struct {
		entry string
		dep   string
		want  bool
	}{
		{"golangci_lint_linux_amd64", "golangci_lint_linux_amd64", true},
		{"golangci_lint_linux_amd64", "golangci_lint_linux_arm64", true},
		{"mediamtx_dist", "mediamtx_dist", true},
		{"mediamtx_dist", "mediamtx_dist_arm64", true},
		{"mediamtx_dist", "mediamtx_dist_amd64", true},
		{"mediamtx_dist", "other_dist", false},
	}
	for _, tc := range cases {
		m := MatchesNamePrefix(common.CategoryToolBinary, tc.entry)
		got := m(common.Dependency{Category: common.CategoryToolBinary, Name: tc.dep})
		if got != tc.want {
			t.Errorf("MatchesNamePrefix(%q) on dep %q = %v, want %v", tc.entry, tc.dep, got, tc.want)
		}
	}

	if MatchesNamePrefix(common.CategoryToolBinary, "mediamtx_dist")(common.Dependency{Category: common.CategoryScriptPin, Name: "mediamtx_dist"}) {
		t.Error("MatchesNamePrefix ignored the category")
	}
}

// TestMatchesGitHubURL proves the opt-in URL matcher owns a dep by its GitHub
// download URL, tolerating release path suffixes and a .git suffix, and
// rejecting non-GitHub or other-repo URLs.
func TestMatchesGitHubURL(t *testing.T) {
	cases := []struct {
		source string
		want   bool
	}{
		{"https://github.com/foo/bar/releases/download/v1.2.3/bar.tar.gz", true},
		{"https://github.com/foo/bar", true},
		{"https://github.com/foo/bar.git", true},
		{"http://github.com/foo/bar", true},
		{"https://github.com/foo/baz", false},
		{"https://github.com/other/bar", false},
		{"https://gitlab.com/foo/bar", false},
		{"https://bcr.bazel.build/modules/rules_go", false},
		{"", false},
	}
	m := MatchesGitHubURL(common.CategoryToolBinary, "foo", "bar")
	for _, tc := range cases {
		got := m(common.Dependency{Category: common.CategoryToolBinary, Source: tc.source})
		if got != tc.want {
			t.Errorf("MatchesGitHubURL(foo/bar) on source %q = %v, want %v", tc.source, got, tc.want)
		}
	}

	if MatchesGitHubURL(common.CategoryScriptPin, "foo", "bar")(common.Dependency{Category: common.CategoryToolBinary, Source: "https://github.com/foo/bar"}) {
		t.Error("MatchesGitHubURL ignored the category")
	}
}

// TestMatchResolverPreservesFirstMatchOrder proves the hybrid matchers slot
// into the existing strict first-match-wins dispatch: when both an exact and a
// prefix entry own the dependency, whichever entry is listed first wins.
func TestMatchResolverPreservesFirstMatchOrder(t *testing.T) {
	exact := ResolverEntry{Match: Matches(common.CategoryToolBinary, "mediamtx_dist"), Network: true}
	prefix := ResolverEntry{Match: MatchesNamePrefix(common.CategoryToolBinary, "mediamtx_dist"), Network: false}
	dep := common.Dependency{Category: common.CategoryToolBinary, Name: "mediamtx_dist"}

	got, ok := matchResolver([]ResolverEntry{exact, prefix}, dep)
	if !ok || !got.Network {
		t.Error("exact entry listed first did not win")
	}
	got, ok = matchResolver([]ResolverEntry{prefix, exact}, dep)
	if !ok || got.Network {
		t.Error("prefix entry listed first did not win")
	}
}
