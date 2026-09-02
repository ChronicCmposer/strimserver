package main

import "testing"

// findDep returns the first dependency matching category and name, or nil.
func findDep(t *testing.T, deps []dependency, category, name string) *dependency {
	t.Helper()
	for i := range deps {
		if deps[i].Category == category && deps[i].Name == name {
			return &deps[i]
		}
	}
	return nil
}

// findDepVersion returns the first dependency matching category, name, and
// version, or nil.
func findDepVersion(t *testing.T, deps []dependency, category, name, version string) *dependency {
	t.Helper()
	for i := range deps {
		if deps[i].Category == category && deps[i].Name == name && deps[i].Version == version {
			return &deps[i]
		}
	}
	return nil
}

func TestParseModuleBazel(t *testing.T) {
	const module = `
bazel_dep(name = "platforms", version = "1.1.0")
bazel_dep(name = "rules_go", version = "0.63.0")
single_version_override(
    module_name = "bazel_lib",
    patch_strip = 1,
    patches = ["//tools/bazel/patches:bazel_lib_no_bats.patch"],
    version = "3.7.0",
)
http_archive(
    name = "golangci_lint_linux_amd64",
    build_file_content = "exports_files([\"golangci-lint\"])",
    sha256 = "2277d43b98ec0054280f2ac26b53268bae97682444678a59a657dd565da021d6",
    strip_prefix = "golangci-lint-2.13.2-linux-amd64",
    url = "https://github.com/golangci/golangci-lint/releases/download/v2.13.2/golangci-lint-2.13.2-linux-amd64.tar.gz",
)
http_archive(
    name = "mediamtx_dist",
    url = "https://github.com/bluenviron/mediamtx/releases/download/v1.17.0/mediamtx_v1.17.0_linux_amd64.tar.gz",
)
http_file(
    name = "iperf3_apk",
    urls = ["https://dl-cdn.alpinelinux.org/alpine/v3.23/main/x86_64/iperf3-3.19.1-r1.apk"],
)
apt.sources_list(
    uris = ["https://snapshot.debian.org/archive/debian/20260824T082821Z"],
)
oci.pull(
    name = "alpine",
    digest = "sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659",
    image = "docker.io/library/alpine",
)
`
	deps, unknowns := parseModuleBazel([]byte(module), "MODULE.bazel")
	if len(unknowns) != 0 {
		t.Fatalf("parseModuleBazel unknowns = %v, want none", unknowns)
	}

	if got := findDep(t, deps, "bazel-module", "platforms"); got == nil || got.Version != "1.1.0" {
		t.Errorf("bazel_dep platforms not extracted: %v", got)
	}
	if got := findDep(t, deps, "bazel-module", "rules_go"); got == nil || got.Version != "0.63.0" {
		t.Errorf("bazel_dep rules_go not extracted: %v", got)
	}
	if got := findDep(t, deps, "bazel-module", "bazel_lib"); got == nil || got.Version != "3.7.0" || got.Note != "pinned by single_version_override" {
		t.Errorf("single_version_override bazel_lib not extracted: %v", got)
	}
	if got := findDep(t, deps, "tool-binary", "golangci_lint_linux_amd64"); got == nil || got.Version != "2.13.2" {
		t.Errorf("http_archive golangci-lint not extracted: %v", got)
	}
	if got := findDep(t, deps, "tool-binary", "mediamtx_dist"); got == nil || got.Version != "1.17.0" {
		t.Errorf("http_archive mediamtx not extracted: %v", got)
	}
	if got := findDep(t, deps, "runtime", "iperf3"); got == nil || got.Version != "3.19.1-r1" {
		t.Errorf("http_file iperf3 not extracted: %v", got)
	}
	if got := findDep(t, deps, "base-image", "debian"); got == nil || got.Version != "20260824T082821Z" {
		t.Errorf("apt.sources_list snapshot not extracted: %v", got)
	}
	if got := findDep(t, deps, "base-image", "alpine"); got == nil || got.Version != "" || got.Note != "digest-pinned" {
		t.Errorf("oci.pull alpine not extracted: %v", got)
	}
}

func TestParseModuleBazelSkipsS3Artifacts(t *testing.T) {
	const module = `
s3_http_archive(
    name = "ffmpeg_dist",
    mirror_urls = ["https://github.com/ChronicCmposer/strimserver/releases/download/ffmpeg-artifacts/ffmpeg-8.0.tar.gz"],
)
s3_http_file(
    name = "openssh_dist",
    mirror_urls = ["https://github.com/ChronicCmposer/strimserver/releases/download/openssh-dist/openssh-experimental.rpm"],
)
`
	deps, unknowns := parseModuleBazel([]byte(module), "MODULE.bazel")
	if len(deps) != 0 || len(unknowns) != 0 {
		t.Fatalf("s3 artifacts must be excluded, got deps=%v unknowns=%v", deps, unknowns)
	}
}

func TestParseGoMod(t *testing.T) {
	deps, unknowns := parseGoMod([]byte("module strimserver-controller\n\ngo 1.26.4\n"), "core/controller/go.mod")
	if len(unknowns) != 0 {
		t.Fatalf("parseGoMod unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 || deps[0].Category != "toolchain" || deps[0].Name != "Go" || deps[0].Version != "1.26.4" {
		t.Errorf("go directive not extracted: %v", deps)
	}
}

func TestParseBazelVersionAndNvmrc(t *testing.T) {
	deps, unknowns := parseBazelVersion([]byte("9.2.0\n"), ".bazelversion")
	if len(unknowns) != 0 || len(deps) != 1 || deps[0].Name != "Bazel" || deps[0].Version != "9.2.0" {
		t.Errorf("bazel version not extracted: deps=%v unknowns=%v", deps, unknowns)
	}

	deps, unknowns = parseNvmrc([]byte("24.13.0\n"), ".nvmrc")
	if len(unknowns) != 0 || len(deps) != 1 || deps[0].Name != "Node" || deps[0].Version != "24.13.0" {
		t.Errorf("node version not extracted: deps=%v unknowns=%v", deps, unknowns)
	}
}

func TestParsePackageJSON(t *testing.T) {
	deps, unknowns := parsePackageJSON([]byte(`{"packageManager": "pnpm@9.15.9"}`), "tools/streamdeck-plugin/package.json")
	if len(unknowns) != 0 {
		t.Fatalf("parsePackageJSON unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 || deps[0].Category != "toolchain" || deps[0].Name != "pnpm" || deps[0].Version != "9.15.9" {
		t.Errorf("packageManager pin not extracted: %v", deps)
	}
}

func TestParseWorkflow(t *testing.T) {
	const workflow = "steps:\n      - uses: actions/checkout@v4\n      - uses: bazelbuild/setup-bazelisk@v3\n"
	deps, unknowns := parseWorkflow([]byte(workflow), ".github/workflows/controller-ci.yml")
	if len(unknowns) != 0 {
		t.Fatalf("parseWorkflow unknowns = %v, want none", unknowns)
	}
	if got := findDep(t, deps, "ci-action", "actions/checkout"); got == nil || got.Version != "v4" {
		t.Errorf("actions/checkout not extracted: %v", got)
	}
	if got := findDep(t, deps, "ci-action", "bazelbuild/setup-bazelisk"); got == nil || got.Version != "v3" {
		t.Errorf("setup-bazelisk not extracted: %v", got)
	}
}

func TestScrapeQemu(t *testing.T) {
	const script = `
QEMU_VERSION="${QEMU_VERSION:-8.2.2}"
case "$QEMU_VERSION" in
  8.2.2) QEMU_SOURCE_SHA256="${QEMU_SOURCE_SHA256:-847346c1b82c1a54b2c38f6edbd85549edeb17430b7d4d3da12620e2962bc4f3}" ;;
  9.2.4) QEMU_SOURCE_SHA256="${QEMU_SOURCE_SHA256:-f3cc1c4eabfdb288218ac3e33763dbe9e276d8bc890b867a2335d58de2ddd39a}" ;;
esac
QEMU_DISTLIB_URL="${QEMU_DISTLIB_URL:-https://files.pythonhosted.org/packages/02/08/9c41fb51ab5b43eb21674aff13df270e8ba6c4b29c8624e328dc7a9482af/distlib-0.4.3-py2.py3-none-any.whl}"
`
	deps, unknowns := scrapeQemu([]byte(script), "tools/qemu/build-qemu.sh")
	if len(unknowns) != 0 {
		t.Fatalf("scrapeQemu unknowns = %v, want none", unknowns)
	}
	for _, wantVersion := range []string{"8.2.2", "9.2.4"} {
		if got := findDepVersion(t, deps, "script-pin", "qemu", wantVersion); got == nil {
			t.Errorf("qemu %s not extracted: %v", wantVersion, deps)
		}
	}
	if got := findDep(t, deps, "script-pin", "distlib"); got == nil || got.Version != "0.4.3" {
		t.Errorf("distlib not extracted: %v", got)
	}
}

func TestScrapeOpenssh(t *testing.T) {
	const script = `
OPENSSH_TAG="${OPENSSH_TAG:-V_10_3_P1}"
OPENSSH_VERSION="${OPENSSH_VERSION:-10.3p1}"
M4_SOURCE_URL="${M4_SOURCE_URL:-https://ftp.gnu.org/gnu/m4/m4-1.4.19.tar.gz}"
AMAZONLINUX_TAG="${AMAZONLINUX_TAG:-2023}"
`
	deps, unknowns := scrapeOpenssh([]byte(script), "tools/openssh/build.sh", opensshBuildSpecs)
	if len(unknowns) != 0 {
		t.Fatalf("scrapeOpenssh build.sh unknowns = %v, want none", unknowns)
	}
	if got := findDep(t, deps, "script-pin", "openssh-portable"); got == nil || got.Version != "10.3p1" || got.Note != "git tag V_10_3_P1" {
		t.Errorf("openssh-portable not extracted: %v", got)
	}
	if got := findDep(t, deps, "script-pin", "GNU m4"); got == nil || got.Version != "1.4.19" {
		t.Errorf("m4 not extracted: %v", got)
	}

	deps, unknowns = scrapeOpenssh([]byte(script), "tools/openssh/publish.sh", opensshPublishSpecs)
	if len(unknowns) != 0 {
		t.Fatalf("scrapeOpenssh publish.sh unknowns = %v, want none", unknowns)
	}
	if got := findDep(t, deps, "base-image", "amazonlinux"); got == nil || got.Version != "2023" {
		t.Errorf("amazonlinux not extracted: %v", got)
	}
}

func TestScrapeFfmpeg(t *testing.T) {
	const script = `
: "${FFMPEG_VERSION:=8.0}"
: "${NV_CODEC_HEADERS_TAG:=n13.0.19.0}"
: "${CUDA_MANIFEST_URL:=https://developer.download.nvidia.com/compute/cuda/redist/redistrib_13.0.2.json}"
: "${DEBIAN_SNAPSHOT:=20260824T082821Z}"
`
	deps, unknowns := scrapeFfmpeg([]byte(script), "tools/ffmpeg-dist/build.sh")
	if len(unknowns) != 0 {
		t.Fatalf("scrapeFfmpeg unknowns = %v, want none", unknowns)
	}
	if got := findDep(t, deps, "script-pin", "ffmpeg"); got == nil || got.Version != "8.0" {
		t.Errorf("ffmpeg not extracted: %v", got)
	}
	if got := findDep(t, deps, "script-pin", "nv-codec-headers"); got == nil || got.Version != "n13.0.19.0" {
		t.Errorf("nv-codec-headers not extracted: %v", got)
	}
	if got := findDep(t, deps, "script-pin", "CUDA"); got == nil || got.Version != "13.0.2" {
		t.Errorf("CUDA not extracted: %v", got)
	}
	if got := findDep(t, deps, "base-image", "debian"); got == nil || got.Version != "20260824T082821Z" || got.Note != "base image debian:trixie-20260824-slim" {
		t.Errorf("debian base image not extracted: %v", got)
	}
}

func TestDedupeKeepsFirst(t *testing.T) {
	deps := []dependency{
		{Category: "script-pin", Name: "ffmpeg", Version: "8.0", File: "tools/ffmpeg-dist/build.sh"},
		{Category: "script-pin", Name: "ffmpeg", Version: "8.0", File: "tools/ffmpeg-dist/publish.sh"},
		{Category: "script-pin", Name: "qemu", Version: "9.2.4", File: "tools/qemu/build-qemu.sh"},
	}
	got := dedupe(deps)
	if len(got) != 2 {
		t.Fatalf("dedupe = %v, want 2 entries", got)
	}
	if got[0].File != "tools/ffmpeg-dist/build.sh" {
		t.Errorf("dedupe kept %q, want the first occurrence", got[0].File)
	}
}
