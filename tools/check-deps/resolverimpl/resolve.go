package resolverimpl

import "strimserver-check-deps/common"

// DigestResolve short-circuits digest-pinned base images (alpine): there is no
// tag to compare, so it returns no version and lets classify report ok.
func DigestResolve(dep common.Dependency) common.VersionInfo {
	return common.VersionInfo{Infos: []string{"digest-pinned base image"}}
}

// ToolchainResolve marks toolchain pins (Go, Bazel, Node, pnpm) as current;
// no upstream endpoint is configured, so nothing is compared.
func ToolchainResolve(dep common.Dependency) common.VersionInfo {
	return common.VersionInfo{
		Version: dep.Version,
		Infos:   []string{"toolchain pin; no upstream endpoint configured"},
	}
}

// DigestResolve and ToolchainResolve are direct common.Resolver
// implementations; the assertions pin the contract so a signature drift fails
// the build rather than surfacing only at a registration site.
var _ common.Resolver = DigestResolve
var _ common.Resolver = ToolchainResolve
