"""Forces a target to build under the linux_arm64 platform.

The strimserver deployment bundle is per-architecture: the same BUILD graph
select()s the controller binary, the image architectures, and the multiarch
lib paths on //tools/bazel:is_*_target. The default invocation builds the
amd64 bundle (from --platforms=//tools/bazel:linux_amd64 in .bazelrc); this
rule rebuilds a single target -- the unchecked deployment tar -- under
//tools/bazel:linux_arm64, so ONE `bazel build` produces BOTH tars.

The rule exposes the transitioned target's default output as a symlink under
the caller-chosen `out` basename. That distinct name is what keeps sh_binary
runfiles collision-free: the underlying pkg_tar keeps its unsuffixed output
name (strimserver-deployment-go-arm64.unchecked.tar) in BOTH configurations, so the
amd64 and arm64 tars would otherwise flatten to the same runfiles path and
one would silently overwrite the other in `bazel run //:publish_*`.
"""

def _platform_transition_impl(settings, attr):
    return {
        "//command_line_option:platforms": "//tools/bazel:linux_arm64",
    }

_platform_transition = transition(
    implementation = _platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _platform_transition_rule_impl(ctx):
    """Symlink the transitioned target's default output under `out`."""
    target = ctx.attr.target[0]
    out = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.symlink(output = out, target_file = target[DefaultInfo].files.to_list()[0])
    return [DefaultInfo(files = depset([out]))]

platform_transition = rule(
    implementation = _platform_transition_rule_impl,
    attrs = {
        "target": attr.label(cfg = _platform_transition),
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
    doc = "Rebuild `target` under //tools/bazel:linux_arm64, exposing its default output as a symlink named `out`.",
)