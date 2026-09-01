"""Builds the buildkit-direct-execve patched qemu-x86_64 as a Bazel tool.

QEMU_VERSION (env)
    Overrides the emulator version (default "8.2.2", the ffmpeg-dist pin --
    for cross-stripping any patched qemu works, but the default deliberately
    matches the consumer whose artifact bytes are version-sensitive). Must be
    a version tools/qemu/build-qemu.sh supports (8.2.2 or 9.2.4) or have
    QEMU_SOURCE_SHA256 pinned.

    This is a repo-rule env var: Bazel reads it only when the repository is
    (re)fetched, so changing it after a build requires `bazel shutdown` and a
    re-run, or passing --repo_env=QEMU_VERSION=... on the command line.

Why this exists:
    strimserver ships a linux/amd64 mediamtx binary, and on non-x86_64 build
    hosts the native host `strip` cannot cross-strip it. The repo's own
    tools/qemu/build-qemu.sh already builds a qemu-x86_64 carrying the
    tonistiigi/binfmt "buildkit-direct-execve" patch series, used by the
    out-of-band ffmpeg/openssh artifact pipelines. This rule makes that same
    emulator available as a hermetic Bazel tool so the in-tree genrule can
    cross-strip the amd64 binary by running an amd64 GNU strip under it.

    The build is deliberately heavy (source download + meson/ninja compile),
    so nothing may reference this repository on an x86_64 host: consumers
    wire it in behind a config_setting/select so an amd64 build never fetches
    it. The rule guards that contract itself (fail fast if fetched on amd64).

    The built binary is installed into this repository's own directory (via
    QEMU_CACHE), so the tool is hermetic: it does not read the version-stamped
    ~/.cache path the out-of-band pipelines share, and it is version-stamped
    by the repository's own name. build-qemu.sh's idempotency guard makes a
    re-fetch cheap (it verifies the cached binary before rebuilding).
"""

def _qemu_x86_64_impl(ctx):
    # Guard clause: this emulator exists only to run amd64 binaries on
    # non-x86_64 hosts, so an x86_64 fetch means the consumer's select wiring
    # regressed. Fail loud and early instead of burning a full source build.
    if ctx.os.arch == "amd64":
        fail(
            "qemu_x86_64: fetched on an x86_64 host, but this emulator is only " +
            "needed to cross-run amd64 binaries on non-x86_64 hosts; the " +
            "genrule select in core/BUILD.bazel should have resolved this " +
            "repository away",
        )

    build_script = ctx.path(ctx.attr.build_script)
    qemu_bin = ctx.path("qemu-x86_64")

    # QEMU_CACHE points into this repository so the built binary becomes a
    # repo artifact (hermetic, version-stamped by the repo name). The script
    # verifies an existing cache binary before reuse, so a re-fetch is cheap.
    # PATH/HOME/XDG_CACHE_HOME are inherited from the repo rule environment,
    # which is exactly what the script's host-dependency checks rely on.
    #
    # TMPDIR is pinned to this repository's own directory (real disk, under
    # the bazel output base): the script's `mktemp -d` workdir -- where the
    # ~1GB qemu source tree is extracted and meson/ninja compiles it -- would
    # otherwise land in $TMPDIR, and on hosts where /tmp is a small tmpfs
    # (containers/VMs) that exhausts it and the fetch dies mid-tar with
    # ENOSPC. The script's EXIT trap removes the workdir, so nothing is left
    # behind in this directory.
    result = ctx.execute(
        [str(build_script)],
        environment = {
            "QEMU_VERSION": ctx.attr.qemu_version,
            "QEMU_CACHE": str(qemu_bin),
            "TMPDIR": str(qemu_bin.dirname),
        },
        timeout = ctx.attr.build_timeout,
        quiet = False,
    )
    if result.return_code != 0:
        fail(
            "qemu_x86_64: tools/qemu/build-qemu.sh failed (exit %d):\n%s" %
            (result.return_code, result.stderr),
        )

    ctx.file("BUILD.bazel", 'exports_files(["qemu-x86_64"])')

qemu_x86_64 = repository_rule(
    implementation = _qemu_x86_64_impl,
    attrs = {
        "build_script": attr.label(
            default = "//tools/qemu:build-qemu.sh",
            allow_single_file = True,
            doc = "The patched-qemu build script (tracks changes via the label).",
        ),
        "qemu_version": attr.string(
            default = "8.2.2",
            doc = "QEMU_VERSION pin; must match a supported tools/qemu pin.",
        ),
        "build_timeout": attr.int(
            default = 3600,
            doc = "Seconds allowed for the qemu source build (meson/ninja).",
        ),
    },
    environ = [
        "QEMU_VERSION",
        "XDG_CACHE_HOME",
        "HOME",
        "PATH",
        "TMPDIR",
    ],
    doc = "Builds the buildkit-direct-execve patched qemu-x86_64 as a file target.",
)