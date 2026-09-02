package extractorimpl

import (
	"regexp"
	"sort"

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
	qemuDefaultVersionRe = regexp.MustCompile(`QEMU_VERSION="[^"]*-([0-9][0-9.]*)"`)
	qemuCaseArmRe        = regexp.MustCompile(`(?m)^\s*([0-9]+\.[0-9]+\.[0-9]+)\)\s+QEMU_SOURCE_SHA256`)
	qemuDistlibRe        = regexp.MustCompile(`QEMU_DISTLIB_URL:[-=][^"}]*distlib-([0-9]+\.[0-9]+\.[0-9]+)-py2`)

	opensshVersionRe = regexp.MustCompile(`OPENSSH_VERSION:[-=]([^"}]+)\}`)
	opensshTagRe     = regexp.MustCompile(`OPENSSH_TAG:[-=]([^"}]+)\}`)

	ffmpegVersionRe  = regexp.MustCompile(`FFMPEG_VERSION:[-=]([0-9]+\.[0-9]+)\}`)
	nvCodecHeadersRe = regexp.MustCompile(`NV_CODEC_HEADERS_TAG:[-=]([^"}]+)\}`)
	cudaManifestRe   = regexp.MustCompile(`CUDA_MANIFEST_URL:[-=][^"}]*redistrib_([0-9]+\.[0-9]+\.[0-9]+)\.json`)
	debianSnapshotRe = regexp.MustCompile(`DEBIAN_SNAPSHOT:[-=]([0-9]{8}T[0-9]{6}Z)\}`)
)

// ExtractScripts scrapes version pins out of the pinned-build shell scripts.
// The same pins are declared in both a build.sh and its publish.sh, so the
// combined result is deduplicated by (category, name, version). Each file is
// scraped only for the pins it is expected to carry: amazonlinux lives in
// publish.sh, the m4 tarball lives in build.sh, and both declare the shared
// OpenSSH pin.
func ExtractScripts(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	// Script groups (e.g. build.sh + publish.sh) declare the same pins;
	// resolveAll dedupes the aggregate, so each pin is reported exactly once.
	return common.RunSourceSpecs(root, []common.SourceSpec{
		{RelPath: "tools/qemu/build-qemu.sh", Parse: scrapeQemu},
		{RelPath: "tools/openssh/build.sh", Parse: func(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
			return scrapeOpenssh(data, file, opensshBuildSpecs)
		}},
		{RelPath: "tools/openssh/publish.sh", Parse: func(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
			return scrapeOpenssh(data, file, opensshPublishSpecs)
		}},
		{RelPath: "tools/ffmpeg-dist/build.sh", Parse: scrapeFfmpeg},
		{RelPath: "tools/ffmpeg-dist/publish.sh", Parse: scrapeFfmpeg},
	})
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
		})
	}
	return deps, unknowns
}

// scrapeQemu extracts every qemu version pinned by build-qemu.sh (the default
// QEMU_VERSION and each verified case arm) plus the provisioned distlib wheel.
func scrapeQemu(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	versions := make(map[string]bool)
	if m := qemuDefaultVersionRe.FindStringSubmatch(content); m != nil {
		versions[m[1]] = true
	}
	for _, m := range qemuCaseArmRe.FindAllStringSubmatch(content, -1) {
		versions[m[1]] = true
	}
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	if len(versions) == 0 {
		unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "no QEMU_VERSION pin found"})
	} else {
		sorted := make([]string, 0, len(versions))
		for version := range versions {
			sorted = append(sorted, version)
		}
		sort.Strings(sorted)
		for _, version := range sorted {
			deps = append(deps, common.Dependency{
				Category: common.CategoryScriptPin,
				Name:     "qemu",
				Version:  version,
				Source:   "https://download.qemu.org",
				File:     file,
				Note:     "buildkit-direct-execve patched qemu-x86_64",
			})
		}
	}

	gotDeps, gotUnknowns := scrapeScript(content, file, []pinSpec{{
		name:     "distlib",
		category: common.CategoryScriptPin,
		re:       qemuDistlibRe,
		source:   "https://files.pythonhosted.org",
		note:     "mkvenv wheel pin",
	}})
	deps, unknowns = common.MergeExtract(deps, unknowns, gotDeps, gotUnknowns)
	return deps, unknowns
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

// scrapeOpenssh extracts the OpenSSH source pin (version + git tag) plus the
// file-specific specs passed in from the openssh build and publish scripts.
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
