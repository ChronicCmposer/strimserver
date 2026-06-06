# syntax=docker/dockerfile:1

FROM amazonlinux:2023 AS builder

ARG OPENSSH_VERSION=10.3p1
ARG OPENSSH_TAG=V_10_3_P1
ARG OPENSSH_REPO=https://github.com/openssh/openssh-portable.git

RUN dnf install -y \
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
      file \
    && dnf clean all

WORKDIR /usr/src

RUN git clone --depth 1 --branch "${OPENSSH_TAG}" "${OPENSSH_REPO}" openssh \
   && cd openssh \
   && autoreconf -fiv \
   && ./configure --with-pam \
   && make sshd sshd-session sshd-auth -j"$(nproc)" \
   && rm -rf /tmp/openssh-root \
   && mkdir -p /tmp/openssh-root/var/empty/sshd \
   && make install-nokeys DESTDIR=/tmp/openssh-root

COPY sshd_config /tmp/openssh-root/usr/local/etc/sshd_config

RUN { \
      find /tmp/openssh-root -type d \
        -printf '%%dir /%P\n' | grep -v '^%dir /$'; \
      find /tmp/openssh-root/etc/ssh -type f \
        -printf '%%config(noreplace) /%P\n' 2>/dev/null || true; \
      find /tmp/openssh-root \( -type f -o -type l \) \
        ! -path '/tmp/openssh-root/etc/ssh/*' \
        -printf '/%P\n'; \
    } > /tmp/openssh-filelist

RUN cat > /tmp/openssh-experimental.spec <<EOF
%global debug_package %{nil}
%define _build_id_links none

Name: openssh-experimental
Version: ${OPENSSH_VERSION}
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
cp -a /tmp/openssh-root/. %{buildroot}/

%files -f /tmp/openssh-filelist
%defattr(-,root,root,-)
EOF

RUN mkdir -p /tmp/rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} /out \
    && rpmbuild -bb \
      --define "_topdir /tmp/rpmbuild" \
      /tmp/openssh-experimental.spec \
    && cp "$(find /tmp/rpmbuild/RPMS -name 'openssh-experimental-*.rpm' | head -n 1)" \
      /out/openssh-experimental.rpm

FROM scratch AS artifact
COPY --from=builder /out/openssh-experimental.rpm /openssh-experimental.rpm
