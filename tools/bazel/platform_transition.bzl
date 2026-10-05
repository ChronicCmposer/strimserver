"""Rebuilds a target under an explicit linux_<arch> target platform.

The strimserver deployment bundles are per-architecture: the same BUILD graph
select()s the controller binary, the image architectures, and the multiarch
lib paths on //tools/bazel:is_*_target. The default invocation now builds
natively for the HOST platform, so each arch's deployment tar is rebuilt under
its own forced platform via this transition -- ONE `bazel build` produces BOTH
the amd64 and arm64 Go tars from a single analysis pass.

The rule exposes the transitioned target's default output as a symlink under
the caller-chosen `out` basename. That distinct name is what keeps sh_binary
runfiles collision-free: the underlying pkg_tar keeps its unsuffixed output
name (strimserver-deployment-go-amd64.unchecked.tar) in BOTH configurations, so
the amd64 and arm64 tars would otherwise flatten to the same runfiles path and
one would silently overwrite the other in `bazel run //:publish_*`.
"""

def _arch_transition_impl(settings, attr):
    if attr.to_arch == "amd64":
        return {
            "//command_line_option:platforms": "//tools/bazel:linux_amd64",
        }
    if attr.to_arch == "arm64":
        return {
            "//command_line_option:platforms": "//tools/bazel:linux_arm64",
        }
    fail("to_arch must be 'amd64' or 'arm64', got %r" % attr.to_arch)

_arch_transition = transition(
    implementation = _arch_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _arch_transition_rule_impl(ctx):
    """Symlink the transitioned target's default output under `out`."""
    target = ctx.attr.target[0]
    out = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.symlink(output = out, target_file = target[DefaultInfo].files.to_list()[0])
    return [DefaultInfo(files = depset([out]))]

arch_transition = rule(
    implementation = _arch_transition_rule_impl,
    attrs = {
        "target": attr.label(cfg = _arch_transition),
        "to_arch": attr.string(
            mandatory = True,
            values = ["amd64", "arm64"],
            doc = "The linux target architecture to build under.",
        ),
        "out": attr.string(
            mandatory = True,
            doc = "The output basename (e.g. strimserver-deployment-go-arm64.unchecked.tar); must differ from the target's own basename to avoid runfiles collisions.",
        ),
        # Kept for compatibility; the function-transition allowlist is a no-op
        # in modern Bazel but the implicit attr is still recognized.
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Rebuild `target` under //tools/bazel:linux_<to_arch>, exposing its default output as a symlink named `out`.",
)
