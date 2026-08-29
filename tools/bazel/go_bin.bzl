"""Exposes the raw `go` binary from the resolved rules_go toolchain.

@rules_go//go:go (go_bin_runner) is explicitly documented as "only meant to
be used with 'bazel run', not as a tool" -- it shells out through a wrapper
that resets cwd based on BUILD_WORKING_DIRECTORY, which bazel test never
sets, so it silently ignores a test's own working directory. This rule reads
the SDK's go binary directly from the toolchain instead, for tools (like
golangci-lint) that need a plain `go` on PATH inside a hermetic test.
"""

_GO_TOOLCHAIN_TYPE = "@rules_go//go:toolchain"

def _go_bin_impl(ctx):
    sdk = ctx.toolchains[_GO_TOOLCHAIN_TYPE].sdk
    return [DefaultInfo(files = depset([sdk.go]), runfiles = ctx.runfiles([sdk.go]))]

go_bin = rule(
    implementation = _go_bin_impl,
    toolchains = [_GO_TOOLCHAIN_TYPE],
    doc = "Provides the resolved Go toolchain's `go` binary as a plain file.",
)
