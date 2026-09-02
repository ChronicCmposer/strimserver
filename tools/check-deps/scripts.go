package main

import (
	"regexp"
	"sort"
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

// extractScripts scrapes version pins out of the pinned-build shell scripts.
// The same pins are declared in both a build.sh and its publish.sh, so the
// combined result is deduplicated by (category, name, version). Each file is
// scraped only for the pins it is expected to carry: amazonlinux lives in
// publish.sh, the m4 tarball lives in build.sh, and both declare the shared
// OpenSSH pin.
func extractScripts(root string) ([]dependency, []unknown) {
	type scriptGroup struct {
		file  string
		parse func(data []byte, file string) ([]dependency, []unknown)
	}
	groups := []scriptGroup{
		{"tools/qemu/build-qemu.sh", scrapeQemu},
		{"tools/openssh/build.sh", func(data []byte, file string) ([]dependency, []unknown) {
			return scrapeOpenssh(data, file, opensshBuildSpecs)
		}},
		{"tools/openssh/publish.sh", func(data []byte, file string) ([]dependency, []unknown) {
			return scrapeOpenssh(data, file, opensshPublishSpecs)
		}},
		{"tools/ffmpeg-dist/build.sh", scrapeFfmpeg},
		{"tools/ffmpeg-dist/publish.sh", scrapeFfmpeg},
	}
	var deps []dependency
	var unknowns []unknown
	for _, group := range groups {
		gotDeps, gotUnknowns := readAndParse(root, group.file, group.parse)
		deps = append(deps, gotDeps...)
		unknowns = append(unknowns, gotUnknowns...)
	}
	return dedupe(deps), unknowns
}

// scrapeScript applies the pin specs to one script's content. A spec whose
// regex does not match becomes an unknown record, never a silent drop.
func scrapeScript(content, file string, specs []pinSpec) ([]dependency, []unknown) {
	var deps []dependency
	var unknowns []unknown
	for _, spec := range specs {
		m := spec.re.FindStringSubmatch(content)
		if m == nil {
			unknowns = append(unknowns, unknown{File: file, Reason: "pin not found: " + spec.name})
			continue
		}
		note := spec.note
		if spec.noteFrom != nil {
			note = spec.noteFrom(m[1])
		}
		deps = append(deps, dependency{
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
func scrapeQemu(data []byte, file string) ([]dependency, []unknown) {
	content := string(data)
	versions := make(map[string]bool)
	if m := qemuDefaultVersionRe.FindStringSubmatch(content); m != nil {
		versions[m[1]] = true
	}
	for _, m := range qemuCaseArmRe.FindAllStringSubmatch(content, -1) {
		versions[m[1]] = true
	}
	var deps []dependency
	var unknowns []unknown
	if len(versions) == 0 {
		unknowns = append(unknowns, unknown{File: file, Reason: "no QEMU_VERSION pin found"})
	} else {
		sorted := make([]string, 0, len(versions))
		for version := range versions {
			sorted = append(sorted, version)
		}
		sort.Strings(sorted)
		for _, version := range sorted {
			deps = append(deps, dependency{
				Category: "script-pin",
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
		category: "script-pin",
		re:       qemuDistlibRe,
		source:   "https://files.pythonhosted.org",
		note:     "mkvenv wheel pin",
	}})
	deps = append(deps, gotDeps...)
	unknowns = append(unknowns, gotUnknowns...)
	return deps, unknowns
}

// opensshBuildSpecs and opensshPublishSpecs are the pins each half of the
// openssh pipeline declares: build.sh pins the static GNU m4 tarball, and
// publish.sh pins the amazonlinux chroot base image.
var opensshBuildSpecs = []pinSpec{
	{
		name:     "GNU m4",
		category: "script-pin",
		re:       regexp.MustCompile(`M4_SOURCE_URL:[-=][^"}]*m4-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz`),
		source:   "https://ftp.gnu.org/gnu/m4",
		note:     "static m4 for the qemu autoreconf workaround",
	},
}

var opensshPublishSpecs = []pinSpec{
	{
		name:     "amazonlinux",
		category: "base-image",
		re:       regexp.MustCompile(`AMAZONLINUX_TAG:[-=]([^"}]+)\}`),
		source:   "docker.io/library/amazonlinux",
		note:     "chroot base image",
	},
}

// scrapeOpenssh extracts the OpenSSH source pin (version + git tag) plus the
// file-specific specs passed in from the openssh build and publish scripts.
func scrapeOpenssh(data []byte, file string, specs []pinSpec) ([]dependency, []unknown) {
	content := string(data)
	var deps []dependency
	var unknowns []unknown

	version := ""
	if m := opensshVersionRe.FindStringSubmatch(content); m != nil {
		version = m[1]
	}
	if version == "" {
		unknowns = append(unknowns, unknown{File: file, Reason: "OpenSSH pin not found: no OPENSSH_VERSION assignment"})
	} else {
		note := ""
		if m := opensshTagRe.FindStringSubmatch(content); m != nil {
			note = "git tag " + m[1]
		}
		deps = append(deps, dependency{
			Category: "script-pin",
			Name:     "openssh-portable",
			Version:  version,
			Source:   "https://github.com/openssh/openssh-portable.git",
			File:     file,
			Note:     note,
		})
	}

	gotDeps, gotUnknowns := scrapeScript(content, file, specs)
	deps = append(deps, gotDeps...)
	unknowns = append(unknowns, gotUnknowns...)
	return deps, unknowns
}

// scrapeFfmpeg extracts the ffmpeg-dist upstream component pins (ffmpeg,
// nv-codec-headers, CUDA) and the debian chroot base image. The S3 artifact
// itself is deliberately not extracted: it is governed by the publish
// pipeline, not an upstream dependency.
func scrapeFfmpeg(data []byte, file string) ([]dependency, []unknown) {
	content := string(data)
	return scrapeScript(content, file, []pinSpec{
		{
			name:     "ffmpeg",
			category: "script-pin",
			re:       ffmpegVersionRe,
			source:   "https://github.com/FFmpeg/FFmpeg.git",
			note:     "FFmpeg source pin",
		},
		{
			name:     "nv-codec-headers",
			category: "script-pin",
			re:       nvCodecHeadersRe,
			source:   "https://github.com/FFmpeg/nv-codec-headers.git",
			note:     "git tag",
		},
		{
			name:     "CUDA",
			category: "script-pin",
			re:       cudaManifestRe,
			source:   "https://developer.download.nvidia.com/compute/cuda/redist",
			note:     "NVIDIA redistributable manifest",
		},
		{
			name:     "debian",
			category: "base-image",
			re:       debianSnapshotRe,
			source:   "docker.io/library/debian",
			noteFrom: debianBaseImageNote,
		},
	})
}

// debianBaseImageNote renders the ffmpeg-dist chroot base image tag from the
// pinned Debian snapshot, e.g. 20260824T082821Z -> "trixie-20260824-slim".
func debianBaseImageNote(snapshot string) string {
	date := snapshot[:8] // "YYYYMMDD"
	return "base image debian:trixie-" + date + "-slim"
}
