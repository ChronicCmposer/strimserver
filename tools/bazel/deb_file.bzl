"""Extracts a single file, preserving its mode, from a deb package's
:data content tar (see @rules_distroless//apt). Used to hand-pick exactly
the files the FROM-scratch rules_oci images need out of the @trixie apt
snapshot (MODULE.bazel), without pulling in a package's full (sometimes
surprisingly large, and not necessarily relevant -- see nice's actual ldd
vs coreutils' apt Depends:) transitive closure for a single binary or .so.
"""

def deb_file(name, data, path, path_arm64 = None, out = None):
    """
    Args:
        name: target name.
        data: label of a deb :data content.tar.gz. May be the arch-selecting
            alias @trixie//<pkg>:data (resolves to /amd64:data or /arm64:data
            via the target platform) when both architectures are needed.
        path: path of the file inside that tar, e.g. "usr/bin/nice".
        path_arm64: optional arm64 variant of `path`, e.g.
            "usr/lib/aarch64-linux-gnu/libc.so.6". When set, the genrule cmd
            select()s between the amd64 and arm64 member paths, so one target
            serves both target architectures. `out` defaults to `path`'s
            basename (the amd64 name), keeping the amd64 output byte-identical.
        out: output filename; defaults to path's basename.
    """
    out = out or path.split("/")[-1]
    # deb_postfix's content.tar.gz stores members as "./usr/bin/foo", not
    # "usr/bin/foo" -- GNU tar matches the member name exactly.
    cmd_template = """
set -eu
tmp="$(RULEDIR)/{name}.extract_tmp"
rm -rf "$$tmp" && mkdir -p "$$tmp"
tar -xzf $(location {data}) -C "$$tmp" "./{path}"
cp -p "$$tmp/{path}" $@
rm -rf "$$tmp"
"""
    cmd = cmd_template.format(name = name, data = data, path = path)
    if path_arm64:
        # genrule cmd is a configurable string attribute; the branch is only
        # location-expanded for the selected target platform (verified).
        cmd = select({
            "//tools/bazel:is_amd64_target": cmd,
            "//tools/bazel:is_arm64_target": cmd_template.format(name = name, data = data, path = path_arm64),
        })
    native.genrule(
        name = name,
        srcs = [data],
        outs = [out],
        cmd = cmd,
    )
