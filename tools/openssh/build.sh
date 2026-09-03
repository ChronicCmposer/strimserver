#!/usr/bin/env bash
# =============================================================================
# tools/openssh/build.sh -- build the openssh-experimental RPM inside an
# amazonlinux:2023 rootfs.
#
# Single source of truth for the pinned OpenSSH artifact build.
# Runs inside the chroot that tools/openssh/publish.sh provisions from the
# Docker Hub registry API (no docker): the guest executes
# /build.sh via chroot (+ qemu-x86_64 when the host is not amd64).
#
# $1 is the rootfs path -- "/" inside the chroot (publish.sh passes it, so the
# script is also usable pointed at an already-extracted rootfs for testing).
# Every mutable path is prefixed with it; no host-absolute path is referenced.
#
# Pins (env-overridable):
#   OPENSSH_TAG     V_10_5_P1            (git tag/branch to clone)
#   OPENSSH_VERSION 10.5p1               (informational; RPM Version is 10.5)
#   OPENSSH_REPO    https://github.com/openssh/openssh-portable.git
#   NPROC           (host nproc)
#
# Output: /out/openssh-experimental.rpm (publish.sh copies it out of the rootfs).
# =============================================================================
set -euo pipefail

# --- execve-interception probe (fail fast on an unpatched qemu) --------------
# Under a patched (buildkit-direct-execve) qemu the guest's /bin/sh re-execs
# via qemu itself; an unpatched qemu ENOEXECs the first guest child. Probe the
# capability up front so the failure is a clear message, not a mid-build
# surprise. Passes trivially on a native amd64 chroot (safe under set -e
# because the guard is inside `if !`).
if ! /bin/sh -c 'exit 0' >/dev/null 2>&1; then
    echo "error: the qemu emulator cannot execute guest children (missing the buildkit-direct-execve patch)." >&2
    echo "       Provide QEMU_BIN=/var/tmp/ffmpeg-build/qemu-x86_64-patched or rebuild via tools/qemu/build-qemu.sh." >&2
    exit 1
fi

# --- inputs ------------------------------------------------------------------
rootfs="${1:-/}"
OPENSSH_TAG="${OPENSSH_TAG:-V_10_5_P1}"
OPENSSH_VERSION="${OPENSSH_VERSION:-10.5p1}"
OPENSSH_REPO="${OPENSSH_REPO:-https://github.com/openssh/openssh-portable.git}"
NPROC="${NPROC:-$(nproc)}"
# Static GNU m4 for the qemu workaround (see the autoreconf branch below);
# pinned source tarball, verified by sha256 before use.
M4_SOURCE_URL="${M4_SOURCE_URL:-https://ftp.gnu.org/gnu/m4/m4-1.4.21.tar.gz}"
M4_SOURCE_SHA256="${M4_SOURCE_SHA256:-38ae59f7a30bf9c108193cc5c25fbb06014f21e230c7ede2eff614f7b7c37ed8}"

src_dir="$rootfs/tmp/openssh-src"
destdir="$rootfs/tmp/openssh-root"
rpmbuild_top="$rootfs/tmp/rpmbuild"
filelist="$rootfs/tmp/openssh-filelist"
spec_file="$rootfs/tmp/openssh-experimental.spec"
out_dir="$rootfs/out"

# --- idempotency: clean every prior build state ------------------------------
# The source tree is preserved for incremental-make resume (see below) and only
# rebuilt when it doesn't match the pinned commit; staging + output state is
# always regenerated.
rm -rf "$destdir" "$rpmbuild_top" "$filelist" "$spec_file"
# The rootfs is persistent, so a failed build's RPM would linger and pass a
# later verification as if it were fresh; remove it before every build.
rm -f "$out_dir/openssh-experimental.rpm"

# --- build deps --------------------------------------------------------------
dnf install -y \
    git \
    gcc \
    make \
    autoconf \
    automake \
    libtool \
    perl \
    zlib-devel \
    openssl-devel \
    pam-devel \
    rpm-build \
    findutils \
    file
dnf clean all

# --- clone openssh-portable at the pinned tag, configure, build ---------------
# --with-pam matches the pinned artifact contract; the deps above provide the
# PAM + openssl headers it needs. The full tree is built because
# install-nokeys/install-files installs every binary (ssh, ssh-add, ssh-keygen,
# ssh-keyscan, ssh-agent, scp, sftp, ssh-keysign, sftp-server, ...), not just
# the daemon + session/auth helpers -- install-files is not a build
# prerequisite of its own recipes, so the full set must be built up front.
#
# Incremental-make resume: the rootfs cache is keyed on every build-determining
# pin (AMAZONLINUX_TAG + OPENSSH_TAG + QEMU_VERSION), so a cached rootfs holds
# the identical source + toolchain. Reuse the source tree only when it is
# verifiably at the pinned commit AND already configured (Makefile present);
# otherwise wipe and rebuild clean. The commit marker records the resolved HEAD
# from the first clone so a resumed build can detect a force-moved tag. Note
# the OpenSSH Makefile depends on config.h, so re-running configure would force
# a full rebuild -- that is exactly why configure is skipped on reuse.
commit_marker="$rootfs/tmp/openssh-commit"
reuse=0
if [[ -f "$src_dir/Makefile" && -f "$commit_marker" ]] \
     && [[ "$(git -C "$src_dir" rev-parse HEAD 2>/dev/null)" == "$(cat "$commit_marker" 2>/dev/null)" ]]; then
    reuse=1
    echo "==> reusing openssh source tree (matches pinned commit)"
fi
if [[ "$reuse" != 1 ]]; then
    rm -rf "$src_dir"
    git clone --depth 1 --branch "$OPENSSH_TAG" "$OPENSSH_REPO" "$src_dir"
    git -C "$src_dir" rev-parse HEAD > "$commit_marker"
fi
cd "$src_dir"
# autoreconf is normally unnecessary: openssh-portable commits the generated
# autotools outputs (configure, aclocal.m4, config.h.in, Makefile.in) at every
# release tag (configure.ac uses only autoconf macros -- no libtool/automake).
# A git checkout does not preserve the release tarball's mtimes, so a freshly
# cloned configure can end up older than the checked-in m4/openssh.m4, and
# autoconf's generated configure then refuses to run ("m4/openssh.m4 newer
# than configure, run autoreconf"). Regenerate whenever configure is missing
# OR stale (the exact predicate autoconf itself fails on).
if [[ "$reuse" != 1 ]]; then
    if [[ ! -f configure ]] || [[ m4/openssh.m4 -nt configure ]]; then
        # The guest /usr/bin/m4 (amazonlinux:2023 glibc) crashes qemu under the
        # buildkit-direct-execve emulator on non-x86_64 hosts (QEMU internal SIGSEGV
        # on its /proc/self/maps emulation -- the same glibc loader/string code
        # paths that break grep/awk, worked around with sed above), so autom4te
        # dies with "need GNU m4 1.4 or later" and aborts autoreconf. Work around it
        # by building a static GNU m4 from the pinned source tarball and prepending
        # its bin dir to PATH so autom4te uses it instead: a static binary never
        # takes the dynamic loader's /proc/self/maps path that trips qemu, and it
        # produces the same configure output as the guest m4. This engages only
        # when qemu is actually in play (publish.sh installs
        # /usr/local/bin/qemu-x86_64 into the rootfs solely on non-x86_64 hosts),
        # so a native amd64 run is completely unaffected.
        if [[ -x "$rootfs/usr/local/bin/qemu-x86_64" ]]; then
            m4_good_dir="$rootfs/tmp/m4-good"
            m4_bin="$m4_good_dir/usr/bin/m4"
            if [[ ! -x "$m4_bin" ]]; then
                echo "==> building a static GNU m4 (the guest /usr/bin/m4 crashes qemu)"
                dnf install -y glibc-static
                m4_tarball="$rootfs/tmp/m4-1.4.21.tar.gz"
                curl -fsSL --retry 3 -o "$m4_tarball" "$M4_SOURCE_URL"
                printf '%s  %s\n' "$M4_SOURCE_SHA256" "$m4_tarball" | sha256sum -c - >/dev/null
                mkdir -p "$rootfs/tmp/m4-src"
                tar -xzf "$m4_tarball" -C "$rootfs/tmp/m4-src"
                # m4's bundled gnulib gl_GNUmakefile macro AC_CONFIG_LINKS's GNUmakefile to
                # itself; under qemu srcdir resolves absolute, so config.status replaces the
                # real GNUmakefile with a self-referential symlink and GNU make dies with
                # "Too many levels of symbolic links". It is maintainer-only, so drop it and
                # let make read the automake Makefile. Also build 'all' before installing:
                # install-exec does not build first, so the noinst convenience library
                # ../lib/libm4.a would be missing when src/m4 links.
                (
                    cd "$rootfs/tmp/m4-src/m4-1.4.21" \
                        && ./configure --prefix=/usr --disable-shared LDFLAGS=-static \
                        && rm -f GNUmakefile \
                        && make -j"$NPROC" all \
                        && make -j"$NPROC" install-exec DESTDIR="$m4_good_dir"
                )
                # sed (not grep) for the static check: grep itself crashes qemu.
                file -b "$m4_bin" | sed -n '/statically linked/p' >/dev/null || {
                    echo "error: static m4 build failed; cannot run autoreconf under qemu." >&2
                    exit 1
                }
            fi
            PATH="$m4_good_dir/usr/bin:$PATH"
            export PATH
        fi
        autoreconf -fiv
    fi
    ./configure --with-pam
fi
make -j"$NPROC"

# --- install into a staging root (no host keys; they are generated at boot) ---
mkdir -p "$destdir/var/empty/sshd"
make -j"$NPROC" install-nokeys DESTDIR="$destdir"

# --- custom sshd_config: overwrite the stock one installed by make ------------
# make install-nokeys installs the source tree's sshd_config at the default
# sysconfdir (${prefix}/etc = /usr/local/etc); the repo's tuned copy replaces
# it there -- the only location the default-built sshd will read.
cp "$rootfs/sshd_config" "$destdir/usr/local/etc/sshd_config"

# --- rpm file list (find pipeline) -------------------------------------------
# NB: sed instead of grep for the directory filter: under the buildkit-direct-
# execve qemu on non-amd64 hosts, amazonlinux's grep/awk binaries crash qemu
# (QEMU internal SIGSEGV on their glibc string code paths); sed is unaffected
# and produces byte-identical output.
{
    find "$destdir" -type d \
        -printf '%%dir /%P\n' | sed -n '/^%dir \/$/!p'
    find "$destdir/etc/ssh" -type f \
        -printf '%%config(noreplace) /%P\n' 2>/dev/null || true
    find "$destdir" \( -type f -o -type l \) \
        ! -path "$destdir/etc/ssh/*" \
        -printf '/%P\n'
} > "$filelist"

# --- rpm spec (Version 10.5 / Release 1 per the migration plan) ---------------
cat > "$spec_file" <<EOF
%global debug_package %{nil}
%define _build_id_links none

Name: openssh-experimental
Version: 10.5
Release: 1
Summary: Experimental OpenSSH ${OPENSSH_VERSION} build
License: BSD
URL: https://www.openssh.com/portable.html

%description
Experimental OpenSSH build packaged from upstream portable OpenSSH source.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a ${destdir}/. %{buildroot}/

%files -f ${filelist}
%defattr(-,root,root,-)
EOF

# --- build the RPM ------------------------------------------------------------
mkdir -p "$rpmbuild_top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} "$out_dir"
rpmbuild -bb \
    --define "_topdir $rpmbuild_top" \
    "$spec_file"
rpm="$(find "$rpmbuild_top/RPMS" -name 'openssh-experimental-*.rpm' | head -n 1)"

# --- place the artifact -------------------------------------------------------
# The rootfs is persistent, so a stale /out from the old bind-mount era can
# survive a rebuild: a bind-mount whose source directory was deleted still
# stats as a directory (so `mkdir -p` no-ops) yet rejects new entries with
# ENOENT. Clear any leftover mount and recreate the plain directory
# immediately before the copy, so the artifact write cannot fail on a bad /out.
if mountpoint -q "$out_dir"; then
    if ! umount "$out_dir"; then
        echo "error: stale $out_dir mount could not be cleared; run publish.sh as root once (or delete the rootfs cache) so a fresh artifact directory can be created." >&2
        exit 1
    fi
fi
rm -rf "$out_dir"
mkdir -p "$out_dir"
cp "$rpm" "$out_dir/openssh-experimental.rpm"
echo "==> artifact: $out_dir/openssh-experimental.rpm"