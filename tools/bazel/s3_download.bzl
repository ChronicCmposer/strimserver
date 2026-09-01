"""Env-driven S3 downloads with a GitHub Release mirror fallback.

STRIMSERVER_S3_BUCKET and STRIMSERVER_S3_REGION
    When BOTH are set, the virtual-hosted S3 URL
    https://s3.<REGION>.amazonaws.com/<BUCKET>/<s3_key> is tried first, then
    mirror_urls. When either is unset, only mirror_urls are used (the GitHub
    Release fallback). Setting exactly one of the two is an error: a
    half-configured bucket must not silently resolve to the mirror.

    These are repo-rule env vars: Bazel reads them only when the repository
    is (re)fetched, so changing STRIMSERVER_S3_BUCKET or
    STRIMSERVER_S3_REGION after a build requires `bazel shutdown` and a
    re-run, or passing --repo_env=STRIMSERVER_S3_BUCKET=... /
    --repo_env=STRIMSERVER_S3_REGION=... on the command line.
"""

def _urls(ctx, s3_key):
    """Build the download URLs: the S3 endpoint first, then the mirrors."""
    bucket = ctx.getenv("STRIMSERVER_S3_BUCKET")
    region = ctx.getenv("STRIMSERVER_S3_REGION")

    if (bucket == None) != (region == None):
        fail(
            "STRIMSERVER_S3_BUCKET and STRIMSERVER_S3_REGION must be set together " +
            "(bucket=%r, region=%r); unset both to use mirror_urls." % (bucket, region),
        )

    urls = []
    if bucket != None:
        urls.append("https://s3.%s.amazonaws.com/%s/%s" % (region, bucket, s3_key))
    urls.extend(ctx.attr.mirror_urls)

    if not urls:
        fail("no download URLs: STRIMSERVER_S3_BUCKET/STRIMSERVER_S3_REGION are unset and mirror_urls is empty")

    return urls

def _s3_http_archive_impl(ctx):
    ctx.download_and_extract(
        url = _urls(ctx, ctx.attr.s3_key),
        sha256 = ctx.attr.sha256,
        stripPrefix = "",
    )
    if ctx.attr.build_file_content:
        ctx.file("BUILD.bazel", ctx.attr.build_file_content)

s3_http_archive = repository_rule(
    implementation = _s3_http_archive_impl,
    attrs = {
        "s3_key": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "mirror_urls": attr.string_list(mandatory = True),
        "build_file_content": attr.string(),
    },
    environ = ["STRIMSERVER_S3_BUCKET", "STRIMSERVER_S3_REGION"],
)

def _s3_http_file_impl(ctx):
    # Two modes, selected by whether build_file_content is set:
    #
    # 1. build_file_content set (root-addressable exports_files mode): the
    #    artifact is downloaded to the repo ROOT under downloaded_file_name
    #    and a root BUILD.bazel declares it. A bare file (no archive suffix,
    #    e.g. an .rpm) is placed directly in the repo root and addressed as
    #    @<repo>//:<downloaded_file_name> via exports_files. This is the
    #    pattern used by @ffmpeg_dist/@mediamtx_dist and @openssh_dist.
    #
    # 2. build_file_content unset: the artifact is downloaded under file/ and
    #    `@<repo>//file` is a package (no colon), so a BUILD file inside the
    #    file/ directory wraps it; the default target `file` keeps consumers
    #    at @<repo>//file. Unlike exports_files, a filegroup is not implicitly
    #    visible, so public visibility is granted explicitly.
    if ctx.attr.build_file_content:
        ctx.download(
            url = _urls(ctx, ctx.attr.s3_key),
            output = ctx.attr.downloaded_file_name,
            sha256 = ctx.attr.sha256,
        )
        ctx.file("BUILD.bazel", ctx.attr.build_file_content)
    else:
        ctx.download(
            url = _urls(ctx, ctx.attr.s3_key),
            output = "file/" + ctx.attr.downloaded_file_name,
            sha256 = ctx.attr.sha256,
        )
        ctx.file(
            "file/BUILD.bazel",
            'filegroup(name = "file", srcs = ["%s"], visibility = ["//visibility:public"])' % ctx.attr.downloaded_file_name,
        )

s3_http_file = repository_rule(
    implementation = _s3_http_file_impl,
    attrs = {
        "s3_key": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "mirror_urls": attr.string_list(mandatory = True),
        "downloaded_file_name": attr.string(mandatory = True),
        # When set, downloads the artifact to the repo ROOT (output =
        # downloaded_file_name) and writes it as a root BUILD.bazel, enabling
        # root-addressable exports_files targets like
        # @openssh_dist//:openssh-experimental.rpm. When unset, the artifact
        # is placed under file/ and wrapped by a synthesized filegroup "file".
        "build_file_content": attr.string(),
    },
    environ = ["STRIMSERVER_S3_BUCKET", "STRIMSERVER_S3_REGION"],
)