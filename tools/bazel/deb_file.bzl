"""Extracts a single file, preserving its mode, from a deb package's
:data content tar (see @rules_distroless//apt). Used to hand-pick exactly
the files the scratch images need, matching core/Dockerfile's and
core/controller/Dockerfile's explicit `COPY --from=libs <one file>` lines,
without pulling in a package's full (sometimes surprisingly large, and not
necessarily relevant -- see nice's actual ldd vs coreutils' apt Depends:)
transitive closure for a single binary or .so.
"""

def deb_file(name, data, path, out = None):
    """
    Args:
        name: target name.
        data: label of a deb :data content.tar.gz.
        path: path of the file inside that tar, e.g. "usr/bin/nice".
        out: output filename; defaults to path's basename.
    """
    out = out or path.split("/")[-1]
    native.genrule(
        name = name,
        srcs = [data],
        outs = [out],
        # deb_postfix's content.tar.gz stores members as "./usr/bin/foo", not
        # "usr/bin/foo" -- GNU tar matches the member name exactly.
        cmd = """
set -eu
tmp="$(RULEDIR)/{name}.extract_tmp"
rm -rf "$$tmp" && mkdir -p "$$tmp"
tar -xzf $(location {data}) -C "$$tmp" "./{path}"
cp -p "$$tmp/{path}" $@
rm -rf "$$tmp"
""".format(name = name, data = data, path = path),
    )
