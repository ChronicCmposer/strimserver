package main

import (
	"errors"
)

// This file routes each Phase 1 dependency to the version-source resolver that
// owns it and combines the resolver's answer with the classifier. Resolvers
// live in per-client files (bcr.go, dockerhub.go, ...) and each returns a
// versionInfo; classify in tier.go turns that into a resolved record.

// versionInfo is the pure datum a resolver produces: the latest upstream
// version, an optional release date, informational notes, and the error when
// resolution failed (never fatal, always surfaced as "unknown").
type versionInfo struct {
	version string   // latest/wanted version ("" when none to compare)
	date    string   // optional upstream release date
	infos   []string // informational notes (yanked, deprecated, staleness, exemptions)
	err     error    // resolution failure; nil means success
}

// resolverFunc resolves one dependency's latest version.
type resolverFunc func(dep dependency) versionInfo

// resolverEntry matches a dependency (usually by category/name) to its
// resolver. Entries are evaluated in order; the first match wins. network marks
// resolvers that perform upstream I/O worth caching (registry calls, scrapers);
// the no-op resolvers (digest, toolchain) are not network-backed and never
// cached.
type resolverEntry struct {
	match   func(dep dependency) bool
	resolve resolverFunc
	network bool
}

var depResolvers = []resolverEntry{
	{match: isBazelModule, resolve: bcrResolve, network: true},
	{match: matches("tool-binary", "golangci_lint_linux_amd64"), resolve: githubResolverFor("golangci", "golangci-lint"), network: true},
	{match: matches("tool-binary", "mediamtx_dist"), resolve: githubResolverFor("bluenviron", "mediamtx"), network: true},
	{match: matches("runtime", "iperf3"), resolve: alpineResolve, network: true},
	{match: matches("base-image", "alpine"), resolve: digestResolve},
	{match: matches("base-image", "debian"), resolve: debianResolve, network: true},
	{match: matches("base-image", "amazonlinux"), resolve: amazonlinuxResolve, network: true},
	{match: matches("script-pin", "qemu"), resolve: qemuScrapeResolve, network: true},
	{match: matches("script-pin", "openssh-portable"), resolve: opensshScrapeResolve, network: true},
	{match: matches("script-pin", "GNU m4"), resolve: m4ScrapeResolve, network: true},
	{match: matches("script-pin", "ffmpeg"), resolve: ffmpegScrapeResolve, network: true},
	{match: matches("script-pin", "nv-codec-headers"), resolve: githubResolverFor("FFmpeg", "nv-codec-headers"), network: true},
	{match: matches("script-pin", "CUDA"), resolve: nvidiaResolve, network: true},
	{match: matches("script-pin", "distlib"), resolve: pypiResolve, network: true},
	{match: isCIAction, resolve: githubActionResolve, network: true},
	{match: isToolchain, resolve: toolchainResolve},
}

// matchResolver returns the first resolverEntry matching dep.
func matchResolver(dep dependency) (resolverEntry, bool) {
	for _, entry := range depResolvers {
		if entry.match(dep) {
			return entry, true
		}
	}
	return resolverEntry{}, false
}

// resolveDep routes one extracted dependency through its resolver and the
// classifier. It always returns a resolved record; a missing resolver or a
// failed network call become an "unknown" record with a reason.
func resolveDep(dep dependency) resolved {
	if entry, ok := matchResolver(dep); ok {
		return classify(dep, entry.resolve(dep))
	}
	return classify(dep, versionInfo{err: errors.New("no resolver configured for this dependency")})
}

// digestResolve short-circuits digest-pinned base images (alpine): there is no
// tag to compare, so it returns no version and lets classify report ok.
func digestResolve(dep dependency) versionInfo {
	return versionInfo{infos: []string{"digest-pinned base image"}}
}

// toolchainResolve marks toolchain pins (Go, Bazel, Node, pnpm) as current;
// no upstream endpoint is configured, so nothing is compared.
func toolchainResolve(dep dependency) versionInfo {
	return versionInfo{
		version: dep.Version,
		infos:   []string{"toolchain pin; no upstream endpoint configured"},
	}
}

func isBazelModule(dep dependency) bool { return dep.Category == "bazel-module" }
func isCIAction(dep dependency) bool    { return dep.Category == "ci-action" }
func isToolchain(dep dependency) bool   { return dep.Category == "toolchain" }

// matches builds a matcher that accepts a dependency of the given category and
// name.
func matches(category, name string) func(dependency) bool {
	return func(dep dependency) bool {
		return dep.Category == category && dep.Name == name
	}
}
