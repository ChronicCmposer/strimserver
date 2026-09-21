package resolverimpl

import (
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"strimserver-check-deps/common"
)

// Phase 2 + Phase 6.3a AWS DLAMI resolver unit tests. The pure parsers run
// against inline fixtures; the chain tests inject a fake `aws` shim via PATH
// (the same pattern resolvePNPM's tests use for corepack), so no real aws
// binary and no network are touched. The dual-arch resolver queries both the
// x86_64 and the arm64 SSM parameter, so the shim dispatches on --name and
// can answer each architecture independently.

// fakeAWS writes an executable aws shim into dir that answers both the x86_64
// and the arm64 SSM queries with the same fixture and exit, and answers
// describe-images with describeFixture/describeExit. It is the convenience
// form of fakeAWSArch for tests that do not need to distinguish the
// architectures (0 = success, nonzero = failure).
func fakeAWS(t *testing.T, dir, ssmFixture string, ssmExit int, describeFixture string, describeExit int) {
	t.Helper()
	fakeAWSArch(t, dir, ssmFixture, ssmExit, ssmFixture, ssmExit, describeFixture, describeExit)
}

// fakeAWSArch writes an executable aws shim into dir that dispatches on the
// first subcommand and, for ssm, on the --name parameter: "ssm --name
// *x86_64*" prints x86Fixture and exits x86Exit, "ssm --name *arm64*" prints
// arm64Fixture and exits arm64Exit, "ec2 describe-images" prints
// describeFixture and exits describeExit. Any other invocation prints nothing
// and exits 255. When AWS_SSM_LOG is set, each ssm invocation appends the
// queried parameter name to that file, so tests can prove both architecture
// parameters were queried.
func fakeAWSArch(t *testing.T, dir, x86Fixture string, x86Exit int, arm64Fixture string, arm64Exit int, describeFixture string, describeExit int) {
	t.Helper()
	script := "#!/bin/sh\n" +
		"name=\"\"\n" +
		"prev=\"\"\n" +
		"for arg in \"$@\"; do\n" +
		"  if [ \"$prev\" = \"--name\" ]; then name=\"$arg\"; fi\n" +
		"  prev=\"$arg\"\n" +
		"done\n" +
		"if [ \"$1\" = \"ssm\" ] && [ -n \"$AWS_SSM_LOG\" ]; then printf '%s\\n' \"$name\" >> \"$AWS_SSM_LOG\"; fi\n" +
		"case \"$1\" in\n" +
		"  ssm)\n" +
		"    case \"$name\" in\n" +
		"      *x86_64*) printf '%s\\n' '" + x86Fixture + "'; exit " + strconv.Itoa(x86Exit) + " ;;\n" +
		"      *arm64*) printf '%s\\n' '" + arm64Fixture + "'; exit " + strconv.Itoa(arm64Exit) + " ;;\n" +
		"      *) printf '%s\\n' '" + x86Fixture + "'; exit " + strconv.Itoa(x86Exit) + " ;;\n" +
		"    esac ;;\n" +
		"  ec2) shift\n" +
		"    if [ \"$1\" = \"describe-images\" ]; then printf '%s\\n' '" + describeFixture + "'; exit " + strconv.Itoa(describeExit) + "; fi ;;\n" +
		"esac\n" +
		"exit 255\n"
	if err := os.WriteFile(filepath.Join(dir, "aws"), []byte(script), 0o755); err != nil {
		t.Fatalf("writing aws shim: %v", err)
	}
}

func TestParseAWSCLISSMOutput(t *testing.T) {
	cases := []struct {
		in   string
		want string
		err  bool
	}{
		{"ami-07626c4fc6797c8e0\n", "ami-07626c4fc6797c8e0", false},
		{"  ami-0123456789abcdef0  \n", "ami-0123456789abcdef0", false},
		{"ami-12345678\n", "ami-12345678", false}, // 8-hex legacy id
		{"", "", true},
		{"ami-123\n", "", true},                                // too short
		{"not-an-ami\n", "", true},                             // not an id at all
		{"ami-0123456789abcdef0 extra\n", "", true},            // id plus trailing junk
		{"Parameter.Value\nami-0123456789abcdef0\n", "", true}, // full JSON-ish output
	}
	for _, tc := range cases {
		got, err := parseAWSCLISSMOutput([]byte(tc.in))
		if tc.err {
			if err == nil {
				t.Errorf("parseAWSCLISSMOutput(%q) = %q, want error", tc.in, got)
			}
			continue
		}
		if err != nil || got != tc.want {
			t.Errorf("parseAWSCLISSMOutput(%q) = %q, %v; want %q", tc.in, got, err, tc.want)
		}
	}
}

func TestParseDescribeImagesOutput(t *testing.T) {
	cases := []struct {
		in      string
		name    string
		created string
		err     bool
	}{
		{"base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806\t2026-08-06T12:00:00Z\n", "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806", "2026-08-06T12:00:00Z", false},
		{"  base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806\t2026-08-06T12:00:00Z  \n", "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806", "2026-08-06T12:00:00Z", false},
		{"", "", "", true},                         // empty output (no matching image)
		{"only-a-name\n", "", "", true},            // one field, no tab
		{"name\tcreated\textra\n", "", "", true},   // three fields
		{"\t2026-08-06T12:00:00Z\n", "", "", true}, // empty name field
		{"name\t\n", "", "", true},                 // empty creation date field
	}
	for _, tc := range cases {
		name, created, err := parseDescribeImagesOutput([]byte(tc.in))
		if tc.err {
			if err == nil {
				t.Errorf("parseDescribeImagesOutput(%q) = %q, %q, want error", tc.in, name, created)
			}
			continue
		}
		if err != nil || name != tc.name || created != tc.created {
			t.Errorf("parseDescribeImagesOutput(%q) = %q, %q, %v; want %q, %q", tc.in, name, created, err, tc.name, tc.created)
		}
	}
}

// TestResolveDLAMIFromAWSCLI proves the awscli primary resolves a bare
// ami-... line from `aws ssm get-parameter` output and that the best-effort
// describe-images metadata for the current pin and for both architecture
// latest ids is surfaced; the fetcher is never reached, so nil is safe here.
func TestResolveDLAMIFromAWSCLI(t *testing.T) {
	binDir := t.TempDir()
	const describeOut = "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806\t2026-08-06T12:00:00Z"
	fakeAWS(t, binDir, "ami-07626c4fc6797c8e0", 0, describeOut, 0)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	vi := DLAMIResolve(nil, 5*time.Second)(common.Dependency{Category: common.CategoryAMI, Name: "dlami", Version: "ami-0123456789abcdef0"})
	if vi.Err != nil || vi.Version != "ami-07626c4fc6797c8e0" {
		t.Fatalf("DLAMIResolve = %+v, want ami-07626c4fc6797c8e0 with no error", vi)
	}
	if vi.Date != "2026-08-06T12:00:00Z" {
		t.Errorf("Date = %q, want the latest CreationDate", vi.Date)
	}
	wantMeta := map[string]string{
		"current_name":         "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806",
		"current_created":      "2026-08-06T12:00:00Z",
		"latest_name":          "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806",
		"latest_created":       "2026-08-06T12:00:00Z",
		"latest_arm64_name":    "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806",
		"latest_arm64_created": "2026-08-06T12:00:00Z",
	}
	if !maps.Equal(vi.Metadata, wantMeta) {
		t.Errorf("Metadata = %v, want %v", vi.Metadata, wantMeta)
	}
}

// TestResolveDLAMIMetadataFailureKeepsVersion proves describe-images failures
// are best-effort: when SSM resolves the latest ids but the describe calls
// fail (a stale current id, missing permissions), the resolution still
// succeeds with the id — only the metadata is omitted.
func TestResolveDLAMIMetadataFailureKeepsVersion(t *testing.T) {
	binDir := t.TempDir()
	fakeAWS(t, binDir, "ami-07626c4fc6797c8e0", 0, "aws: error: AccessDenied", 255)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	vi := DLAMIResolve(nil, 5*time.Second)(common.Dependency{Category: common.CategoryAMI, Name: "dlami", Version: "ami-0123456789abcdef0"})
	if vi.Err != nil || vi.Version != "ami-07626c4fc6797c8e0" {
		t.Fatalf("DLAMIResolve = %+v, want ami-07626c4fc6797c8e0 with no error despite describe-images failure", vi)
	}
	if len(vi.Metadata) != 0 {
		t.Errorf("Metadata = %v, want empty when describe-images fails", vi.Metadata)
	}
	if vi.Date != "" {
		t.Errorf("Date = %q, want empty when the latest describe fails", vi.Date)
	}
}

// TestResolveDLAMIUnknownWhenAWSCLIFails proves a failing awscli primary
// (nonzero exit, e.g. missing credentials) yields an unknown (Err set, no
// version) — never a panic and never a fabricated id — and that the error
// attributes the awscli failure.
func TestResolveDLAMIUnknownWhenAWSCLIFails(t *testing.T) {
	binDir := t.TempDir()
	fakeAWS(t, binDir, "aws: error: Unable to locate credentials", 255, "", 0)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	vi := DLAMIResolve(nil, 5*time.Second)(common.Dependency{Category: common.CategoryAMI, Name: "dlami"})
	if vi.Err == nil {
		t.Fatalf("DLAMIResolve = %+v, want an error (unknown)", vi)
	}
	if !strings.Contains(vi.Err.Error(), "aws ssm get-parameter failed") {
		t.Errorf("error = %q, want it to attribute the awscli failure", vi.Err)
	}
	if vi.Version != "" {
		t.Errorf("version = %q, want empty on failure", vi.Version)
	}
}

// TestResolveDLAMIQueriesBothArchParams proves the dual-arch resolver asks
// both the x86_64 and the arm64 SSM parameter, never only the amd64 one.
func TestResolveDLAMIQueriesBothArchParams(t *testing.T) {
	binDir := t.TempDir()
	logFile := filepath.Join(t.TempDir(), "ssm.log")
	fakeAWS(t, binDir, "ami-07626c4fc6797c8e0", 0, "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806\t2026-08-06T12:00:00Z", 0)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("AWS_SSM_LOG", logFile)

	vi := DLAMIResolve(nil, 5*time.Second)(common.Dependency{Category: common.CategoryAMI, Name: "dlami", Version: "ami-0123456789abcdef0"})
	if vi.Err != nil {
		t.Fatalf("DLAMIResolve = %+v, want no error", vi)
	}
	log, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatalf("reading ssm log: %v", err)
	}
	queried := strings.Fields(string(log))
	if len(queried) != 2 || !slices.Contains(queried, dlamiSSMParam) || !slices.Contains(queried, dlamiSSMParamArm64) {
		t.Errorf("ssm log = %q, want exactly the %s and %s parameters queried", queried, dlamiSSMParam, dlamiSSMParamArm64)
	}
}

// TestResolveDLAMICurrentWhenPinMatchesArm64Latest proves the freshness
// semantics are arch-agnostic: an arm64-pinned id that equals the arm64
// latest is current even though it differs from the x86_64 latest, so the
// resolver reports the pin itself (and the classifier reports ok).
func TestResolveDLAMICurrentWhenPinMatchesArm64Latest(t *testing.T) {
	binDir := t.TempDir()
	const (
		x86Latest   = "ami-0e383fef63b2191d4"
		arm64Latest = "ami-0123456789abcdef0"
		describeOut = "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806\t2026-08-06T12:00:00Z"
	)
	fakeAWSArch(t, binDir, x86Latest, 0, arm64Latest, 0, describeOut, 0)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	vi := DLAMIResolve(nil, 5*time.Second)(common.Dependency{Category: common.CategoryAMI, Name: "dlami", Version: arm64Latest})
	if vi.Err != nil {
		t.Fatalf("DLAMIResolve = %+v, want no error", vi)
	}
	if vi.Version != arm64Latest {
		t.Errorf("Version = %q, want the pinned arm64 latest %q reported as current", vi.Version, arm64Latest)
	}
	if vi.Date != "2026-08-06T12:00:00Z" {
		t.Errorf("Date = %q, want the arm64 latest CreationDate paired with the reported version", vi.Date)
	}
	wantMeta := map[string]string{
		"current_name":         "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806",
		"current_created":      "2026-08-06T12:00:00Z",
		"latest_name":          "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806",
		"latest_created":       "2026-08-06T12:00:00Z",
		"latest_arm64_name":    "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806",
		"latest_arm64_created": "2026-08-06T12:00:00Z",
	}
	if !maps.Equal(vi.Metadata, wantMeta) {
		t.Errorf("Metadata = %v, want %v", vi.Metadata, wantMeta)
	}
}

// TestResolveDLAMIX86QueryFailureFallsBackToArm64 proves a single-arch SSM
// failure is tolerated: when the x86_64 query fails but the arm64 query
// resolves, the resolution succeeds with the arm64 id and notes the x86_64
// failure instead of going unknown.
func TestResolveDLAMIX86QueryFailureFallsBackToArm64(t *testing.T) {
	binDir := t.TempDir()
	const (
		arm64Latest = "ami-0123456789abcdef0"
		describeOut = "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806\t2026-08-06T12:00:00Z"
	)
	fakeAWSArch(t, binDir, "aws: error: AccessDenied", 255, arm64Latest, 0, describeOut, 0)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	vi := DLAMIResolve(nil, 5*time.Second)(common.Dependency{Category: common.CategoryAMI, Name: "dlami", Version: "ami-0e383fef63b2191d4"})
	if vi.Err != nil {
		t.Fatalf("DLAMIResolve = %+v, want no error despite x86_64 SSM failure", vi)
	}
	if vi.Version != arm64Latest {
		t.Errorf("Version = %q, want the arm64 latest %q as the reported latest", vi.Version, arm64Latest)
	}
	if !infoNotes(vi.Infos, "x86_64 SSM query failed") {
		t.Errorf("Infos = %v, want a note that the x86_64 SSM query failed", vi.Infos)
	}
	if vi.Date != "2026-08-06T12:00:00Z" {
		t.Errorf("Date = %q, want the arm64 latest CreationDate", vi.Date)
	}
	if _, ok := vi.Metadata["latest_name"]; ok {
		t.Errorf("Metadata = %v, want no latest_name when the x86_64 query failed", vi.Metadata)
	}
	if _, ok := vi.Metadata["latest_arm64_name"]; !ok {
		t.Errorf("Metadata = %v, want latest_arm64_name when the arm64 query succeeded", vi.Metadata)
	}
}

// TestResolveDLAMIarm64QueryFailureKeepsX86 proves the symmetric case: when
// the arm64 SSM query fails but the x86_64 query resolves, an amd64 pin that
// equals the x86_64 latest stays current and the arm64 failure is noted.
func TestResolveDLAMIarm64QueryFailureKeepsX86(t *testing.T) {
	binDir := t.TempDir()
	const (
		x86Latest   = "ami-0e383fef63b2191d4"
		describeOut = "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806\t2026-08-06T12:00:00Z"
	)
	fakeAWSArch(t, binDir, x86Latest, 0, "aws: error: AccessDenied", 255, describeOut, 0)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	vi := DLAMIResolve(nil, 5*time.Second)(common.Dependency{Category: common.CategoryAMI, Name: "dlami", Version: x86Latest})
	if vi.Err != nil {
		t.Fatalf("DLAMIResolve = %+v, want no error despite arm64 SSM failure", vi)
	}
	if vi.Version != x86Latest {
		t.Errorf("Version = %q, want the pinned x86_64 latest %q reported as current", vi.Version, x86Latest)
	}
	if !infoNotes(vi.Infos, "arm64 SSM query failed") {
		t.Errorf("Infos = %v, want a note that the arm64 SSM query failed", vi.Infos)
	}
	if vi.Date != "2026-08-06T12:00:00Z" {
		t.Errorf("Date = %q, want the x86_64 latest CreationDate", vi.Date)
	}
	if _, ok := vi.Metadata["latest_arm64_name"]; ok {
		t.Errorf("Metadata = %v, want no latest_arm64_name when the arm64 query failed", vi.Metadata)
	}
}

// infoNotes reports whether any informational note contains the substring.
func infoNotes(infos []string, want string) bool {
	for _, info := range infos {
		if strings.Contains(info, want) {
			return true
		}
	}
	return false
}
