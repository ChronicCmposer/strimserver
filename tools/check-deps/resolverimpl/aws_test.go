package resolverimpl

import (
	"maps"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"strimserver-check-deps/common"
)

// Phase 2 AWS DLAMI resolver unit tests. The pure parsers run against inline
// fixtures; the chain tests inject a fake `aws` shim via PATH (the same
// pattern resolvePNPM's tests use for corepack), so no real aws binary and no
// network are touched.

// fakeAWS writes an executable aws shim into dir that dispatches on the first
// subcommand: "ssm" prints ssmFixture and exits ssmExit; "ec2
// describe-images" prints describeFixture and exits describeExit. Any other
// invocation prints nothing and exits 255. Each test injects the fixture and
// exit for both subcommands so it controls the awscli SSM primary and the
// describe-images metadata independently (0 = success, nonzero = failure).
func fakeAWS(t *testing.T, dir, ssmFixture string, ssmExit int, describeFixture string, describeExit int) {
	t.Helper()
	script := "#!/bin/sh\n" +
		"case \"$1\" in\n" +
		"  ssm) printf '%s\\n' '" + ssmFixture + "'; exit " + strconv.Itoa(ssmExit) + " ;;\n" +
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
// describe-images metadata for both the current and the latest id is surfaced;
// the fetcher is never reached, so nil is safe here.
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
		"current_name":    "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806",
		"current_created": "2026-08-06T12:00:00Z",
		"latest_name":     "base-oss-nvidia-driver-gpu-amazon-linux-2023.1.20260806",
		"latest_created":  "2026-08-06T12:00:00Z",
	}
	if !maps.Equal(vi.Metadata, wantMeta) {
		t.Errorf("Metadata = %v, want %v", vi.Metadata, wantMeta)
	}
}

// TestResolveDLAMIMetadataFailureKeepsVersion proves describe-images failures
// are best-effort: when SSM resolves the latest id but both describe calls
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
