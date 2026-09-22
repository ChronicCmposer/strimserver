"""Hermetic amd64 glibc static sysroot built from Debian trixie cross debs.

The clang cross-toolchain (registered in MODULE.bazel) links linux/amd64
binaries on this aarch64 host. This rule assembles the `--sysroot` it needs
from three `Architecture: all` Debian cross dev packages fetched from
snapshot.debian.org (the same 20260824T082821Z pin as the @trixie apt
extension and the deb_extract dev debs above):

  * libc6-dev-amd64-cross        -- crt1.o/crti.o/crtn.o, libc.a, libm.a,
                                    libpthread.a, libdl.a, the glibc headers;
  * linux-libc-dev-amd64-cross   -- the Linux UAPI headers;
  * libgcc-14-dev-amd64-cross    -- libgcc.a, libgcc_eh.a, crtbegin*/crtend*.

Each .deb is a plain `ar` archive holding control.tar.xz + data.tar.xz, so
`ar` + `tar` (POSIX tools the repo's other repo rules already assume, e.g.
deb_extract.bzl) extract them. The three trees merge into one `sysroot/` tree
in the layout the toolchain expects:

  sysroot/include/               -- all headers, glibc + kernel UAPI together
  sysroot/lib/                   -- crt*.o and the static archives (the glibc
                                    multiarch prefix /usr/x86_64-linux-gnu/lib/
                                    is dropped)
  sysroot/lib/gcc/               -- the gcc-14 support libs, keeping their
                                    natural x86_64-linux-gnu/14/ subpath

The libc6-dev package ships GNU ld *linker scripts* (libc.so, libm.so,
libm.a) whose GROUP (...) members are absolute host paths like
/usr/x86_64-linux-gnu/lib/libm-2.41.a; lld rejects absolute members that do
not exist on the host. This rule rewrites those members to bare relative
names so lld resolves them from the script's own directory (or -L) -- the
same trick OpenWrt applies to its cross sysroots.
"""

def _run(ctx, command):
    """Run one shell command, failing loudly with its stderr on a bad exit."""
    result = ctx.execute(["/bin/sh", "-c", command], quiet = True)
    if result.return_code != 0:
        fail(
            "{name}: `{command}` failed (exit {code}):\n{stderr}".format(
                name = ctx.name,
                command = command,
                code = result.return_code,
                stderr = result.stderr,
            ),
        )

def _patch_linker_scripts(ctx):
    """Rewrite absolute GROUP (...) members in GNU ld linker scripts to bare names.

    Only the small text scripts are touched: grep's -I keeps binary ar
    archives (libc.a, libm-2.41.a, ...) that merely contain the string out of
    the list, so the real archives stay byte-identical. The multiarch prefix
    is stripped first (the literal OpenWrt `/usr/lib/` rule alone would leave
    `/usr/x86_64-linux-gnu/lib/...` members half-patched); the generic
    `/usr/lib/` and `/lib/` rules remain as a fallback for any non-multiarch
    member.
    """
    _run(
        ctx,
        "grep -rlI -E 'GROUP \\(|OUTPUT_FORMAT' sysroot/lib | " +
        "xargs -r sed -i " +
        "'s,/usr/x86_64-linux-gnu/lib64/,,g; s,/usr/x86_64-linux-gnu/lib/,,g; " +
        "s,/usr/lib/,,g; s,/lib/,,g'",
    )

def _verify_sysroot(ctx):
    """Fail fast if the merged tree is missing a file the toolchain needs."""
    for required in [
        "sysroot/lib/crt1.o",
        "sysroot/lib/libc.a",
        "sysroot/lib/libm.a",
        "sysroot/lib/gcc/x86_64-linux-gnu/14/libgcc.a",
    ]:
        check = ctx.execute(["test", "-f", required], quiet = True)
        if check.return_code != 0:
            fail(
                "{name}: merged sysroot is missing {missing}; the pinned Debian " +
                "packages no longer have the expected layout -- re-verify the " +
                "versions at the snapshot timestamp".format(
                    name = ctx.name,
                    missing = required,
                ),
            )

def _amd64_sysroot_impl(ctx):
    for deb, url, sha256 in [
        ("libc6.deb", ctx.attr.libc6_url, ctx.attr.libc6_sha256),
        ("linux_libc.deb", ctx.attr.linux_libc_url, ctx.attr.linux_libc_sha256),
        ("libgcc.deb", ctx.attr.libgcc_url, ctx.attr.libgcc_sha256),
    ]:
        ctx.download(
            url = url,
            output = deb,
            sha256 = sha256,
        )

    # Extract each deb into its own directory so the data.tar.xz members
    # cannot collide, then merge the wanted subtrees into sysroot/.
    for deb, extract_dir in [
        ("libc6.deb", "extract/libc6"),
        ("linux_libc.deb", "extract/linux_libc"),
        ("libgcc.deb", "extract/libgcc"),
    ]:
        _run(
            ctx,
            "mkdir -p {dir} && (cd {dir} && ar x ../../{deb} && tar -xf data.tar.xz)".format(
                dir = extract_dir,
                deb = deb,
            ),
        )

    _run(ctx, "mkdir -p sysroot/include sysroot/lib/gcc")
    _run(ctx, "cp -a extract/libc6/usr/x86_64-linux-gnu/include/. sysroot/include/")
    _run(ctx, "cp -a extract/linux_libc/usr/x86_64-linux-gnu/include/. sysroot/include/")
    _run(ctx, "cp -a extract/libc6/usr/x86_64-linux-gnu/lib/. sysroot/lib/")
    _run(ctx, "cp -a extract/libgcc/usr/lib/gcc-cross/x86_64-linux-gnu sysroot/lib/gcc/")

    _patch_linker_scripts(ctx)
    _verify_sysroot(ctx)

    ctx.file(
        "BUILD.bazel",
        'filegroup(name = "sysroot", srcs = glob(["sysroot/**"]), visibility = ["//visibility:public"])\n',
    )

amd64_sysroot = repository_rule(
    implementation = _amd64_sysroot_impl,
    attrs = {
        "libc6_url": attr.string(
            mandatory = True,
            doc = "snapshot.debian.org URL of libc6-dev-amd64-cross_*.deb.",
        ),
        "libc6_sha256": attr.string(
            mandatory = True,
            doc = "sha256 of the libc6-dev-amd64-cross .deb.",
        ),
        "linux_libc_url": attr.string(
            mandatory = True,
            doc = "snapshot.debian.org URL of linux-libc-dev-amd64-cross_*.deb.",
        ),
        "linux_libc_sha256": attr.string(
            mandatory = True,
            doc = "sha256 of the linux-libc-dev-amd64-cross .deb.",
        ),
        "libgcc_url": attr.string(
            mandatory = True,
            doc = "snapshot.debian.org URL of libgcc-*-dev-amd64-cross_*.deb.",
        ),
        "libgcc_sha256": attr.string(
            mandatory = True,
            doc = "sha256 of the libgcc-*-dev-amd64-cross .deb.",
        ),
    },
    doc = "Downloads the three amd64-cross dev debs and merges them into a static sysroot/ tree.",
)