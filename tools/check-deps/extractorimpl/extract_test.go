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

// TestScrapeQemu proves build-qemu.sh now yields only the distlib wheel pin:
// qemu versions are tracked per consumer (their publish scripts), not scraped
// out of the shared build script.
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
	if findDep(t, deps, "script-pin", "qemu") != nil {
		t.Errorf("scrapeQemu must not emit a qemu dependency from build-qemu.sh: %v", deps)
	}
	if len(deps) != 1 {
		t.Fatalf("scrapeQemu deps = %v, want exactly the distlib dependency", deps)
	}
	if got := findDep(t, deps, "script-pin", "distlib"); got == nil || got.Version != "0.4.3" {
		t.Errorf("distlib not extracted: %v", got)
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

func TestScrapeOpenssh(t *testing.T) {
	const script = `
OPENSSH_TAG="${OPENSSH_TAG:-V_10_5_P1}"
OPENSSH_VERSION="${OPENSSH_VERSION:-10.5p1}"
M4_SOURCE_URL="${M4_SOURCE_URL:-https://ftp.gnu.org/gnu/m4/m4-1.4.21.tar.gz}"
AMAZONLINUX_TAG="${AMAZONLINUX_TAG:-2023.12.20260817.0}"
`
	deps, unknowns := scrapeOpenssh([]byte(script), "tools/openssh/build.sh", opensshBuildSpecs)
	if len(unknowns) != 0 {
		t.Fatalf("scrapeOpenssh build.sh unknowns = %v, want none", unknowns)
	}
	if got := findDep(t, deps, "script-pin", "openssh-portable"); got == nil || got.Version != "10.5p1" || got.Note != "git tag V_10_5_P1" {
		t.Errorf("openssh-portable not extracted: %v", got)
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
