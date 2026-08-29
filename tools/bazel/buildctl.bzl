"""Hybrid escape hatch: wraps the existing `sudo buildctl` toolchain for the
two images rules_oci cannot express -- ffmpeg (compiles FFmpeg from source
against the CUDA devel image) and the openssh RPM (autoreconf/configure/make/
rpmbuild). rules_oci has no RUN equivalent and won't get one (it treats a
container as an archive format, not a build environment), so these two stay
on BuildKit, wrapped just enough that `bazel build //...` remains the single
entry point and the action participates in Bazel's dependency graph and
local cache (though not remote caching or sandboxing -- see
execution_requirements below).

Caveat (documented, not solved): this action is not hermetic. Bazel keys its
cache on the declared `srcs`, but can't see the remote BuildKit daemon's
state, upstream git clones inside the Dockerfile, or apt package drift.
`bazel clean --expunge` plus a fresh daemon is the escape hatch if a stale
result is suspected.
"""

def _buildctl_build_impl(ctx):
    dockerfile = ctx.file.dockerfile
    context_dir = dockerfile.dirname

    addr_opt = "--addr {}".format(ctx.attr.addr) if ctx.attr.addr else ""

    build_arg_opts = " ".join([
        "--opt build-arg:{}={}".format(key, value)
        for key, value in ctx.attr.build_args.items()
    ])

    if ctx.attr.output_type == "oci_tar":
        out = ctx.outputs.out
        output_opt = "--output type=oci,name={},dest={}".format(ctx.attr.image_name, out.path)
        outputs = [out]
    elif ctx.attr.output_type == "local_file":
        out = ctx.outputs.out
        output_opt = "--output type=local,dest={}".format(out.dirname)
        outputs = [out]
    else:
        fail("output_type must be \"oci_tar\" or \"local_file\", got %r" % ctx.attr.output_type)

    command = " ".join([part for part in [
        "sudo buildctl",
        addr_opt,
        "build",
        "--frontend=dockerfile.v0",
        "--opt platform=linux/amd64",
        "--local context=" + context_dir,
        "--local dockerfile=" + context_dir,
        "--opt filename=./" + dockerfile.basename,
        ("--opt target=" + ctx.attr.target) if ctx.attr.target else "",
        build_arg_opts,
        "--progress=plain",
        output_opt,
    ] if part])

    ctx.actions.run_shell(
        outputs = outputs,
        inputs = ctx.files.srcs,
        command = command,
        mnemonic = "BuildctlBuild",
        progress_message = "buildctl: building %s (target=%s)" % (context_dir, ctx.attr.target),
        execution_requirements = {
            # A real BuildKit daemon is not a Bazel action and can't be
            # sandboxed, run remotely, or executed without network access to
            # the daemon (and, for ffmpeg, the upstream git/apt mirrors the
            # Dockerfile itself reaches out to).
            "no-sandbox": "1",
            "no-remote": "1",
            "requires-network": "1",
            # Never safe to run more than one buildctl invocation against the
            # same daemon concurrently from this rule.
            "local": "1",
        },
        use_default_shell_env = True,
    )
    return [DefaultInfo(files = depset(outputs))]

buildctl_build = rule(
    implementation = _buildctl_build_impl,
    attrs = {
        "dockerfile": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The Dockerfile to build; its directory is the buildctl context.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "All files buildctl's Dockerfile RUN/COPY steps can reach: real Bazel " +
                  "inputs, so a change to any of them invalidates the cached result " +
                  "(unlike make, which always rebuilds these targets unconditionally).",
        ),
        "target": attr.string(
            doc = "The Dockerfile stage to build (--opt target=...). Omit for a " +
                  "single-stage Dockerfile with no named stages.",
        ),
        "addr": attr.string(
            doc = "Optional buildctl daemon address, e.g. tcp://127.0.0.1:1234. " +
                  "Defaults to buildctl's own default (a local Unix socket).",
        ),
        "build_args": attr.string_dict(
            doc = "Extra --opt build-arg:KEY=VALUE pairs.",
        ),
        "image_name": attr.string(
            doc = "Required when output_type = \"oci_tar\": the image name/tag to embed.",
        ),
        "output_type": attr.string(
            mandatory = True,
            values = ["oci_tar", "local_file"],
        ),
        "out": attr.output(
            mandatory = True,
            doc = "Declared output file: the OCI tarball, or the single local artifact " +
                  "(its basename must match the filename the Dockerfile's scratch " +
                  "target writes at its root, e.g. \"openssh-experimental.rpm\").",
        ),
    },
)
