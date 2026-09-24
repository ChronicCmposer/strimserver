/*
 * config.h for the vendored wslay 1.1.1 build.
 *
 * Mirrors what upstream's autotools `configure` generates on Linux/glibc
 * (wslay 1.1.1 config.h.in). The sources gate only on HAVE_ARPA_INET_H,
 * HAVE_NETINET_IN_H, HAVE_WINSOCK2_H and WORDS_BIGENDIAN; the remaining
 * defines are the standard glibc feature set so future macro gates resolve
 * the same way the upstream build resolves them. WORDS_BIGENDIAN is
 * deliberately left undefined: both target arches (linux/amd64 and
 * linux/arm64) are little-endian.
 *
 * This file is included via `#include <config.h>` guarded by HAVE_CONFIG_H,
 * which the Bazel build defines on the compile command line.
 */
#ifndef WSLAY_CONFIG_H
#define WSLAY_CONFIG_H

/* Both target arches (linux/amd64, linux/arm64) are little-endian. */
/* #undef WORDS_BIGENDIAN */

/* glibc provides these on both target arches. */
#define HAVE_ARPA_INET_H 1
#define HAVE_DLFCN_H 1
#define HAVE_HTONS 1
#define HAVE_INTTYPES_H 1
#define HAVE_MEMMOVE 1
#define HAVE_MEMORY_H 1
#define HAVE_MEMSET 1
#define HAVE_NETINET_IN_H 1
#define HAVE_NTOHL 1
#define HAVE_NTOHS 1
#define HAVE_PTRDIFF_T 1
#define HAVE_STDDEF_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
/* No Winsock on Linux. */
/* #undef HAVE_WINSOCK2_H */

#define LT_OBJDIR ".libs/"
#define STDC_HEADERS 1

#define PACKAGE "wslay"
#define PACKAGE_BUGREPORT "https://github.com/tatsuhiro-t/wslay/issues"
#define PACKAGE_NAME "wslay"
#define PACKAGE_STRING "wslay 1.1.1"
#define PACKAGE_TARNAME "wslay"
#define PACKAGE_URL ""
#define PACKAGE_VERSION "1.1.1"
#define VERSION "1.1.1"

#endif /* WSLAY_CONFIG_H */