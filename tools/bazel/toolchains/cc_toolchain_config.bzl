"""cc_toolchain_config for the clang x86_64-linux cross toolchain.

Part of workstream A2: this toolchain executes on the aarch64 dev host
(exec = aarch64) and targets linux/amd64, so
//core/controller/alternate/asm:controller_asm_x86_64 compiles and assembles on the aarch64
host without qemu.

Tool binaries are the host's own Debian clang/lld/llvm-ar, referenced by
absolute path exactly like the generated @local_config_cc toolchain wires
/usr/bin/gcc on this host. Target headers and static libs come from the
@amd64_sysroot repository (workstream A1), whose merged tree is laid out as
sysroot/include + sysroot/lib + sysroot/lib/gcc and is visible from the
execroot at the canonical repo path external/+amd64_sysroot+amd64_sysroot/
(see the SYSROOT constant below).

This config is C-only: the toolchain feeds the vendored C protocol layer and
the .S modules, so it links libgcc (--rtlib=libgcc) and deliberately never
adds -lstdc++ or -static globally (the controller's own linkopts carry
-static). The toolchain is registered only for amd64 targets; arm64 targets
and @bazel_tools' launcher_maker keep using native local_config_cc.
"""

load(
    "@rules_cc//cc/private/toolchain:unix_cc_toolchain_config.bzl",
    _cc_toolchain_config = "cc_toolchain_config",
)

# Host tool binaries (absolute paths, resolved on the exec platform at action
# time — the same pattern the generated @local_config_cc toolchain uses).
CLANG_BIN = "/usr/bin/clang"
CLANG_CPP_BIN = "/usr/bin/clang-cpp"
LLD_BIN = "/usr/bin/ld.lld"
LLVM_AR_BIN = "/usr/bin/llvm-ar"

# `clang -print-resource-dir` on this host: the arch-independent builtin
# headers shipped with clang 21.1.8 (stddef, stdatomic, x86 intrinsics, ...).
CLANG_RESOURCE_DIR = "/usr/lib/llvm-21/lib/clang/21"
# Debian also exposes the resource dir through a /usr/lib/clang/21 symlink
# tree; the compiler can emit either form in its depfile, and Bazel's
# absolute-path-inclusion check compares the raw depfile path, so both forms
# are declared as builtin include dirs.
CLANG_RESOURCE_DIR_SYMLINK = "/usr/lib/clang/21"

# The @amd64_sysroot merged tree as seen from the execroot. Relative paths in
# cxx_builtin_include_directories / builtin_sysroot / -L resolve against the
# action working directory, which is the execroot.
#
# NOTE the exec path: repos instantiated in MODULE.bazel via use_repo_rule
# carry the canonical name "+<rule_name>+<repo_name>", so @amd64_sysroot
# (rule amd64_sysroot, name amd64_sysroot) lands at
# external/+amd64_sysroot+amd64_sysroot/ — NOT external/amd64_sysroot
# (verified with `bazel aquery` on the CppLink action inputs).
SYSROOT = "external/+amd64_sysroot+amd64_sysroot/sysroot"

# A1's amd64_sysroot.bzl merges the libgcc-14-dev-amd64-cross deb keeping its
# natural subpath: sysroot/lib/gcc/x86_64-linux-gnu/14/ holds the gcc-14
# support libs (libgcc.a, crtbegin*/crtend*) and include/ the gcc runtime
# headers; the glibc crt1/crti/crtn objects and libc.a sit directly in
# sysroot/lib/.
GCC_TRIPLE_DIR = "x86_64-linux-gnu/14"

# ISA floor x86-64-v4 with the AVX-512 feature set the floor implies explicitly
# disabled (the cap is AVX2 — no zmm/k/AMX), mirroring
# //core/controller/alternate/asm:controller_asm_lib_x86_64. Applied to every compile and
# preprocess_assemble action so the .S modules are gated identically to the C.
ISA_FLOOR = [
    "-march=x86-64-v4",
    "-mno-avx512f",
    "-mno-avx512vl",
    "-mno-avx512bw",
    "-mno-avx512dq",
    "-mno-avx512cd",
]

# Determinism: pin __DATE__/__TIMESTAMP__/__TIME__ and silence clang's warning
# about redefining its builtin macros (matters under -Wall -Wextra -Werror).
DETERMINISM_FLAGS = [
    "-Wno-builtin-macro-redefined",
    '-D__DATE__="redacted"',
    '-D__TIMESTAMP__="redacted"',
    '-D__TIME__="redacted"',
]

def cc_toolchain_config(name):
    """Instantiates the clang x86_64-linux cross C++ toolchain config."""
    _cc_toolchain_config(
        name = name,
        cpu = "k8",
        compiler = "clang",
        toolchain_identifier = "clang-x86_64-linux-cross",
        host_system_name = "aarch64",
        target_system_name = "x86_64-unknown-linux-gnu",
        target_libc = "glibc_2.41",
        abi_version = "local",
        abi_libc_version = "local",
        tool_paths = {
            "gcc": CLANG_BIN,
            "ld": LLD_BIN,
            "ar": LLVM_AR_BIN,
            "cpp": CLANG_CPP_BIN,
            # Tools a C-only toolchain never invokes. /bin/false fails loudly if
            # anything ever tries (fail fast instead of silently misassembling).
            "dwp": "/bin/false",
            "gcov": "/bin/false",
            "nm": "/bin/false",
            "objcopy": "/bin/false",
            "objdump": "/bin/false",
            "strip": "/bin/false",
            "c++filt": "/bin/false",
            "cpp-module-deps-scanner": "/bin/false",
        },
        cxx_builtin_include_directories = [
            CLANG_RESOURCE_DIR,
            CLANG_RESOURCE_DIR_SYMLINK,
            SYSROOT + "/include",
            SYSROOT + "/lib/gcc/" + GCC_TRIPLE_DIR + "/include",
        ],
        builtin_sysroot = SYSROOT,
        compile_flags = [
            "--target=x86_64-linux-gnu",
            "-B/usr/bin",
            "-no-canonical-prefixes",
            # Bazel 9 does not turn cxx_builtin_include_directories into
            # -isystem flags (they feed the undeclared-inclusion check only;
            # local_config_cc gets away with that because gcc/clang natively
            # find the host's /usr/include). With --sysroot pointing at the
            # merged sysroot tree, clang's default search looks in
            # <sysroot>/usr/include — which does not exist in this layout — so
            # the sysroot header dirs must be passed explicitly.
            "-isystem", SYSROOT + "/include",
            "-isystem", SYSROOT + "/lib/gcc/" + GCC_TRIPLE_DIR + "/include",
        ] + ISA_FLOOR + DETERMINISM_FLAGS,
        conly_flags = ["-std=gnu11"],
        link_flags = [
            "--target=x86_64-linux-gnu",
            "-fuse-ld=lld",
            "--ld-path=" + LLD_BIN,
            "-no-canonical-prefixes",
            # The merged sysroot splits its static libs across two dirs: the
            # glibc crt objects + libc.a under sysroot/lib, and the gcc-14
            # runtime (libgcc.a, crtbegin*/crtend*) under
            # sysroot/lib/gcc/x86_64-linux-gnu/14. lld only searches what -L
            # says (clang's implicit sysroot multiarch dirs don't match this
            # merged layout), so both dirs are explicit.
            "-L" + SYSROOT + "/lib",
            "-L" + SYSROOT + "/lib/gcc/" + GCC_TRIPLE_DIR,
            "-Wl,--build-id=md5",
            "--rtlib=libgcc",
        ],
    )