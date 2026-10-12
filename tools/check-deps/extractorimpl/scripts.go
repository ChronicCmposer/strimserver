package extractorimpl

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// pinSpec describes one version pin to scrape from a shell script. The first
// capture group of re is the pinned version. role marks an opaque
// integrity/reproducibility pin (a hash, epoch, or commit) that has no
// comparable upstream version; it classifies as integrity and needs no
// resolver. An empty role is a normal version pin.
type pinSpec struct {
	name     string
	category string
	re       *regexp.Regexp
	source   string
	note     string // static annotation, overridden by noteFrom when set
	noteFrom func(version string) string
	role     string
}

var (
	qemuConsumerVersionRe = regexp.MustCompile(`QEMU_VERSION="\$\{QEMU_VERSION:-([0-9][0-9.]*)\}"`)
	qemuDistlibRe         = regexp.MustCompile(`QEMU_DISTLIB_URL:[-=][^"}]*distlib-([0-9]+\.[0-9]+\.[0-9]+)-py2`)

	// bzlQemuVersionRe targets only the qemu_x86_64 repo-rule's qemu_version
	// attr default. The attr.string( ... default = "...") shape keeps it from
	// matching build_script (attr.label) or build_timeout (attr.int).
	bzlQemuVersionRe = regexp.MustCompile(`"qemu_version": attr\.string\(\s*default = "([0-9][0-9.]*)"`)

	opensshVersionRe = regexp.MustCompile(`OPENSSH_VERSION:[-=]([^"}]+)\}`)
	opensshTagRe     = regexp.MustCompile(`OPENSSH_TAG:[-=]([^"}]+)\}`)

	ffmpegVersionRe  = regexp.MustCompile(`FFMPEG_VERSION:[-=]([0-9]+\.[0-9]+)\}`)
	nvCodecHeadersRe = regexp.MustCompile(`NV_CODEC_HEADERS_TAG:[-=]([^"}]+)\}`)
	cudaManifestRe   = regexp.MustCompile(`CUDA_MANIFEST_URL:[-=][^"}]*redistrib_([0-9]+\.[0-9]+\.[0-9]+)\.json`)
	debianSnapshotRe = regexp.MustCompile(`DEBIAN_SNAPSHOT:[-=]([0-9]{8}T[0-9]{6}Z)\}`)

	// dlamiAmiIDRe targets the pinned AMI constant in deploy/aws/launch. The
	// launch default is a hard-coded ami id (not the floating SSM resolution),
	// so the regex reads exactly the DEFAULT_AMI_ID assignment.
	dlamiAmiIDRe = regexp.MustCompile(`DEFAULT_AMI_ID = "(ami-[0-9a-f]{8,17})"`)

	// ffmpegCommitRe and nvCodecHeadersCommitRe capture the exact 40-hex git
	// commits the two ffmpeg-dist components are checked out at (the tag is
	// only a readability alias; the commit is the determinism pin). The
	// `NAME:[-=]...` shape matches both the `: "${NAME:=...}"` (build.sh) and
	// `NAME="${NAME:-...}"` (publish.sh) env-default forms, while the trailing
	// `\}` anchors on the closing brace so the `${NAME:0:7}` substring
	// expansions elsewhere in publish.sh cannot match.
	ffmpegCommitRe         = regexp.MustCompile(`FFMPEG_COMMIT:[-=]([0-9a-f]{40})\}`)
	nvCodecHeadersCommitRe = regexp.MustCompile(`NV_CODEC_HEADERS_COMMIT:[-=]([0-9a-f]{40})\}`)
	// gencodeRe captures the nvcc -gencode target (e.g. arch=compute_75,code=sm_75).
	gencodeRe = regexp.MustCompile(`GENCODE:[-=](arch=compute_[0-9]+,code=sm_[0-9]+)\}`)

	// m4SourceSHA256Re captures the integrity hash of the pinned static GNU m4
	// tarball; sourceDateEpochRe captures the fixed reproducible-build clock.
	m4SourceSHA256Re  = regexp.MustCompile(`M4_SOURCE_SHA256:[-=]([0-9a-f]{64})\}`)
	sourceDateEpochRe = regexp.MustCompile(`SOURCE_DATE_EPOCH:[-=]([0-9]+)\}`)

	// qemuSourceHashRe captures every supported QEMU_VERSION case arm and the
	// sha256 it pins, e.g. `  8.2.2) QEMU_SOURCE_SHA256="${QEMU_SOURCE_SHA256:-<hash>}"`.
	// The anchored `^\s*<version>)` shape deliberately skips the `*)` fallback
	// arm (which carries no version and no verified hash).
	qemuSourceHashRe    = regexp.MustCompile(`(?m)^\s*([0-9]+\.[0-9]+\.[0-9]+)\)\s+QEMU_SOURCE_SHA256="\$\{QEMU_SOURCE_SHA256:-([0-9a-f]{64})\}"`)
	qemuDistlibSHA256Re = regexp.MustCompile(`QEMU_DISTLIB_SHA256:[-=]([0-9a-f]{64})\}`)

	// uploadExpectedSHA256Re captures the MODULE.bazel artifact pin checked by
	// scripts/upload-artifact.sh before it uploads.
	uploadExpectedSHA256Re = regexp.MustCompile(`EXPECTED_SHA256:[-=]([0-9a-f]{64})\}`)
	// fishDistRe extracts the pinned fish version from the release URL. The
	// version, not the URL, is the comparable pin.
	fishDistRe = regexp.MustCompile(`FISH_DIST_URL="https://github\.com/fish-shell/fish-shell/releases/download/([0-9]+\.[0-9]+\.[0-9]+)/fish-`)

	// scriptPinCarrierRe is the fail-closed discovery detector: it reports a
	// script that assigns a *_VERSION, *_SHA256, or *_COMMIT pin to a
	// non-empty value but has no dedicated extractor spec. It matches a plain
	// `NAME=value` assignment or the `NAME:-value` / `NAME:=value` env-default
	// forms, requiring the first value character to be present and not a
	// quote, brace, separator, `$`, or whitespace. That excludes the empty
	// default `NAME:-}`, the left-hand half of `NAME="${NAME:-...}"`, a bare
	// expansion `NAME="$NAME"`, and a bash substring `NAME:0:7`, so a
	// genuinely-unpinned computed variable is not flagged.
	scriptPinCarrierRe = regexp.MustCompile(`[A-Z][A-Z0-9_]*_(?:VERSION|SHA256|COMMIT)(?:=|:[-=])[^}"'\s:$-]`)
)

// scriptSourceSpecs is the deterministic per-file dispatch table for the pinned
// build scripts that carry extracted pins. A single file may appear more than
// once when it has more than one independent parser (e.g. publish.sh declares
// both the amazonlinux base image and the consumer's qemu pin). The
// directory-discovery pass in ExtractScripts consults this table's RelPath set
// so any OTHER discovered script carrying a pin fails closed rather than being
// silently ignored.
var scriptSourceSpecs = []common.SourceSpec{
	{RelPath: "tools/qemu/build-qemu.sh", Parse: scrapeQemu},
	{RelPath: "tools/openssh/build.sh", Parse: func(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
		return scrapeOpenssh(data, file, opensshBuildSpecs)
	}},
	{RelPath: "tools/openssh/publish.sh", Parse: func(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
		return scrapeOpenssh(data, file, opensshPublishSpecs)
	}},
	{RelPath: "tools/openssh/publish.sh", Parse: scrapeQemuConsumer("openssh")},
	{RelPath: "tools/ffmpeg-dist/build.sh", Parse: scrapeFfmpeg},
	{RelPath: "tools/ffmpeg-dist/publish.sh", Parse: scrapeFfmpeg},
	{RelPath: "tools/ffmpeg-dist/publish.sh", Parse: scrapeQemuConsumer("ffmpeg-dist")},
	{RelPath: "tools/bazel/qemu_x86_64.bzl", Parse: scrapeBzlPinQemu},
	{RelPath: "deploy/aws/launch", Parse: scrapeDlami},
	{RelPath: "scripts/upload-artifact.sh", Parse: scrapeUploadArtifact},
	{RelPath: "deploy/aws/fish-deploy.sh", Parse: scrapeFish},
}

// scriptRoots are the repository subtrees the discovery pass walks. Only these
// three hold the pinned-build scripts; restricting the walk keeps it bounded.
var scriptRoots = []string{"tools", "scripts", "deploy"}

// scriptExtensions are the shell-family extensions the discovery pass treats
// as script files. Extension-less executable files are also considered (see
// isScriptFile) so a pinned interpreter script such as deploy/aws/launch is
// never silently skipped.
var scriptExtensions = map[string]bool{
	".sh":   true,
	".bash": true,
	".zsh":  true,
	".fish": true,
}

// unspecifiedPinReason is the fail-closed unknown recorded for a discovered
// script that carries a pin but no extractor spec.
const unspecifiedPinReason = "discovered script carries a version/sha256/commit pin but has no extractor spec"

// ExtractScripts scrapes version pins out of the pinned-build shell scripts. It
// runs the deterministic dispatch table first (a known file that cannot be
// read still surfaces as an unknown via common.ReadAndParse), then walks the
// tools/, scripts/, and deploy/ subtrees: every discovered script file without
// a dispatch entry that carries a *_VERSION / *_SHA256 / *_COMMIT pin fails
// closed as an ExtractionUnknown, so a newly-added pinned script is never
// silently ignored.
func ExtractScripts(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	deps, unknowns := common.RunSourceSpecs(root, scriptSourceSpecs)

	known := make(map[string]bool, len(scriptSourceSpecs))
	for _, spec := range scriptSourceSpecs {
		known[spec.RelPath] = true
	}

	for _, rel := range discoverScriptFiles(root) {
		if known[rel] {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			unknowns = append(unknowns, common.ExtractionUnknown{File: rel, Reason: "cannot read discovered script: " + err.Error()})
			continue
		}
		if scriptPinCarrierRe.Match(data) {
			unknowns = append(unknowns, common.ExtractionUnknown{File: rel, Reason: unspecifiedPinReason})
		}
	}
	return deps, unknowns
}

// ExtractScripts must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractScripts

// discoverScriptFiles walks the scriptRoots subtrees and returns every
// repo-relative script file path, sorted for deterministic output. Unreadable
// directories are skipped, never fatal: discovery is a safety net, not a
// source of hard failure.
func discoverScriptFiles(root string) []string {
	var found []string
	for _, base := range scriptRoots {
		_ = filepath.WalkDir(filepath.Join(root, base), func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() {
				if skipScriptDir(d.Name()) {
					return fs.SkipDir
				}
				return nil
			}
			if !isScriptFile(d) {
				return nil
			}
			rel, relErr := filepath.Rel(root, path)
			if relErr != nil {
				return nil
			}
			found = append(found, filepath.ToSlash(rel))
			return nil
		})
	}
	sort.Strings(found)
	return found
}

// skipScriptDir prunes directories that never hold hand-written pinned scripts:
// VCS metadata, vendored dependencies, Python bytecode caches, and any hidden
// directory.
func skipScriptDir(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	switch name {
	case "node_modules", "__pycache__":
		return true
	}
	return false
}

// isScriptFile reports whether a walked file is a script: it has a shell-family
// extension, or it has no extension and is an executable regular file (the
// deploy/aws writing convention for interpreter scripts).
func isScriptFile(d fs.DirEntry) bool {
	if scriptExtensions[strings.ToLower(filepath.Ext(d.Name()))] {
		return true
	}
	if filepath.Ext(d.Name()) != "" {
		return false
	}
	info, err := d.Info()
	if err != nil {
		return false
	}
	return info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0
}

// scrapeScript applies the pin specs to one script's content. A spec whose
// regex does not match becomes an unknown record, never a silent drop.
func scrapeScript(content, file string, specs []pinSpec) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	for _, spec := range specs {
		m := spec.re.FindStringSubmatch(content)
		if m == nil {
			unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "pin not found: " + spec.name})
			continue
		}
		note := spec.note
		if spec.noteFrom != nil {
			note = spec.noteFrom(m[1])
		}
		deps = append(deps, common.Dependency{
			Category: spec.category,
			Name:     spec.name,
			Version:  m[1],
			Source:   spec.source,
			File:     file,
			Note:     note,
			Role:     spec.role,
		})
	}
	return deps, unknowns
}

// scrapeQemu extracts the pins tools/qemu/build-qemu.sh owns: the default
// QEMU_VERSION (the ffmpeg-dist byte-identity pin), the distlib mkvenv wheel
// URL and its sha256, and every supported QEMU_SOURCE_SHA256 case arm. The
// per-consumer qemu pins live in each consumer's own publish script (see
// scrapeQemuConsumer); this is the shared build script's default.
func scrapeQemu(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	deps, unknowns := scrapeScript(content, file, []pinSpec{
		{
			name:     "qemu",
			category: common.CategoryScriptPin,
			re:       qemuConsumerVersionRe,
			source:   "https://download.qemu.org",
			note:     "build-qemu.sh default QEMU_VERSION (ffmpeg-dist byte-identity pin; 8.2.2/9.2.4/11.0.2/11.0.4 supported)",
		},
		{
			name:     "distlib",
			category: common.CategoryScriptPin,
			re:       qemuDistlibRe,
			source:   "https://files.pythonhosted.org",
			note:     "mkvenv wheel pin",
		},
		{
			name:     "distlib-sha256",
			category: common.CategoryScriptPin,
			re:       qemuDistlibSHA256Re,
			source:   "https://files.pythonhosted.org",
			note:     "sha256 of the pinned distlib mkvenv wheel",
			role:     common.RoleIntegrity,
		},
	})
	sourceDeps, sourceUnknowns := scrapeQemuSourceHashes(content, file)
	return common.MergeExtract(deps, unknowns, sourceDeps, sourceUnknowns)
}

// scrapeQemuSourceHashes extracts the verified source-tarball sha256 for every
// supported QEMU_VERSION case arm. Each arm is keyed by its qemu version (the
// comparable pin) with the sha256 carried in Source as the integrity digest.
func scrapeQemuSourceHashes(content, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	for _, m := range qemuSourceHashRe.FindAllStringSubmatch(content, -1) {
		version, hash := m[1], m[2]
		deps = append(deps, common.Dependency{
			Category: common.CategoryScriptPin,
			Name:     "qemu-source-sha256",
			Version:  version,
			Source:   hash,
			File:     file,
			Note:     "sha256 of the qemu-" + version + ".tar.xz source tarball",
			Role:     common.RoleIntegrity,
		})
	}
	return deps, nil
}

// scrapeQemuConsumer extracts the qemu version a single tool pins in its own
// publish script (each consumer declares its own QEMU_VERSION and owns a
// version-stamped qemu cache).
func scrapeQemuConsumer(consumer string) func(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	return func(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
		content := string(data)
		return scrapeScript(content, file, []pinSpec{{
			name:     "qemu",
			category: common.CategoryScriptPin,
			re:       qemuConsumerVersionRe,
			source:   "https://download.qemu.org",
			note:     consumer + "'s buildkit-direct-execve patched qemu-x86_64 pin",
		}})
	}
}

// scrapeBzlPinQemu extracts the qemu version pinned as the qemu_x86_64
// repo-rule attr default in tools/bazel/qemu_x86_64.bzl. That emulator is the
// one the in-tree genrule uses to cross-strip the amd64 mediamtx binary on
// non-x86_64 hosts; it is an independent pin, distinct from the ffmpeg-dist /
// openssh consumer pins scraped from their publish scripts, so it is reported
// in its own bzl-pin category.
func scrapeBzlPinQemu(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	return scrapeScript(content, file, []pinSpec{{
		name:     "qemu",
		category: common.CategoryBzlPin,
		re:       bzlQemuVersionRe,
		source:   "https://download.qemu.org",
		note:     "qemu_x86_64 repo-rule default for cross-stripping amd64 mediamtx on non-x86_64 hosts",
	}})
}

// scrapeDlami extracts the pinned us-east-2 Deep Learning AMI id from
// deploy/aws/launch. The pin replaces the former /latest SSM float, so the
// AMI is tracked like any other pinned dependency: check-deps compares it to
// the current upstream id and flags when it goes stale.
func scrapeDlami(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	return scrapeScript(content, file, []pinSpec{{
		name:     "dlami",
		category: common.CategoryAMI,
		re:       dlamiAmiIDRe,
		source:   "https://aws.amazon.com/ec2/",
		note:     "pinned AWS Deep Learning Base OSS Nvidia Driver GPU AMI (Amazon Linux 2023), x86_64, us-east-2",
	}})
}

// scrapeUploadArtifact extracts the expected ffmpeg-dist artifact sha256 that
// scripts/upload-artifact.sh verifies before uploading, keeping the script's
// contract hash tracked alongside the MODULE.bazel s3_http_archive pin.
func scrapeUploadArtifact(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	return scrapeScript(content, file, []pinSpec{{
		name:     "ffmpeg-dist-sha256",
		category: common.CategoryScriptPin,
		re:       uploadExpectedSHA256Re,
		source:   "",
		note:     "expected sha256 of the published ffmpeg_dist artifact (matches the MODULE.bazel pin)",
		role:     common.RoleIntegrity,
	}})
}

// scrapeFish extracts the pinned fish release version that deploy/aws/
// fish-deploy.sh installs (x86_64-only). The release URL is the pin; the
// version is what check-deps compares.
func scrapeFish(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	return scrapeScript(content, file, []pinSpec{{
		name:     "fish",
		category: common.CategoryScriptPin,
		re:       fishDistRe,
		source:   "https://github.com/fish-shell/fish-shell",
		note:     "pinned fish release tarball (x86_64-only)",
	}})
}

// opensshBuildSpecs and opensshPublishSpecs are the pins each half of the
// openssh pipeline declares: build.sh pins the static GNU m4 tarball and the
// reproducible-build clock, and publish.sh pins the amazonlinux chroot base
// image. The shared OpenSSH version + tag pins are handled directly by
// scrapeOpenssh for both files.
var opensshBuildSpecs = []pinSpec{
	{
		name:     "GNU m4",
		category: common.CategoryScriptPin,
		re:       regexp.MustCompile(`M4_SOURCE_URL:[-=][^"}]*m4-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz`),
		source:   "https://ftp.gnu.org/gnu/m4",
		note:     "static m4 for the qemu autoreconf workaround",
	},
	{
		name:     "GNU m4-sha256",
		category: common.CategoryScriptPin,
		re:       m4SourceSHA256Re,
		source:   "https://ftp.gnu.org/gnu/m4",
		note:     "sha256 of the pinned static m4 tarball",
		role:     common.RoleIntegrity,
	},
	{
		name:     "source-date-epoch",
		category: common.CategoryScriptPin,
		re:       sourceDateEpochRe,
		source:   "",
		noteFrom: sourceDateEpochNote,
		role:     common.RoleIntegrity,
	},
}

var opensshPublishSpecs = []pinSpec{
	{
		name:     "amazonlinux",
		category: common.CategoryBaseImage,
		re:       regexp.MustCompile(`AMAZONLINUX_TAG:[-=]([^"}]+)\}`),
		source:   "docker.io/library/amazonlinux",
		note:     "chroot base image",
	},
}

// scrapeOpenssh emits the shared OpenSSH pins (the numeric version and the
// git tag, promoted from an annotation to its own Dependency) and then applies
// the caller's file-specific specs. A missing version or tag each fail closed.
func scrapeOpenssh(data []byte, file string, specs []pinSpec) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown

	if m := opensshVersionRe.FindStringSubmatch(content); m == nil {
		unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "OpenSSH pin not found: no OPENSSH_VERSION assignment"})
	} else {
		deps = append(deps, common.Dependency{
			Category: common.CategoryScriptPin,
			Name:     "openssh-portable",
			Version:  m[1],
			Source:   "https://github.com/openssh/openssh-portable.git",
			File:     file,
		})
	}

	if m := opensshTagRe.FindStringSubmatch(content); m == nil {
		unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "OpenSSH tag not found: no OPENSSH_TAG assignment"})
	} else {
		deps = append(deps, common.Dependency{
			Category: common.CategoryScriptPin,
			Name:     "openssh-portable",
			Version:  m[1],
			Source:   "https://github.com/openssh/openssh-portable.git",
			File:     file,
			Note:     "git tag/branch cloned (OPENSSH_TAG)",
		})
	}

	gotDeps, gotUnknowns := scrapeScript(content, file, specs)
	deps, unknowns = common.MergeExtract(deps, unknowns, gotDeps, gotUnknowns)
	return deps, unknowns
}

// sourceDateEpochNote renders the pinned epoch as a readable UTC timestamp,
// e.g. 1786924800 -> "reproducible build clock 2026-08-17T00:00:00Z". A
// malformed value degrades to a descriptive note instead of panicking.
func sourceDateEpochNote(epoch string) string {
	seconds, err := strconv.ParseInt(epoch, 10, 64)
	if err != nil {
		return "reproducible build clock (unparseable epoch)"
	}
	return "reproducible build clock " + time.Unix(seconds, 0).UTC().Format(time.RFC3339)
}

// scrapeFfmpeg extracts the ffmpeg-dist upstream component pins (ffmpeg,
// nv-codec-headers, CUDA) together with their exact git commits and the nvcc
// codegen target, plus the debian chroot base image. Both build.sh and
// publish.sh declare the same defaults, so the same parser serves both. The S3
// artifact itself is deliberately not extracted: it is governed by the publish
// pipeline, not an upstream dependency.
func scrapeFfmpeg(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	return scrapeScript(content, file, []pinSpec{
		{
			name:     "ffmpeg",
			category: common.CategoryScriptPin,
			re:       ffmpegVersionRe,
			source:   "https://github.com/FFmpeg/FFmpeg.git",
			note:     "FFmpeg source pin",
		},
		{
			name:     "ffmpeg-commit",
			category: common.CategoryScriptPin,
			re:       ffmpegCommitRe,
			source:   "https://github.com/FFmpeg/FFmpeg.git",
			note:     "exact upstream commit checked out (FFmpeg source is cloned blobless and checked out at this SHA)",
			role:     common.RoleIntegrity,
		},
		{
			name:     "nv-codec-headers",
			category: common.CategoryScriptPin,
			re:       nvCodecHeadersRe,
			source:   "https://github.com/FFmpeg/nv-codec-headers.git",
			note:     "git tag",
		},
		{
			name:     "nv-codec-headers-commit",
			category: common.CategoryScriptPin,
			re:       nvCodecHeadersCommitRe,
			source:   "https://github.com/FFmpeg/nv-codec-headers.git",
			note:     "exact checked-out commit guarding against a force-moved tag",
			role:     common.RoleIntegrity,
		},
		{
			name:     "gencode",
			category: common.CategoryScriptPin,
			re:       gencodeRe,
			source:   "",
			note:     "nvcc --nvccflags -gencode target for the CUDA codegen",
			role:     common.RoleIntegrity,
		},
		{
			name:     "CUDA",
			category: common.CategoryScriptPin,
			re:       cudaManifestRe,
			source:   "https://developer.download.nvidia.com/compute/cuda/redist",
			note:     "NVIDIA redistributable manifest",
		},
		{
			name:     "debian",
			category: common.CategoryBaseImage,
			re:       debianSnapshotRe,
			source:   "docker.io/library/debian",
			noteFrom: debianBaseImageNote,
		},
	})
}

// debianBaseImageNote renders the ffmpeg-dist chroot base image tag from the
// pinned Debian snapshot, e.g. 20260824T082821Z -> "trixie-20260824-slim". It
// extracts the 8-digit YYYYMMDD date bounds-safely via utilities.ExtractDate,
// so a short or malformed snapshot yields an empty date instead of panicking.
func debianBaseImageNote(snapshot string) string {
	date := utilities.ExtractDate(snapshot) // "YYYYMMDD"
	return "base image debian:trixie-" + date + "-slim"
}
