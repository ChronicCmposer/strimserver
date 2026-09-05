package extractorimpl

import (
	"regexp"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// pinSpec describes one version pin to scrape from a shell script. The first
// capture group of re is the pinned version.
type pinSpec struct {
	name     string
	category string
	re       *regexp.Regexp
	source   string
	note     string // static annotation, overridden by noteFrom when set
	noteFrom func(version string) string
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
)

// ExtractScripts scrapes version pins out of the pinned-build shell scripts.
// Each file is scraped only for the pins it is expected to carry: amazonlinux
// lives in publish.sh, the m4 tarball lives in build.sh, and both declare the
// shared OpenSSH pin.
func ExtractScripts(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	return common.RunSourceSpecs(root, []common.SourceSpec{
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
	})
}

// ExtractScripts must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractScripts

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
		})
	}
	return deps, unknowns
}

// scrapeQemu extracts the provisioned distlib wheel pin from build-qemu.sh.
// The qemu version itself is deliberately not scraped here: each consumer
// (ffmpeg-dist, openssh) pins its own QEMU_VERSION in its own publish script
// and owns a version-stamped qemu cache, so the shared build script carries no
// single qemu pin to report.
func scrapeQemu(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	return scrapeScript(content, file, []pinSpec{{
		name:     "distlib",
		category: common.CategoryScriptPin,
		re:       qemuDistlibRe,
		source:   "https://files.pythonhosted.org",
		note:     "mkvenv wheel pin",
	}})
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

// opensshBuildSpecs and opensshPublishSpecs are the pins each half of the
// openssh pipeline declares: build.sh pins the static GNU m4 tarball, and
// publish.sh pins the amazonlinux chroot base image.
var opensshBuildSpecs = []pinSpec{
	{
		name:     "GNU m4",
		category: common.CategoryScriptPin,
		re:       regexp.MustCompile(`M4_SOURCE_URL:[-=][^"}]*m4-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz`),
		source:   "https://ftp.gnu.org/gnu/m4",
		note:     "static m4 for the qemu autoreconf workaround",
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

func scrapeOpenssh(data []byte, file string, specs []pinSpec) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown

	version := ""
	if m := opensshVersionRe.FindStringSubmatch(content); m != nil {
		version = m[1]
	}
	if version == "" {
		unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "OpenSSH pin not found: no OPENSSH_VERSION assignment"})
	} else {
		note := ""
		if m := opensshTagRe.FindStringSubmatch(content); m != nil {
			note = "git tag " + m[1]
		}
		deps = append(deps, common.Dependency{
			Category: common.CategoryScriptPin,
			Name:     "openssh-portable",
			Version:  version,
			Source:   "https://github.com/openssh/openssh-portable.git",
			File:     file,
			Note:     note,
		})
	}

	gotDeps, gotUnknowns := scrapeScript(content, file, specs)
	deps, unknowns = common.MergeExtract(deps, unknowns, gotDeps, gotUnknowns)
	return deps, unknowns
}

// scrapeFfmpeg extracts the ffmpeg-dist upstream component pins (ffmpeg,
// nv-codec-headers, CUDA) and the debian chroot base image. The S3 artifact
// itself is deliberately not extracted: it is governed by the publish
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
			name:     "nv-codec-headers",
			category: common.CategoryScriptPin,
			re:       nvCodecHeadersRe,
			source:   "https://github.com/FFmpeg/nv-codec-headers.git",
			note:     "git tag",
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
