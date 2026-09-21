"""Downloads a .deb from snapshot.debian.org and extracts it for Bazel.

The repo's apt extension (@trixie) already delivers *runtime* donor debs for
the FROM-scratch images, but it only exposes each package as a whole
content.tar.gz (:data) plus a filemap; it cannot surface individual header
files as cc_library inputs. The dev debs here (libprotobuf-dev, libprotoc-dev,
protobuf-compiler) are *build-time* tooling for the protoc-gen-c plugin, so
they are fetched and extracted by this repo rule instead.

The .deb is a plain `ar` archive holding control.tar.xz + data.tar.xz; both
`ar` and `tar` are POSIX tools present on every Linux build host (the repo's
other repo rules already assume a Unix toolchain, e.g. qemu_x86_64.bzl).
"""
def _deb_extract_impl(ctx):
    ctx.download(
        url = ctx.attr.url,
        output = "package.deb",
        sha256 = ctx.attr.sha256,
    )
    for command, args in [
        ("ar", ["x", "package.deb"]),
        ("tar", ["-xf", "data.tar.xz"]),
    ]:
        result = ctx.execute([command] + args, quiet = True)
        if result.return_code != 0:
            fail(
                "{name}: `{command}` failed (exit {code}):\n{stderr}".format(
                    name = ctx.name,
                    command = command,
                    code = result.return_code,
                    stderr = result.stderr,
                ),
            )
    ctx.file("BUILD.bazel", ctx.attr.build_file_content)

deb_extract = repository_rule(
    implementation = _deb_extract_impl,
    attrs = {
        "url": attr.string(
            mandatory = True,
            doc = "snapshot.debian.org .deb URL (or any ar-archive .deb URL).",
        ),
        "sha256": attr.string(
            mandatory = True,
            doc = "sha256 of the .deb file.",
        ),
        "build_file_content": attr.string(
            mandatory = True,
            doc = "BUILD.bazel content for the extracted tree.",
        ),
    },
    doc = "Downloads a .deb and extracts it with ar + tar.",
)