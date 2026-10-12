package extractorimpl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"strimserver-check-deps/common"
)

// This file covers the pins added to scripts.go beyond the original allowlist:
// the ffmpeg-dist commits/gencode, the openssh tarball hash + reproducible
// clock + promoted OPENSSH_TAG dependency, the qemu build-script pins, the
// upload-artifact and fish-deploy pins, and the directory-discovery
// fail-closed pass. Helpers are self-contained (sm prefix) so this file does
// not depend on the pre-existing extract_test.go.

func smWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("creating fixture directory: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("writing fixture file: %v", err)
	}
}

func smFind(deps []common.Dependency, category, name string) *common.Dependency {
	for i := range deps {
		if deps[i].Category == category && deps[i].Name == name {
			return &deps[i]
		}
	}
	return nil
}

func smFindVersion(deps []common.Dependency, category, name, version string) *common.Dependency {
	for i := range deps {
		if deps[i].Category == category && deps[i].Name == name && deps[i].Version == version {
			return &deps[i]
		}
	}
	return nil
}

const (
	ffmpegCommit  = "1a748fe2cd43e3ead22fafb1b5b7d77f153898a8"
	nvCodecCommit = "88fee5c37318c991a8762d423530f91681e32e3a"
)

// TestScrapeFfmpegCommitsAndGencode proves both declaration shapes
// (`: "${NAME:=...}"` in build.sh and `NAME="${NAME:-...}"` in publish.sh) yield
// the exact ffmpeg / nv-codec-headers commits and the nvcc gencode target,
// while the `${NAME:0:7}` substring expansions elsewhere in publish.sh are
// never mistaken for pins.
func TestScrapeFfmpegCommitsAndGencode(t *testing.T) {
	const buildShape = `
: "${FFMPEG_VERSION:=8.1}"
: "${FFMPEG_COMMIT:=1a748fe2cd43e3ead22fafb1b5b7d77f153898a8}"
: "${NV_CODEC_HEADERS_TAG:=n13.0.19.1}"
: "${NV_CODEC_HEADERS_COMMIT:=88fee5c37318c991a8762d423530f91681e32e3a}"
: "${CUDA_MANIFEST_URL:=https://developer.download.nvidia.com/compute/cuda/redist/redistrib_13.2.2.json}"
: "${DEBIAN_SNAPSHOT:=20261005T000000Z}"
: "${GENCODE:=arch=compute_75,code=sm_75}"
`
	const publishShape = `
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1}"
FFMPEG_COMMIT="${FFMPEG_COMMIT:-1a748fe2cd43e3ead22fafb1b5b7d77f153898a8}"
NV_CODEC_HEADERS_TAG="${NV_CODEC_HEADERS_TAG:-n13.0.19.1}"
NV_CODEC_HEADERS_COMMIT="${NV_CODEC_HEADERS_COMMIT:-88fee5c37318c991a8762d423530f91681e32e3a}"
CUDA_MANIFEST_URL="${CUDA_MANIFEST_URL:-https://developer.download.nvidia.com/compute/cuda/redist/redistrib_13.2.2.json}"
DEBIAN_SNAPSHOT="${DEBIAN_SNAPSHOT:-20261005T000000Z}"
GENCODE="${GENCODE:-arch=compute_75,code=sm_75}"
artifact="ffmpeg-${FFMPEG_VERSION}-deb${deb_date}-nv${NV_CODEC_HEADERS_COMMIT:0:7}-${FFMPEG_COMMIT:0:7}.tar.gz"
`
	for name, script := range map[string]string{"build.sh": buildShape, "publish.sh": publishShape} {
		t.Run(name, func(t *testing.T) {
			deps, unknowns := scrapeFfmpeg([]byte(script), "tools/ffmpeg-dist/"+name)
			if len(unknowns) != 0 {
				t.Fatalf("scrapeFfmpeg unknowns = %v, want none", unknowns)
			}
			if got := smFind(deps, "script-pin", "ffmpeg-commit"); got == nil || got.Version != ffmpegCommit {
				t.Errorf("ffmpeg-commit = %v, want %s", got, ffmpegCommit)
			}
			if got := smFind(deps, "script-pin", "nv-codec-headers-commit"); got == nil || got.Version != nvCodecCommit {
				t.Errorf("nv-codec-headers-commit = %v, want %s", got, nvCodecCommit)
			}
			if got := smFind(deps, "script-pin", "gencode"); got == nil || got.Version != "arch=compute_75,code=sm_75" {
				t.Errorf("gencode = %v, want arch=compute_75,code=sm_75", got)
			}
			if got := smFind(deps, "script-pin", "ffmpeg"); got == nil || got.Version != "8.1" {
				t.Errorf("ffmpeg = %v, want 8.1", got)
			}
			if got := smFind(deps, "base-image", "debian"); got == nil || got.Version != "20261005T000000Z" {
				t.Errorf("debian = %v, want 20261005T000000Z", got)
			}
		})
	}
}

// TestScrapeOpensshShaEpochTag proves build.sh yields the m4 tarball sha256 and
// the readable reproducible clock, and that OPENSSH_TAG is promoted from an
// annotation to its own openssh-portable dependency (reusing the existing
// OpenSSH scrape resolver by name).
func TestScrapeOpensshShaEpochTag(t *testing.T) {
	const script = `
OPENSSH_TAG="${OPENSSH_TAG:-V_10_6_P1}"
OPENSSH_VERSION="${OPENSSH_VERSION:-10.6p1}"
M4_SOURCE_URL="${M4_SOURCE_URL:-https://ftp.gnu.org/gnu/m4/m4-1.4.21.tar.gz}"
M4_SOURCE_SHA256="${M4_SOURCE_SHA256:-38ae59f7a30bf9c108193cc5c25fbb06014f21e230c7ede2eff614f7b7c37ed8}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1786924800}"   # 2026-08-17T00:00:00Z
`
	deps, unknowns := scrapeOpenssh([]byte(script), "tools/openssh/build.sh", opensshBuildSpecs)
	if len(unknowns) != 0 {
		t.Fatalf("scrapeOpenssh unknowns = %v, want none", unknowns)
	}
	if got := smFindVersion(deps, "script-pin", "openssh-portable", "10.6p1"); got == nil {
		t.Errorf("openssh-portable 10.6p1 not extracted: %v", deps)
	}
	if got := smFindVersion(deps, "script-pin", "openssh-portable", "V_10_6_P1"); got == nil {
		t.Errorf("OPENSSH_TAG not promoted to a dependency: %v", deps)
	}
	if got := smFind(deps, "script-pin", "GNU m4"); got == nil || got.Version != "1.4.21" {
		t.Errorf("GNU m4 = %v, want 1.4.21", got)
	}
	if got := smFind(deps, "script-pin", "GNU m4-sha256"); got == nil || got.Version != "38ae59f7a30bf9c108193cc5c25fbb06014f21e230c7ede2eff614f7b7c37ed8" {
		t.Errorf("GNU m4-sha256 = %v", got)
	}
	got := smFind(deps, "script-pin", "source-date-epoch")
	if got == nil || got.Version != "1786924800" {
		t.Fatalf("source-date-epoch = %v, want 1786924800", got)
	}
	if !strings.Contains(got.Note, "2026-08-17T00:00:00Z") {
		t.Errorf("source-date-epoch note = %q, want one containing the UTC date", got.Note)
	}

	publishScript := `
OPENSSH_TAG="${OPENSSH_TAG:-V_10_6_P1}"
OPENSSH_VERSION="${OPENSSH_VERSION:-10.6p1}"
AMAZONLINUX_TAG="${AMAZONLINUX_TAG:-2023.12.20260817.0}"
`
	pubDeps, pubUnknowns := scrapeOpenssh([]byte(publishScript), "tools/openssh/publish.sh", opensshPublishSpecs)
	if len(pubUnknowns) != 0 {
		t.Fatalf("scrapeOpenssh publish unknowns = %v, want none", pubUnknowns)
	}
	if got := smFind(pubDeps, "base-image", "amazonlinux"); got == nil || got.Version != "2023.12.20260817.0" {
		t.Errorf("amazonlinux = %v", got)
	}
	if got := smFindVersion(pubDeps, "script-pin", "openssh-portable", "V_10_6_P1"); got == nil {
		t.Errorf("publish.sh tag not promoted: %v", pubDeps)
	}
}

// TestScrapeOpensshMissingTagFailsClosed proves a file without OPENSSH_TAG
// surfaces a tag-not-found unknown rather than silently dropping the tag pin.
func TestScrapeOpensshMissingTagFailsClosed(t *testing.T) {
	_, unknowns := scrapeOpenssh([]byte(`OPENSSH_VERSION="${OPENSSH_VERSION:-10.6p1}"`), "tools/openssh/publish.sh", opensshPublishSpecs)
	if !hasUnknownReason(unknowns, "OPENSSH_TAG") {
		t.Errorf("unknowns = %v, want one mentioning OPENSSH_TAG", unknowns)
	}
}

// TestScrapeQemuBuildPins proves build-qemu.sh yields the default QEMU_VERSION,
// the distlib wheel pair, and one qemu-source-sha256 dependency per supported
// case arm (the `*)` fallback arm contributes nothing).
func TestScrapeQemuBuildPins(t *testing.T) {
	const script = `
QEMU_VERSION="${QEMU_VERSION:-8.2.2}"
case "$QEMU_VERSION" in
  8.2.2) QEMU_SOURCE_SHA256="${QEMU_SOURCE_SHA256:-847346c1b82c1a54b2c38f6edbd85549edeb17430b7d4d3da12620e2962bc4f3}" ;;
  9.2.4) QEMU_SOURCE_SHA256="${QEMU_SOURCE_SHA256:-f3cc1c4eabfdb288218ac3e33763dbe9e276d8bc890b867a2335d58de2ddd39a}" ;;
  11.0.2) QEMU_SOURCE_SHA256="${QEMU_SOURCE_SHA256:-3745f6ea88e2e87fe0dc838b2b1d4e0a770bf48e01a1d5a186842a1fff76ccf5}" ;;
  11.0.4) QEMU_SOURCE_SHA256="${QEMU_SOURCE_SHA256:-b099a10abe4a98ac1a53a4f52cb2367651ad9fcd1c0531beb14921f1524ca9ae}" ;;
  *)     QEMU_SOURCE_SHA256="${QEMU_SOURCE_SHA256:-}" ;;
esac
QEMU_DISTLIB_URL="${QEMU_DISTLIB_URL:-https://files.pythonhosted.org/packages/02/08/9c41fb51ab5b43eb21674aff13df270e8ba6c4b29c8624e328dc7a9482af/distlib-0.4.3-py2.py3-none-any.whl}"
QEMU_DISTLIB_SHA256="${QEMU_DISTLIB_SHA256:-4b0ce306c966eb73bc3a7b6abad017c556dadd92c44701562cd528ac7fde4d5b}"
`
	deps, unknowns := scrapeQemu([]byte(script), "tools/qemu/build-qemu.sh")
	if len(unknowns) != 0 {
		t.Fatalf("scrapeQemu unknowns = %v, want none", unknowns)
	}
	if got := smFindVersion(deps, "script-pin", "qemu", "8.2.2"); got == nil || got.File != "tools/qemu/build-qemu.sh" {
		t.Errorf("default qemu pin = %v, want script-pin/qemu 8.2.2", got)
	}
	if got := smFind(deps, "script-pin", "distlib"); got == nil || got.Version != "0.4.3" {
		t.Errorf("distlib = %v, want 0.4.3", got)
	}
	if got := smFind(deps, "script-pin", "distlib-sha256"); got == nil || got.Version != "4b0ce306c966eb73bc3a7b6abad017c556dadd92c44701562cd528ac7fde4d5b" {
		t.Errorf("distlib-sha256 = %v", got)
	}
	arms := map[string]string{
		"8.2.2":  "847346c1b82c1a54b2c38f6edbd85549edeb17430b7d4d3da12620e2962bc4f3",
		"9.2.4":  "f3cc1c4eabfdb288218ac3e33763dbe9e276d8bc890b867a2335d58de2ddd39a",
		"11.0.2": "3745f6ea88e2e87fe0dc838b2b1d4e0a770bf48e01a1d5a186842a1fff76ccf5",
		"11.0.4": "b099a10abe4a98ac1a53a4f52cb2367651ad9fcd1c0531beb14921f1524ca9ae",
	}
	for version, hash := range arms {
		got := smFindVersion(deps, "script-pin", "qemu-source-sha256", version)
		if got == nil {
			t.Errorf("qemu-source-sha256 %s not extracted", version)
			continue
		}
		if got.Source != hash {
			t.Errorf("qemu-source-sha256 %s source = %q, want %q", version, got.Source, hash)
		}
	}
	if got := smFindVersion(deps, "script-pin", "qemu-source-sha256", "*"); got != nil {
		t.Errorf("the `*)` fallback arm must not yield a dependency: %v", got)
	}
}

// TestScrapeQemuSourceHashes proves the arm parser enumerates only
// version-labelled arms and carries the hash as the Source digest.
func TestScrapeQemuSourceHashes(t *testing.T) {
	hash := strings.Repeat("a", 64)
	content := "  1.2.3) QEMU_SOURCE_SHA256=\"${QEMU_SOURCE_SHA256:-" + hash + "}\" ;;\n" +
		"  *)     QEMU_SOURCE_SHA256=\"${QEMU_SOURCE_SHA256:-}\" ;;\n"
	deps, unknowns := scrapeQemuSourceHashes(content, "tools/qemu/build-qemu.sh")
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 {
		t.Fatalf("deps = %v, want exactly the 1.2.3 arm", deps)
	}
	if deps[0].Version != "1.2.3" || deps[0].Source != hash || deps[0].Name != "qemu-source-sha256" {
		t.Errorf("arm dep = %v, want qemu-source-sha256 1.2.3 with the hash as Source", deps[0])
	}
}

// TestScrapeUploadArtifact proves the upload contract hash is extracted with
// the uppercase `:=` and `:-` forms.
func TestScrapeUploadArtifact(t *testing.T) {
	const hash = "2df93667c7e12f2666be244772a41c653a02cab74880e685623770bd9c86ac34"
	for name, script := range map[string]string{
		"upper":   `EXPECTED_SHA256="${EXPECTED_SHA256:-` + hash + `}"`,
		"default": `: "${EXPECTED_SHA256:=` + hash + `}"`,
	} {
		t.Run(name, func(t *testing.T) {
			deps, unknowns := scrapeUploadArtifact([]byte(script), "scripts/upload-artifact.sh")
			if len(unknowns) != 0 {
				t.Fatalf("unknowns = %v, want none", unknowns)
			}
			if got := smFind(deps, "script-pin", "ffmpeg-dist-sha256"); got == nil || got.Version != hash {
				t.Errorf("ffmpeg-dist-sha256 = %v, want %s", got, hash)
			}
		})
	}
}

// TestScrapeFish proves the fish release version is derived from the pinned
// distribution URL.
func TestScrapeFish(t *testing.T) {
	const script = `FISH_DIST_URL="https://github.com/fish-shell/fish-shell/releases/download/4.3.1/fish-4.3.1-linux-x86_64.tar.xz"`
	deps, unknowns := scrapeFish([]byte(script), "deploy/aws/fish-deploy.sh")
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	got := smFind(deps, "script-pin", "fish")
	if got == nil || got.Version != "4.3.1" || got.Source != "https://github.com/fish-shell/fish-shell" {
		t.Errorf("fish = %v, want script-pin/fish 4.3.1", got)
	}
}

// TestScriptPinCarrierDetection pins the fail-closed detector's boundary: real
// pins (assignment or env-default, with a value) are carriers; empty defaults,
// bare expansions, and comments are not.
func TestScriptPinCarrierDetection(t *testing.T) {
	carriers := []string{
		`FOO_VERSION="${FOO_VERSION:-1.2.3}"`,
		`: "${BAR_SHA256:=` + strings.Repeat("d", 64) + `}"`,
		`BAZ_COMMIT=abcdef0123456789abcdef0123456789abcdef01`,
	}
	for _, s := range carriers {
		if !scriptPinCarrierRe.MatchString(s) {
			t.Errorf("expected %q to be detected as a pin carrier", s)
		}
	}
	notCarriers := []string{
		`GIT_COMMIT="${GIT_COMMIT:-}"`,  // empty default: not a pin
		`QEMU_VERSION="$QEMU_VERSION"`,  // bare expansion: no assigned value
		`# see FOO_VERSION for details`, // no assignment
		`echo "no pins here"`,           // no pin token
		`NV_CODEC_HEADERS_COMMIT:0:7`,   // substring expansion, no `}` value
	}
	for _, s := range notCarriers {
		if scriptPinCarrierRe.MatchString(s) {
			t.Errorf("expected %q NOT to be detected as a pin carrier", s)
		}
	}
}

// TestExtractScriptsDiscoveryFailClosed drives the full extractor over a
// synthetic tree: a known script is parsed, an unregistered script carrying a
// pin fails closed with a descriptive unknown, and non-pinned scripts (and
// non-script files, even pin-shaped ones) are ignored.
func TestExtractScriptsDiscoveryFailClosed(t *testing.T) {
	root := t.TempDir()
	hash := strings.Repeat("c", 64)
	smWrite(t, filepath.Join(root, "scripts", "upload-artifact.sh"), `EXPECTED_SHA256="${EXPECTED_SHA256:-`+hash+`}"`)
	smWrite(t, filepath.Join(root, "tools", "newtool", "build.sh"), `NEWTOOL_VERSION="${NEWTOOL_VERSION:-1.2.3}"`)
	smWrite(t, filepath.Join(root, "scripts", "helper.sh"), "echo no pins here\n")
	smWrite(t, filepath.Join(root, "tools", "notes.txt"), "NEWTOOL_VERSION=9.9.9\n")

	deps, unknowns := ExtractScripts(root)

	got := smFindVersion(deps, "script-pin", "ffmpeg-dist-sha256", hash)
	if got == nil || got.File != "scripts/upload-artifact.sh" {
		t.Errorf("known script not parsed: %v", got)
	}

	failClosed := 0
	for _, u := range unknowns {
		switch u.File {
		case "tools/newtool/build.sh":
			failClosed++
			if u.Reason != unspecifiedPinReason {
				t.Errorf("fail-closed reason = %q, want %q", u.Reason, unspecifiedPinReason)
			}
		case "scripts/helper.sh", "tools/notes.txt":
			t.Errorf("non-pinned/non-script file %s must not be flagged: %v", u.File, u)
		}
	}
	if failClosed != 1 {
		t.Errorf("fail-closed unknowns for tools/newtool/build.sh = %d, want 1", failClosed)
	}
}

// hasUnknownReason reports whether any unknown's Reason contains substr.
func hasUnknownReason(unknowns []common.ExtractionUnknown, substr string) bool {
	for _, u := range unknowns {
		if strings.Contains(u.Reason, substr) {
			return true
		}
	}
	return false
}
