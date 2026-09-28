/*
 * envfile.h — shared env-file parsing + template expansion for the
 * strimserver OCI image's static C binaries.
 *
 * License: project code (see LICENSE). No GPL.
 */

#ifndef STRIMSERVER_CORE_CONTROLLER_C_ENVFILE_H
#define STRIMSERVER_CORE_CONTROLLER_C_ENVFILE_H

#include <stddef.h>

/* Parse a /strimserver.env-style KEY="value" listing (comments, blanks,
 * optional `export` prefix, trailing-whitespace trim, double-quote
 * stripping) and setenv() each key. Returns 0 when the file is absent or
 * parsed cleanly; -1 with an err message on a malformed line or a setenv
 * failure. */
int source_env_file(const char *path, char *err, size_t err_cap);

/* Read template_path, substitute environment references — ${VAR}, $VAR
 * (undefined variables become the empty string) and $$ (a literal `$`) —
 * and write the result to output_path. Returns 0 on success; -1 with an
 * err message on read/write failure. */
int expand_template_file(const char *template_path, const char *output_path,
                         char *err, size_t err_cap);

#endif /* STRIMSERVER_CORE_CONTROLLER_C_ENVFILE_H */