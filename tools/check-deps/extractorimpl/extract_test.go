package extractorimpl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"strimserver-check-deps/common"
)

func writeFixture(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("creating fixture directory: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("writing fixture file: %v", err)
	}
}

func findDep(t *testing.T, deps []common.Dependency, category, name string) *common.Dependency {
	t.Helper()
	for i := range deps {
		if deps[i].Category == category && deps[i].Name == name {
			return &deps[i]
		}
	}
	return nil
}

func findDepVersion(t *testing.T, deps []common.Dependency, category, name, version string) *common.Dependency {
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
    version = "3.7.2",
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
    url = "https://github.com/bluenviron/mediamtx/releases/download/v1.20.1/mediamtx_v1.20.1_linux_amd64.tar.gz",
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
	if got := findDep(t, deps, "bazel-module", "bazel_lib"); got == nil || got.Version != "3.7.2" || got.Note != "pinned by single_version_override" {
		t.Errorf("single_version_override bazel_lib not extracted: %v", got)
	}
	if got := findDep(t, deps, "tool-binary", "golangci_lint_linux_amd64"); got == nil || got.Version != "2.13.2" {
		t.Errorf("http_archive golangci-lint not extracted: %v", got)
	}
	if got := findDep(t, deps, "tool-binary", "mediamtx_dist"); got == nil || got.Version != "1.20.1" {
		t.Errorf("http_archive mediamtx not extracted: %v", got)
	}
	if got := findDep(t, deps, "runtime", "iperf3"); got == nil || got.Version != "3.19.1-r1" {
		t.Errorf("http_file iperf3 not extracted: %v", got)
	}
	if got := findDep(t, deps, "base-image", "debian"); got == nil || got.Version != "20260824T082821Z" {
		t.Errorf("apt.sources_list snapshot not extracted: %v", got)
	}
	if got := findDep(t, deps, "base-image", "alpine"); got == nil || got.Version != "" || !got.DigestPinned {
		t.Errorf("oci.pull alpine not extracted: %v", got)
	}
}

// TestParseModuleBazelExtractsS3ArtifactsAsIntegrity asserts the reversed
// contract: self-published s3_http_archive/s3_http_file artifacts ARE extracted,
// each as an integrity pin whose identity is the sha256 (the S3 key carries no
// upstream version to compare against).
func TestParseModuleBazelExtractsS3ArtifactsAsIntegrity(t *testing.T) {
	const module = `
s3_http_archive(
    name = "ffmpeg_dist",
    mirror_urls = ["https://github.com/ChronicCmposer/strimserver/releases/download/ffmpeg-artifacts/ffmpeg-8.0.tar.gz"],
    s3_key = "ffmpeg/ffmpeg-8.0.tar.gz",
    sha256 = "44021ca11d9c5a3f1921b57150dfe68562cb291658afbef40b231a3554a82120",
)
s3_http_file(
    name = "openssh_dist",
    mirror_urls = ["https://github.com/ChronicCmposer/strimserver/releases/download/openssh-dist/openssh-experimental.rpm"],
    s3_key = "openssh/openssh-experimental.rpm",
    sha256 = "05a2869d27c59c22aaccbad738a91b08f397a82a066c2d6ade4ed68ac00cc8fd",
)
`
	deps, unknowns := parseModuleBazel([]byte(module), "MODULE.bazel")
	if len(unknowns) != 0 {
		t.Fatalf("parseModuleBazel unknowns = %v, want none", unknowns)
	}
	cases := []struct {
		category string
		name     string
	}{
		{"tool-binary", "ffmpeg_dist"},
		{"runtime", "openssh_dist"},
	}
	for _, tc := range cases {
		got := findDep(t, deps, tc.category, tc.name)
		if got == nil || !got.IsIntegrity() {
			t.Errorf("s3 %s %q not extracted as an integrity pin: %v", tc.category, tc.name, got)
		}
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

// TestExtractToolchainsDiscoversNodeSubRepos proves the root .nvmrc assumption
// is gone: the Node and pnpm pins come from the discovered sub-repo, tagged
// with its repo-relative files, and no missing-file unknown is produced.
func TestExtractToolchainsDiscoversNodeSubRepos(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, ".bazelversion"), "9.2.0\n")
	writeFixture(t, filepath.Join(root, "tools", "streamdeck-plugin", ".nvmrc"), "24.13.0\n")
	writeFixture(t, filepath.Join(root, "tools", "streamdeck-plugin", "package.json"), `{"packageManager": "pnpm@9.15.9"}`)

	deps, unknowns := ExtractToolchains(root)
	if len(unknowns) != 0 {
		t.Fatalf("ExtractToolchains unknowns = %v, want none", unknowns)
	}
	if got := findDepVersion(t, deps, "toolchain", "Bazel", "9.2.0"); got == nil {
		t.Errorf("Bazel not extracted: %v", deps)
	}
	if got := findDepVersion(t, deps, "toolchain", "Node", "24.13.0"); got == nil || got.File != "tools/streamdeck-plugin/.nvmrc" {
		t.Errorf("Node not extracted from the sub-repo .nvmrc: %v", deps)
	}
	if got := findDepVersion(t, deps, "toolchain", "pnpm", "9.15.9"); got == nil || got.File != "tools/streamdeck-plugin/package.json" {
		t.Errorf("pnpm not extracted from the sub-repo package.json: %v", deps)
	}
}

// TestExtractToolchainsSkipsUnmanagedPackageJSON proves a discovered
// package.json without a packageManager field contributes no pnpm finding and
// no spurious unknown.
func TestExtractToolchainsSkipsUnmanagedPackageJSON(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, ".bazelversion"), "9.2.0\n")
	writeFixture(t, filepath.Join(root, "web", "package.json"), `{"name": "web"}`)

	deps, unknowns := ExtractToolchains(root)
	if len(unknowns) != 0 {
		t.Fatalf("ExtractToolchains unknowns = %v, want none", unknowns)
	}
	if findDep(t, deps, "toolchain", "pnpm") != nil {
		t.Errorf("unmanaged package.json must not yield a pnpm finding: %v", deps)
	}
	if findDep(t, deps, "toolchain", "Node") != nil {
		t.Errorf("package.json-only sub-repo must not yield a Node finding: %v", deps)
	}
}

// TestExtractToolchainsSurfacesMalformedPackageJSON proves a discovered
// package.json with broken JSON still surfaces as an unknown: the discovery
// skip applies only to the missing packageManager field, never to a real parse
// error.
func TestExtractToolchainsSurfacesMalformedPackageJSON(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, ".bazelversion"), "9.2.0\n")
	writeFixture(t, filepath.Join(root, "web", "package.json"), `{"packageManager": `)

	deps, unknowns := ExtractToolchains(root)
	if len(deps) != 1 || deps[0].Name != "Bazel" {
		t.Errorf("deps = %v, want only the Bazel finding", deps)
	}
	if len(unknowns) != 1 || unknowns[0].File != "web/package.json" {
		t.Fatalf("unknowns = %v, want exactly one unknown for web/package.json", unknowns)
	}
	if !strings.Contains(unknowns[0].Reason, "invalid JSON") {
		t.Errorf("unknown reason = %q, want one containing %q", unknowns[0].Reason, "invalid JSON")
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

// TestScrapeQemu proves build-qemu.sh yields the shared default QEMU_VERSION,
// the distlib wheel version + sha256, and one qemu-source-sha256 dependency per
// supported case arm. Per-consumer qemu pins still live in each consumer's own
// publish script (TestScrapeQemuConsumer).
func TestScrapeQemu(t *testing.T) {
	const script = `
QEMU_VERSION="${QEMU_VERSION:-8.2.2}"
case "$QEMU_VERSION" in
  8.2.2) QEMU_SOURCE_SHA256="${QEMU_SOURCE_SHA256:-847346c1b82c1a54b2c38f6edbd85549edeb17430b7d4d3da12620e2962bc4f3}" ;;
  9.2.4) QEMU_SOURCE_SHA256="${QEMU_SOURCE_SHA256:-f3cc1c4eabfdb288218ac3e33763dbe9e276d8bc890b867a2335d58de2ddd39a}" ;;
esac
QEMU_DISTLIB_URL="${QEMU_DISTLIB_URL:-https://files.pythonhosted.org/packages/02/08/9c41fb51ab5b43eb21674aff13df270e8ba6c4b29c8624e328dc7a9482af/distlib-0.4.3-py2.py3-none-any.whl}"
QEMU_DISTLIB_SHA256="${QEMU_DISTLIB_SHA256:-4b0ce306c966eb73bc3a7b6abad017c556dadd92c44701562cd528ac7fde4d5b}"
`
	deps, unknowns := scrapeQemu([]byte(script), "tools/qemu/build-qemu.sh")
	if len(unknowns) != 0 {
		t.Fatalf("scrapeQemu unknowns = %v, want none", unknowns)
	}
	if got := findDepVersion(t, deps, "script-pin", "qemu", "8.2.2"); got == nil || got.File != "tools/qemu/build-qemu.sh" {
		t.Errorf("build-qemu.sh default qemu not extracted: %v", got)
	}
	if got := findDep(t, deps, "script-pin", "distlib"); got == nil || got.Version != "0.4.3" {
		t.Errorf("distlib not extracted: %v", got)
	}
	if got := findDep(t, deps, "script-pin", "distlib-sha256"); got == nil || got.Version != "4b0ce306c966eb73bc3a7b6abad017c556dadd92c44701562cd528ac7fde4d5b" {
		t.Errorf("distlib-sha256 not extracted: %v", got)
	}
	for version, hash := range map[string]string{
		"8.2.2": "847346c1b82c1a54b2c38f6edbd85549edeb17430b7d4d3da12620e2962bc4f3",
		"9.2.4": "f3cc1c4eabfdb288218ac3e33763dbe9e276d8bc890b867a2335d58de2ddd39a",
	} {
		if got := findDepVersion(t, deps, "script-pin", "qemu-source-sha256", version); got == nil || got.Source != hash {
			t.Errorf("qemu-source-sha256 %s not extracted: %v", version, got)
		}
	}
}

// TestScrapeQemuConsumer proves each consumer's publish script yields exactly
// one script-pin/qemu dependency carrying the consumer's own QEMU_VERSION, the
// download.qemu.org source, the consumer file, and a consumer-labeled note.
func TestScrapeQemuConsumer(t *testing.T) {
	const opensshScript = `
OPENSSH_TAG="${OPENSSH_TAG:-V_10_5_P1}"
OPENSSH_VERSION="${OPENSSH_VERSION:-10.5p1}"
QEMU_VERSION="${QEMU_VERSION:-9.2.4}"
OPENSSH_DIST_ROOTFS="${OPENSSH_DIST_ROOTFS:-}"
`
	deps, unknowns := scrapeQemuConsumer("openssh")([]byte(opensshScript), "tools/openssh/publish.sh")
	if len(unknowns) != 0 {
		t.Fatalf("scrapeQemuConsumer openssh unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 {
		t.Fatalf("scrapeQemuConsumer openssh deps = %v, want exactly one", deps)
	}
	got := deps[0]
	if got.Category != "script-pin" || got.Name != "qemu" || got.Version != "9.2.4" {
		t.Errorf("openssh qemu dep = %v, want script-pin/qemu 9.2.4", got)
	}
	if got.Source != "https://download.qemu.org" {
		t.Errorf("openssh qemu source = %q, want https://download.qemu.org", got.Source)
	}
	if got.File != "tools/openssh/publish.sh" {
		t.Errorf("openssh qemu file = %q, want tools/openssh/publish.sh", got.File)
	}
	if !strings.Contains(got.Note, "openssh") {
		t.Errorf("openssh qemu note = %q, want one containing %q", got.Note, "openssh")
	}

	const ffmpegScript = `
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1}"
QEMU_VERSION="${QEMU_VERSION:-8.2.2}"
FFMPEG_DIST_ROOTFS="${FFMPEG_DIST_ROOTFS:-}"
`
	deps, unknowns = scrapeQemuConsumer("ffmpeg-dist")([]byte(ffmpegScript), "tools/ffmpeg-dist/publish.sh")
	if len(unknowns) != 0 {
		t.Fatalf("scrapeQemuConsumer ffmpeg-dist unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 {
		t.Fatalf("scrapeQemuConsumer ffmpeg-dist deps = %v, want exactly one", deps)
	}
	got = deps[0]
	if got.Version != "8.2.2" {
		t.Errorf("ffmpeg-dist qemu version = %q, want 8.2.2", got.Version)
	}
	if got.File != "tools/ffmpeg-dist/publish.sh" {
		t.Errorf("ffmpeg-dist qemu file = %q, want tools/ffmpeg-dist/publish.sh", got.File)
	}
	if !strings.Contains(got.Note, "ffmpeg-dist") {
		t.Errorf("ffmpeg-dist qemu note = %q, want one containing %q", got.Note, "ffmpeg-dist")
	}
}

// TestScrapeBzlPinQemu proves the qemu_x86_64 repo-rule default in
// tools/bazel/qemu_x86_64.bzl yields exactly one bzl-pin/qemu dependency
// carrying the pinned version, the download.qemu.org source, the bzl file, and
// the cross-stripping note -- and never a script-pin qemu. The fixture carries
// all three attrs (build_script, qemu_version, build_timeout) so the regex
// provably targets only the qemu_version default.
func TestScrapeBzlPinQemu(t *testing.T) {
	const bzl = `
qemu_x86_64 = repository_rule(
    implementation = _qemu_x86_64_impl,
    attrs = {
        "build_script": attr.label(
            default = "//tools/qemu:build-qemu.sh",
            allow_single_file = True,
            doc = "The patched-qemu build script (tracks changes via the label).",
        ),
        "qemu_version": attr.string(
            default = "11.0.2",
            doc = "QEMU_VERSION pin; must match a supported tools/qemu pin.",
        ),
        "build_timeout": attr.int(
            default = 3600,
            doc = "Seconds allowed for the qemu source build (meson/ninja).",
        ),
    },
)
`
	deps, unknowns := scrapeBzlPinQemu([]byte(bzl), "tools/bazel/qemu_x86_64.bzl")
	if len(unknowns) != 0 {
		t.Fatalf("scrapeBzlPinQemu unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 {
		t.Fatalf("scrapeBzlPinQemu deps = %v, want exactly one", deps)
	}
	if findDep(t, deps, "script-pin", "qemu") != nil {
		t.Errorf("scrapeBzlPinQemu must not emit a script-pin qemu: %v", deps)
	}
	got := deps[0]
	if got.Category != "bzl-pin" || got.Name != "qemu" || got.Version != "11.0.2" {
		t.Errorf("bzl-pin qemu dep = %v, want bzl-pin/qemu 11.0.2", got)
	}
	if got.Source != "https://download.qemu.org" {
		t.Errorf("bzl-pin qemu source = %q, want https://download.qemu.org", got.Source)
	}
	if got.File != "tools/bazel/qemu_x86_64.bzl" {
		t.Errorf("bzl-pin qemu file = %q, want tools/bazel/qemu_x86_64.bzl", got.File)
	}
	if !strings.Contains(got.Note, "cross-stripping") {
		t.Errorf("bzl-pin qemu note = %q, want one containing %q", got.Note, "cross-stripping")
	}
}

// TestScrapeDlami proves deploy/aws/launch's pinned DEFAULT_AMI_ID yields
// exactly one ami/dlami dependency carrying the pinned id, the launch file,
// and a us-east-2 annotation.
func TestScrapeDlami(t *testing.T) {
	const script = `DEFAULT_AMI_ID = "ami-07626c4fc6797c8e0"`
	deps, unknowns := scrapeDlami([]byte(script), "deploy/aws/launch")
	if len(unknowns) != 0 {
		t.Fatalf("scrapeDlami unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 {
		t.Fatalf("scrapeDlami deps = %v, want exactly one", deps)
	}
	got := deps[0]
	if got.Category != common.CategoryAMI || got.Name != "dlami" || got.Version != "ami-07626c4fc6797c8e0" {
		t.Errorf("dlami dep = %v, want ami/dlami ami-07626c4fc6797c8e0", got)
	}
	if got.File != "deploy/aws/launch" {
		t.Errorf("dlami file = %q, want deploy/aws/launch", got.File)
	}
	if !strings.Contains(got.Note, "us-east-2") {
		t.Errorf("dlami note = %q, want one mentioning us-east-2", got.Note)
	}
}

// TestScrapeDlamiMissingPin proves a launch file without the pinned constant
// surfaces as an extraction unknown, never a silent drop.
func TestScrapeDlamiMissingPin(t *testing.T) {
	deps, unknowns := scrapeDlami([]byte("# no DEFAULT_AMI_ID here"), "deploy/aws/launch")
	if len(deps) != 0 {
		t.Fatalf("scrapeDlami deps = %v, want none", deps)
	}
	if len(unknowns) != 1 || unknowns[0].Reason != "pin not found: dlami" {
		t.Errorf("scrapeDlami unknowns = %v, want the dlami pin-not-found unknown", unknowns)
	}
}

func TestScrapeOpenssh(t *testing.T) {
	const script = `
OPENSSH_TAG="${OPENSSH_TAG:-V_10_5_P1}"
OPENSSH_VERSION="${OPENSSH_VERSION:-10.5p1}"
M4_SOURCE_URL="${M4_SOURCE_URL:-https://ftp.gnu.org/gnu/m4/m4-1.4.21.tar.gz}"
M4_SOURCE_SHA256="${M4_SOURCE_SHA256:-38ae59f7a30bf9c108193cc5c25fbb06014f21e230c7ede2eff614f7b7c37ed8}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1786924800}"
AMAZONLINUX_TAG="${AMAZONLINUX_TAG:-2023.12.20260817.0}"
`
	deps, unknowns := scrapeOpenssh([]byte(script), "tools/openssh/build.sh", opensshBuildSpecs)
	if len(unknowns) != 0 {
		t.Fatalf("scrapeOpenssh build.sh unknowns = %v, want none", unknowns)
	}
	if got := findDepVersion(t, deps, "script-pin", "openssh-portable", "10.5p1"); got == nil || got.Note != "" {
		t.Errorf("numeric openssh-portable not extracted with an empty note: %v", got)
	}
	if got := findDep(t, deps, "script-pin", "GNU m4"); got == nil || got.Version != "1.4.21" {
		t.Errorf("m4 not extracted: %v", got)
	}

	deps, unknowns = scrapeOpenssh([]byte(script), "tools/openssh/publish.sh", opensshPublishSpecs)
	if len(unknowns) != 0 {
		t.Fatalf("scrapeOpenssh publish.sh unknowns = %v, want none", unknowns)
	}
	if got := findDep(t, deps, "base-image", "amazonlinux"); got == nil || got.Version != "2023.12.20260817.0" {
		t.Errorf("amazonlinux not extracted: %v", got)
	}
}

func TestScrapeFfmpeg(t *testing.T) {
	const script = `
: "${FFMPEG_VERSION:=8.0}"
: "${FFMPEG_COMMIT:=1a748fe2cd43e3ead22fafb1b5b7d77f153898a8}"
: "${NV_CODEC_HEADERS_TAG:=n13.0.19.0}"
: "${NV_CODEC_HEADERS_COMMIT:=88fee5c37318c991a8762d423530f91681e32e3a}"
: "${GENCODE:=arch=compute_75,code=sm_75}"
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

// TestAttrValueQuoteCommentAware asserts attrValue only reads top-level
// `key = "value"` assignments: a nested `version = "9.9.9"` inside a quoted
// build_file_content (or after a '#' comment) must never be picked up, and the
// key must match as a whole word.
func TestAttrValueQuoteCommentAware(t *testing.T) {
	args := `name = "with_nested", build_file_content = "version = \"9.9.9\"\nname = \"inner\"", # version = "8.8.8"
	strip_prefix = "x-1.2.3", version = "1.2.3"`
	if got := attrValue(args, "name"); got != "with_nested" {
		t.Errorf("attrValue(name) = %q, want %q", got, "with_nested")
	}
	if got := attrValue(args, "version"); got != "1.2.3" {
		t.Errorf("attrValue(version) = %q, want the top-level 1.2.3, never the nested 9.9.9 or commented 8.8.8", got)
	}
	if got := attrValue(args, "strip_prefix"); got != "x-1.2.3" {
		t.Errorf("attrValue(strip_prefix) = %q, want %q", got, "x-1.2.3")
	}
	if got := attrValue(`module_name = "bazel_lib"`, "name"); got != "" {
		t.Errorf("attrValue(name) matched inside module_name: got %q, want empty", got)
	}
	if got := attrValue(`names = "plural"`, "name"); got != "" {
		t.Errorf("attrValue(name) matched names: got %q, want empty", got)
	}
	// Single-quoted values are first-class: the first assignment wins even
	// when its value uses the single-quote style.
	if got := attrValue(`name = 'singlevalue'`, "name"); got != "singlevalue" {
		t.Errorf("attrValue(name) should extract the single-quoted value: got %q, want %q", got, "singlevalue")
	}
	if got := attrValue(`name = 'single quoted', name = "double"`, "name"); got != "single quoted" {
		t.Errorf("attrValue(name) should take the first (single-quoted) assignment: got %q, want %q", got, "single quoted")
	}
	// A single-quoted value elsewhere must not interfere with extracting a
	// later key's double-quoted value.
	if got := attrValue(`name = 'single quoted', version = "1.2.3"`, "version"); got != "1.2.3" {
		t.Errorf("attrValue(version) should read past the single-quoted value: got %q, want %q", got, "1.2.3")
	}
	// Backslash escapes are honored inside single-quoted values too.
	if got := attrValue(`name = 'it\'s escaped'`, "name"); got != "it's escaped" {
		t.Errorf("attrValue(name) should unescape the single-quoted value: got %q, want %q", got, "it's escaped")
	}
}

// TestParseModuleBazelNestedVersionIgnored proves a `version = "9.9.9"` string
// nested inside build_file_content is not read as the http_archive version:
// the pin must come from strip_prefix/url instead.
func TestParseModuleBazelNestedVersionIgnored(t *testing.T) {
	const module = `
http_archive(
    name = "nested_version",
    build_file_content = "version = \"9.9.9\"",
    sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
    strip_prefix = "example-4.5.6",
    url = "https://example.com/releases/download/v4.5.6/example-4.5.6.tar.gz",
)
`
	deps, unknowns := parseModuleBazel([]byte(module), "MODULE.bazel")
	if len(unknowns) != 0 {
		t.Fatalf("parseModuleBazel unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 {
		t.Fatalf("parseModuleBazel deps = %v, want 1", deps)
	}
	if deps[0].Version != "4.5.6" {
		t.Errorf("http_archive version = %q, want 4.5.6 from strip_prefix, never the nested 9.9.9", deps[0].Version)
	}
}

// TestScanCallArgsQuoteAndCommentAware asserts the paren-balancing scan ignores
// parentheses inside quoted strings and after '#' comments, so a call whose
// arguments contain `")"` or `# comment )` still captures the full text.
func TestScanCallArgsQuoteAndCommentAware(t *testing.T) {
	tests := []struct {
		name     string
		content  string
		callName string
		want     string
	}{
		{
			name:     "parens inside double-quoted string",
			content:  `http_archive(name = "foo", build_file_content = "fn()")`,
			callName: "http_archive",
			want:     `name = "foo", build_file_content = "fn()"`,
		},
		{
			name:     "parens inside single-quoted string with escape",
			content:  `http_archive(name = 'it\'s', url = "x(y)")`,
			callName: "http_archive",
			want:     `name = 'it\'s', url = "x(y)"`,
		},
		{
			name:     "paren in trailing comment",
			content:  "http_archive(name = \"bar\", # comment ) stays ignored\n  url = \"x\")",
			callName: "http_archive",
			want:     "name = \"bar\", # comment ) stays ignored\n  url = \"x\"",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := scanCallArgs(tt.content, tt.callName)
			if len(got) != 1 || got[0] != tt.want {
				t.Errorf("scanCallArgs(%q, %q) = %q, want [%q]", tt.content, tt.callName, got, tt.want)
			}
		})
	}
}

// TestExtractModuleBazelRealRepo is the integration guard: every repo-rule pin,
// deb_extract, cross sysroot, apt.install package, s3 integrity pin, qemu call,
// and http_archive protoc pin that actually ships in this repo's MODULE.bazel is
// extracted with its expected version. It locates the repo root by walking up
// from the test working directory and skips when MODULE.bazel is absent (e.g. a
// hermetic test sandbox).
func TestExtractModuleBazelRealRepo(t *testing.T) {
	root := findModuleRoot(t)

	deps, unknowns := ExtractModuleBazel(root)
	if len(unknowns) != 0 {
		t.Fatalf("real repo unknowns = %v, want none", unknowns)
	}

	// Named pins whose category and version must match exactly.
	named := []struct {
		category string
		name     string
		version  string
	}{
		{common.CategoryToolBinary, "libwebsockets", "5.0.0"},
		{common.CategoryToolBinary, "libprotobuf_dev_arm64", "3.21.12-11+deb13u1"},
		{common.CategoryToolBinary, "libprotoc_dev_arm64", "3.21.12-11+deb13u1"},
		{common.CategoryToolBinary, "protobuf_compiler_arm64", "3.21.12-11+deb13u1"},
		{common.CategoryToolchain, "amd64_sysroot:libc6", "2.41-11cross1"},
		{common.CategoryToolchain, "amd64_sysroot:libgcc", "14.2.0-19cross1"},
		{common.CategoryToolchain, "amd64_sysroot:linux_libc", "6.12.38-1cross1"},
		{common.CategoryToolBinary, "qemu_x86_64_patched", "11.0.4"},
		{common.CategoryToolBinary, "protoc_linux_aarch64", "36.2"},
		{common.CategoryToolBinary, "protoc_linux_x86_64", "36.2"},
	}
	for _, tc := range named {
		if got := findDepVersion(t, deps, tc.category, tc.name, tc.version); got == nil {
			t.Errorf("%s %q version %q not extracted", tc.category, tc.name, tc.version)
		}
	}

	// The 13 apt.install packages, each a versionless base-image donor (the
	// pinned snapshot governs, not a per-package version).
	aptPackages := []string{
		"dash", "busybox-static", "gettext-base", "ca-certificates",
		"libfdk-aac2t64", "libc6", "coreutils", "libbinutils", "libsframe1",
		"zlib1g", "libzstd1", "libgcc-s1", "binutils-x86-64-linux-gnu",
	}
	for _, name := range aptPackages {
		got := findDep(t, deps, common.CategoryBaseImage, name)
		if got == nil || got.Version != "" {
			t.Errorf("apt.install package %q not extracted as a versionless base-image donor: %v", name, got)
		}
	}

	// The 5 self-published s3 artifacts, each an integrity pin.
	s3Artifacts := []struct {
		category string
		name     string
	}{
		{common.CategoryToolBinary, "ffmpeg_dist"},
		{common.CategoryToolBinary, "ffmpeg_dist_arm64"},
		{common.CategoryRuntime, "offline_segment_dist"},
		{common.CategoryRuntime, "openssh_dist"},
		{common.CategoryRuntime, "openssh_dist_arm64"},
	}
	for _, tc := range s3Artifacts {
		got := findDep(t, deps, tc.category, tc.name)
		if got == nil || !got.IsIntegrity() {
			t.Errorf("s3 artifact %s %q not extracted as an integrity pin: %v", tc.category, tc.name, got)
		}
	}
}

// findModuleRoot walks up from the test working directory to the directory that
// contains MODULE.bazel, skipping the test when none is found.
func findModuleRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		if info, statErr := os.Stat(filepath.Join(dir, "MODULE.bazel")); statErr == nil && !info.IsDir() {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Skip("no MODULE.bazel above test working directory; skipping repo integration test")
		}
		dir = parent
	}
}
