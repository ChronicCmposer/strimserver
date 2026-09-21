"""Downloads and extracts a pinned tarball, then strips symlink loops.

The libwebsockets v5.0.0 upstream archive ships 12 self-referential
`libwebsockets` symlinks under minimal-examples/embedded/ that point back to
the repo root. Any whole-tree traversal (Bazel glob, cmake configure, tar
recursion) hangs on them, and Bazel's `patches` mechanism cannot delete a
symlink, so this repo rule extracts the archive and deletes the looping
links at fetch time.
"""
def _tarball_strip_symlinks_impl(ctx):
    ctx.download_and_extract(
        url = ctx.attr.url,
        sha256 = ctx.attr.sha256,
        stripPrefix = ctx.attr.strip_prefix,
    )
    # Guard: deleting every symlink named `libwebsockets` under the tree is
    # scoped to the embedded-example dirs (other symlinks, e.g. a docs
    # mount-origin link, are legitimate). `find -type l` is POSIX.
    result = ctx.execute(
        ["find", "minimal-examples", "minimal-examples-lowlevel", "-type", "l",
         "-name", "libwebsockets", "-delete"],
        quiet = True,
    )
    if result.return_code != 0:
        fail(
            "{name}: find -delete failed (exit {code}):\n{stderr}".format(
                name = ctx.name,
                code = result.return_code,
                stderr = result.stderr,
            ),
        )
    ctx.file("BUILD.bazel", ctx.attr.build_file_content)

tarball_strip_symlinks = repository_rule(
    implementation = _tarball_strip_symlinks_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(default = ""),
        "build_file_content": attr.string(mandatory = True),
    },
    doc = "Downloads a tarball, strips `libwebsockets` symlink loops, and " +
          "writes a BUILD file over the extracted tree.",
)