"""Transitions for building the C controller deployment bundles.

The C controller (//core/controller/c:strimserver-controller) is a
musl-static binary produced by the hermetic zig toolchain under
`--config=amd64` / `--config=arm64` (.bazelrc). Those configs exist only as
command-line flags, but the release/publish targets must build BOTH the Go
and the C bundles in ONE invocation (one `bazel run`), so the C bundle's tar
subgraph is rebuilt under a transition that injects exactly the flags the
configs set:

  --platforms=@zig_sdk//platform:linux_<arch>
  --extra_toolchains=@zig_sdk//toolchain:linux_<arch>_musl
  --copt=-fno-sanitize=undefined
  --linkopt=-fno-sanitize=undefined
  --compilation_mode=opt
  --copt=-Os
  --copt=-ffunction-sections
  --copt=-fdata-sections
  --linkopt=-Wl,--gc-sections
  --linkopt=-Wl,-s
  --linkopt=-Wl,--build-id=none

Without the transition, the C controller would resolve the DEFAULT
clang/glibc toolchain (registered before zig) and link a dynamic glibc
binary -- the very thing the FROM-scratch, no-donor image forbids.

Binary-size reduction (same flags as the .bazelrc configs): the zig
toolchain's fastbuild mode passes no -O flag (i.e. -O0), which made the
~1.5 MB static binary ~58% larger than necessary. compilation_mode=opt
makes the toolchain emit -O2 + -DNDEBUG; Bazel appends the user --copt
after the toolchain flags, so -Os (added after -O2) wins.
-ffunction-sections/-fdata-sections plus --gc-sections prune unused
functions from the pre-built musl static libc (built with
function-sections) and unused MHD/nanopb/yyjson paths; -Wl,-s strips the
symtab (the binary is a shipped image entrypoint, no debugging use);
--build-id=none drops a trivial note section. NOTE: -Wl,--icf=safe
(identical code folding) is intentionally NOT included: the zig 0.15.2
self-hosted linker errors with "unsupported linker arg: --icf" (Zig
upstream limitation; zig cc ignores -fuse-ld=lld). -flto is intentionally
excluded too (Zig/LLVM LTO bugs).

The rule mirrors //tools/bazel/platform_transition.bzl: it symlinks the
transitioned target's default output under the caller-chosen `out` basename.
That distinct name is what keeps the four bundles collision-free in
sh_binary runfiles.
"""

def _c_controller_transition_impl(settings, attr):
    if attr.to_arch == "amd64":
        return {
            "//command_line_option:platforms": "@zig_sdk//platform:linux_amd64",
            "//command_line_option:extra_toolchains": ["@zig_sdk//toolchain:linux_amd64_musl"],
            "//command_line_option:compilation_mode": "opt",
            "//command_line_option:copt": [
                "-fno-sanitize=undefined",
                "-Os",
                "-ffunction-sections",
                "-fdata-sections",
            ],
            "//command_line_option:linkopt": [
                "-fno-sanitize=undefined",
                "-Wl,--gc-sections",
                "-Wl,-s",
                "-Wl,--build-id=none",
            ],
        }
    if attr.to_arch == "arm64":
        return {
            "//command_line_option:platforms": "@zig_sdk//platform:linux_arm64",
            "//command_line_option:extra_toolchains": ["@zig_sdk//toolchain:linux_arm64_musl"],
            "//command_line_option:compilation_mode": "opt",
            "//command_line_option:copt": [
                "-fno-sanitize=undefined",
                "-Os",
                "-ffunction-sections",
                "-fdata-sections",
            ],
            "//command_line_option:linkopt": [
                "-fno-sanitize=undefined",
                "-Wl,--gc-sections",
                "-Wl,-s",
                "-Wl,--build-id=none",
            ],
        }
    fail("to_arch must be 'amd64' or 'arm64', got %r" % attr.to_arch)

_c_controller_transition = transition(
    implementation = _c_controller_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
        "//command_line_option:extra_toolchains",
        "//command_line_option:compilation_mode",
        "//command_line_option:copt",
        "//command_line_option:linkopt",
    ],
)

def _c_controller_transition_rule_impl(ctx):
    """Symlink the transitioned target's default output under `out`."""
    target = ctx.attr.target[0]
    out = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.symlink(output = out, target_file = target[DefaultInfo].files.to_list()[0])
    return [DefaultInfo(files = depset([out]))]

c_controller_transition = rule(
    implementation = _c_controller_transition_rule_impl,
    attrs = {
        "target": attr.label(cfg = _c_controller_transition),
        "to_arch": attr.string(
            mandatory = True,
            values = ["amd64", "arm64"],
            doc = "The zig musl target architecture to build the C controller for.",
        ),
        "out": attr.string(
            mandatory = True,
            doc = "The output basename (e.g. strimserver-deployment-c-amd64.unchecked.tar); must differ from the target's own basename to avoid runfiles collisions.",
        ),
        # Kept for compatibility; the function-transition allowlist is a no-op
        # in modern Bazel but the implicit attr is still recognized.
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Rebuild `target` under the C controller's zig musl <arch> configuration, exposing its default output as a symlink named `out`.",
)