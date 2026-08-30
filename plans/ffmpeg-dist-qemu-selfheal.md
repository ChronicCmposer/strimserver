---
status: executed
phase: 1
updated: 2026-08-30
---

# Implementation Plan: Self-healing patched-qemu source build in tools/ffmpeg-dist

> **Status: executed.** This plan was carried out with a revision: the
> qemu pin is **8.2.2** with a hand-ported v8.1 patch set, not 8.1.5 +
> the stock v8.1 set (see the REVISED decision and Implementation note
> below). Implementation is complete: acceptance sha
> `2df93667c7e12f2666be244772a41c653a02cab74880e685623770bd9c86ac34`
> reproduced, and the negative tests (unpatched emulator rejected /
> fails fast at the execve probe) passed.

## Goal
Replace publish.sh's broken `QEMU_IMAGE` registry auto-fetch with a source-build fallback (`build-qemu.sh`) that compiles the buildkit-direct-execve patched qemu-x86_64 from downloadable inputs, keeping the FFmpeg artifact byte-identical (sha256 `2df93667c7e12f2666be244772a41c653a02cab74880e685623770bd9c86ac34`).

## Context & Decisions
| Decision | Rationale | Source |
|----------|-----------|--------|
| Source-build the patched qemu (no vendored 15MB binary) | No prebuilt patched qemu exists anywhere: all `tonistiigi/binfmt` tags are unpatched (no `safe_execve`), `qemu-v8.2.2` tag is dead/absent, buildkit releases skip 8.2.x (7.1.0 → 9.2.x) | `ref:ses_fab976d83ffe309A1Q7AFzn73h` |
| **REVISED:** Pin qemu to **8.2.2** with a hand-ported version of the `buildkit-direct-execve-v8.1` patch set (0004/0005 ported to 8.2.2's `ImageSource` API; no upstream v8.2 patch set exists — tonistiigi/binfmt jumps v8.1 → v9.2) | 8.1.5 acceptance failed byte-identity (guest CPUID differs from 8.2.2); 8.2.2 reproduces the pinned sha256 `2df93667…` (see Implementation note below) | `ref:ses_fab976d83ffe309A1Q7AFzn73h` |
| Commit the 7 patch files into the repo (`tools/ffmpeg-dist/qemu-patches/`) | Deterministic + offline; `raw.githubusercontent.com` master is mutable | repo philosophy (pinned inputs) |
| Remove `QEMU_IMAGE` env + `fetch_patched_qemu()` + `docker_arch()` from publish.sh | The auto-fetch fetches an **unpatched** qemu that ENOEXECs on the first guest child — a non-working default that must not ship | `ref:ses_fac8b070dffeaT6gjfsQUS0yR4` |
| Add an **execve-interception probe** as the first step of guest `build.sh` | Fail fast with a clear message instead of a mid-build ENOEXEC surprise; passes trivially on the native docker path | `ref:ses_fac8b070dffeaT6gjfsQUS0yR4` |
| Validate the resolved qemu statically (`file` static-pie, `strings` → `safe_execve`, `--version`) at resolve time | Cheap discriminator between patched and unpatched binaries; catches a stale/unpatched cache | `ref:ses_fab976d83ffe309A1Q7AFzn73h` |
| Docs (README + plan doc) ship in the same scoped commit (user-approved) | Single atomic change; docs describe the shipped behavior | user decision |
| Persist this plan as `plans/ffmpeg-dist-qemu-selfheal.md` (repo style) as the executing agent's first step | Executing agent needs the recipe in-repo; matches plans/ convention | repo convention |

**Implementation note:** the 8.2.2 pin is the implementation. Acceptance
testing built qemu 8.1.5 + the stock v8.1 patch set first, but that
combination failed the byte-identity contract: 8.1.5 exposes a different
guest CPUID than 8.2.2 (leaf 0x07 EBX bit 29, AVX512_BF16 — 8.1.5:
`0x01dc47a9`, 8.2.2: `0x21dc47a9`), which changes compiler/nvcc codegen
and produces a non-byte-identical ffmpeg binary. 8.2.2 reproduces the
pinned sha256 `2df93667c7e12f2666be244772a41c653a02cab74880e685623770bd9c86ac34`.

## Phase 1: Recon [PENDING]
- [ ] **1.1 Enumerate patch-set versions** — fetch `https://api.github.com/repos/tonistiigi/binfmt/contents/patches`; list available directories (expect `buildkit-direct-execve-v8.1`; check whether a `v8.2` set exists). Record exact patch filenames + URLs. ← CURRENT
- [ ] 1.2 Choose (qemu version, patch set): if `v8.2` exists → **qemu 8.2.2**; else **qemu 8.1.5 + v8.1 set**. Download `https://download.qemu.org/qemu-<ver>.tar.xz`, compute and record its sha256.
- [ ] 1.3 Confirm host build deps present: `meson`, `ninja`, `python3`, `pkg-config`, `gcc`, `libglib2.0-dev`. Do **not** install system-wide; if missing, fail loudly with the exact `apt-get install` command.

## Phase 2: Implement [PENDING]
- [ ] 2.1 Add `tools/ffmpeg-dist/qemu-patches/*.patch` — the 7 tonistiigi patch files with a provenance header (source URL, commit, qemu version targeted).
- [ ] 2.2 Create `tools/ffmpeg-dist/build-qemu.sh` (mode 100755):
  - Pins: `QEMU_VERSION`, `QEMU_SOURCE_SHA256`, `QEMU_SOURCE_URL`, `QEMU_PATCH_DIR` (default `dirname $0`/qemu-patches), `QEMU_CACHE` (default `${XDG_CACHE_HOME:-$HOME/.cache}/ffmpeg-dist/qemu-x86_64-patched`), `NPROC` (default 4).
  - Idempotent: if cache exists **and** passes `file static-pie` + `strings safe_execve` + `--version` → exit 0.
  - Download tarball → `sha256sum -c` → extract → apply patches in order (`patch -p1`; any hunk failure → exit 1 with the documented hand-port fallback note from the first-build recipe).
  - Configure (from first-build recipe): `--python="$(command -v python3)" --target-list=x86_64-linux-user --static --disable-system --disable-docs --disable-tools --disable-guest-agent --disable-werror` → `ninja -j$NPROC`.
  - Verify: `file` → static-pie; `strings | grep -c safe_execve` ≥ 1; `--version` → chosen version. Install to cache (`cp` + `chmod +x`). Echo `==> qemu: <path>`. `bash -n` passes.
- [ ] 2.3 Modify `tools/ffmpeg-dist/publish.sh`:
  - Delete `QEMU_IMAGE` env (line 74), its doc block (lines 37-42), `docker_arch()` (lines 111-118), `fetch_patched_qemu()` (lines 120-169).
  - `resolve_qemu()` becomes: `QEMU_BIN` (executable **and** `strings | grep -q safe_execve`, else warning → fall through) > cached qemu (re-validated) > `"$repo_root/tools/ffmpeg-dist/build-qemu.sh"` > loud error.
  - Update the header comment (lines 30-42) and the non-x86_64 error block (lines 194-209) to describe the source-build self-heal (no QEMU_IMAGE).
  - Keep `==> qemu:` echo; add `==> building patched qemu-x86_64 from source (qemu-<ver>) ...` before invoking build-qemu.sh. `bash -n` passes.
- [ ] 2.4 Modify `tools/ffmpeg-dist/build.sh` — insert the execve probe as the first command before phase 0:
  ```bash
  if ! /bin/sh -c 'exit 0' >/dev/null 2>&1; then
    echo "error: the qemu emulator cannot execute guest children (missing the buildkit-direct-execve patch)." >&2
    echo "       Provide QEMU_BIN=/var/tmp/ffmpeg-build/qemu-x86_64-patched or rebuild via build-qemu.sh." >&2
    exit 1
  fi
  ```
  (native docker path passes trivially; safe under `set -e` because it is inside `if !`.)

## Phase 3: Verify [PENDING]
- [ ] 3.1 Standalone: `rm -f "$cache"; ./tools/ffmpeg-dist/build-qemu.sh` → builds from source, passes all three checks, installs to cache.
- [ ] 3.2 **Acceptance**: delete cache, `env -u QEMU_BIN`, then `cd tools/ffmpeg-dist && SKIP_UPLOAD=1 NPROC=4 ./publish.sh` → `==> sha256:` **MUST equal** `2df93667c7e12f2666be244772a41c653a02cab74880e685623770bd9c86ac34` (byte-identical; `cmp`/`diff` binary + BUILD-INFO.txt clean).
- [ ] 3.3 Negative: `QEMU_BIN=` an unpatched qemu (e.g. the 8.1.5 fetched earlier) → build must fail fast at the execve probe with the clear error (or be rejected at resolve time).
- [ ] 3.4 Confirm the consumer is unaffected: `bazel build //:package` still succeeds; the canary workflow (amd64 native sudo chroot) needs no change.

## Phase 4: Docs + commit [PENDING]
- [ ] 4.1 README "Rebuilding the FFmpeg artifact": rewrite the QEMU_BIN paragraph → describe the source-build self-heal (qemu `<ver>` + committed tonistiigi patches, cache path, host build deps on non-amd64 hosts); drop QEMU_IMAGE.
- [ ] 4.2 `plans/ffmpeg-prebuilt-artifact.md`: add deviation #11 (qemu source-build; all registry tags unpatched; QEMU_IMAGE removed).
- [ ] 4.3 Scoped commit: `tools/ffmpeg-dist/{build-qemu.sh, qemu-patches/*, publish.sh, build.sh}`, `README.md`, plan doc (`plans/ffmpeg-dist-qemu-selfheal.md`). **Never** stage the 10 pre-existing dirty files or untracked junk; repo-local identity `Claude <noreply@anthropic.com>`; post-commit `git log -1 --stat` + `git status --short` to confirm scope.

## Notes
- The qemu binary itself is **not** bit-reproducible across builds (not required — only the FFmpeg artifact sha is the contract); the cache prevents rebuilds.
- The 8.2.2 hand-port **is** the implementation, not a fallback: patches 0001–0003, 0006, and 0007 apply cleanly to 8.2.2; 0004 and 0005 were hand-ported to the `ImageSource` API (`bprm->src.fd`) along with the `get_elf_eflags` seek-reset fix (first-build recipe recovered in `/tmp/first_build_dump.txt`).
- 2026-08-30: qemu sourcing forensics completed — patched qemu 8.2.2 at /var/tmp was built from source (qemu-8.2.2.tar.xz + hand-ported v8.1 patches); no prebuilt patched qemu exists in any registry/release `ref:ses_fab976d83ffe309A1Q7AFzn73h`

## Constraints
- Create ONLY this one file. Do not create, modify, or delete any other file in the repo. Do not run any part of the plan's implementation (no recon, no builds, no commits, no git add).
- Verify afterward by reading the file back and diffing it against the content above — it must match character-for-character, including the YAML frontmatter, the em-dashes, the `← CURRENT` marker, the backticked code fence inside task 2.4, and the `ref:ses_...` citations.
- Report: the absolute path written, a byte/character count, and confirmation that no other repo files were touched.