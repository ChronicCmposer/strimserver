// Version defines for the vendored protobuf-c plugin. Bazel copts mangle
// quoted strings, so the PACKAGE_* macros live in a header instead of -D
// flags. These are only used by the deprecated `protoc-c` standalone entry
// point (main.cc); the plugin mode used by this repo never prints them.
#define PACKAGE_STRING "protobuf-c 1.5.2"
#define PACKAGE_VERSION "1.5.2"
