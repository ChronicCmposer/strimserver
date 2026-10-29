// Package pins also contains the single-snapshot oracle for the FFmpeg image.
//
// Orchestrator decision D3 converges the prebuilt @ffmpeg_dist artifact and the
// runtime image onto one Debian snapshot. The same date (20261027) must appear
// in all five places that record it:
//
//  1. the MODULE.bazel s3_http_archive(name = "ffmpeg_dist", ...) artifact name
//  2. the MODULE.bazel apt.sources_list URI
//  3. the tools/ffmpeg-dist/build.sh DEBIAN_SNAPSHOT default
//  4. the tools/ffmpeg-dist/publish.sh DEBIAN_SNAPSHOT default
//  5. the date documented in README.md
//
// Each place is its own sub-test naming the file and the date it found, so a
// failure pinpoints the divergent file. It resolves the repository root the
// same way pins_test.go does: BUILD_WORKSPACE_DIRECTORY when set, else walk up
// until MODULE.bazel is found.
package pins

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// agreedSnapshotDate is the single Debian snapshot date every FFmpeg-related
// pin must record after decision D3. The eight-digit form matches both the
// artifact name (deb20261027) and the snapshot timestamps (20261027T000000Z).
const agreedSnapshotDate = "20261027"

// snapshotCheck is one location that records a Debian date.
type snapshotCheck struct {
	// name is the sub-test prefix; it names the file and its role.
	name string
	// file is the repository-relative path to inspect.
	file string
	// locate, when non-nil, narrows the search to the first match (for
	// example one archive block or one apt extension block).
	locate *regexp.Regexp
	// date captures the eight-digit Debian date in group 1.
	date *regexp.Regexp
	// describe is the human term used in errors, e.g. "the s3_key".
	describe string
}

// dates returns every distinct Debian date recorded by this check, or a
// descriptive error naming the file when the location or its date cannot be
// found. A place that records more than one distinct date is returned as-is so
// the caller can report the divergence.
func (c snapshotCheck) dates(content string) ([]string, error) {
	scoped := content
	if c.locate != nil {
		span := c.locate.FindStringIndex(content)
		if span == nil {
			return nil, fmt.Errorf("%s: %s: cannot find %s", c.name, c.file, c.describe)
		}
		scoped = content[span[0]:span[1]]
	}

	matches := c.date.FindAllStringSubmatch(scoped, -1)
	if len(matches) == 0 {
		return nil, fmt.Errorf("%s: %s: cannot find a Debian date in %s", c.name, c.file, c.describe)
	}

	seen := make(map[string]bool, len(matches))
	found := make([]string, 0, len(matches))
	for _, match := range matches {
		date := match[1]
		if seen[date] {
			continue
		}
		seen[date] = true
		found = append(found, date)
	}
	sort.Strings(found)
	return found, nil
}

// snapshotChecks is the full one-snapshot contract: all five places must record
// agreedSnapshotDate.
var snapshotChecks = []snapshotCheck{
	{
		name:     "module-bazel-ffmpeg-dist-artifact",
		file:     "MODULE.bazel",
		locate:   regexp.MustCompile(`(?s)s3_http_archive\(\s*name = "ffmpeg_dist",.*?\n\)`),
		date:     regexp.MustCompile(`deb(\d{8})-`),
		describe: `the s3_http_archive(name = "ffmpeg_dist", ...) artifact name`,
	},
	{
		name:     "module-bazel-apt-sources-list",
		file:     "MODULE.bazel",
		locate:   regexp.MustCompile(`(?s)apt\.sources_list\(.*?\n\)`),
		date:     regexp.MustCompile(`snapshot\.debian\.org/archive/debian/(\d{8})T\d{6}Z`),
		describe: "the apt.sources_list uris snapshot",
	},
	{
		name:     "tools-ffmpeg-dist-build-sh",
		file:     "tools/ffmpeg-dist/build.sh",
		date:     regexp.MustCompile(`DEBIAN_SNAPSHOT:=(\d{8})T\d{6}Z`),
		describe: "the DEBIAN_SNAPSHOT:= default",
	},
	{
		name:     "tools-ffmpeg-dist-publish-sh",
		file:     "tools/ffmpeg-dist/publish.sh",
		date:     regexp.MustCompile(`DEBIAN_SNAPSHOT:-(\d{8})T\d{6}Z\}`),
		describe: "the DEBIAN_SNAPSHOT:- default",
	},
	{
		// README documents the date in several forms (artifact file name,
		// snapshot timestamp, base-image tag), so every eight-digit date it
		// mentions must be the agreed one.
		name:     "readme-documented-snapshot",
		file:     "README.md",
		date:     regexp.MustCompile(`(\d{8})`),
		describe: "the documented Debian snapshot",
	},
}

// TestFFmpegDistCoherence enforces the single-snapshot contract. Each place is
// its own sub-test so a failure names the divergent file and the date it found.
func TestFFmpegDistCoherence(t *testing.T) {
	root, err := repoRoot()
	if err != nil {
		t.Fatalf("resolve repository root: %v", err)
	}

	// Read each distinct file once; checks on the same file share content.
	cache := map[string]string{}
	for _, check := range snapshotChecks {
		check := check
		content, readErr := readWorkspaceFile(root, check.file, cache)
		var found []string
		if readErr == nil {
			found, readErr = check.dates(content)
		}
		t.Run(check.name+"-"+dateOrMissing(found), func(t *testing.T) {
			if readErr != nil {
				t.Fatalf("%s", readErr)
			}
			if len(found) == 1 && found[0] == agreedSnapshotDate {
				return
			}
			t.Errorf(
				"%s: %s records Debian date(s) %s in %s, but the agreed snapshot is %s; update this place so all five agree",
				check.name, check.file, strings.Join(found, ", "), check.describe, agreedSnapshotDate,
			)
		})
	}
}

// readWorkspaceFile reads rel under root, caching the content per file.
func readWorkspaceFile(root, rel string, cache map[string]string) (string, error) {
	if content, ok := cache[rel]; ok {
		return content, nil
	}
	raw, err := os.ReadFile(filepath.Join(root, rel))
	if err != nil {
		return "", fmt.Errorf("cannot read %s: %w", rel, err)
	}
	cache[rel] = string(raw)
	return cache[rel], nil
}

// dateOrMissing keeps sub-test names stable when a location has no date.
func dateOrMissing(dates []string) string {
	if len(dates) == 0 {
		return "missing"
	}
	return strings.Join(dates, "-")
}
