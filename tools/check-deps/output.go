package main

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"

	"strimserver-check-deps/common"
)

// This file owns the two renderings of the report: the deterministic JSON
// schema (a struct, not a map, so field order is stable across runs) and the
// tiered human-readable console report. All rendering is pure: it takes a
// report and returns bytes/string, so it is unit-testable without I/O.

// finding is one dependency in the JSON report. The struct field order is the
// JSON field order, chosen once so output is reproducible. Tier is the JSON
// schema's string form; the console renderer re-derives the typed tier from it
// via tier() below, so the enum is never duplicated on the record.
type finding struct {
	Category    string   `json:"category"`
	Name        string   `json:"name"`
	Current     string   `json:"current"`
	Wanted      string   `json:"wanted"`
	Latest      string   `json:"latest"`
	Tier        string   `json:"tier"`
	Source      string   `json:"source"`
	URL         string   `json:"url"`
	ReleaseDate string   `json:"releaseDate,omitempty"`
	Status      string   `json:"status"`
	Ignored     bool     `json:"ignored"`
	File        string   `json:"file,omitempty"`
	Reasons     []string `json:"reasons,omitempty"`
	Infos       []string `json:"infos,omitempty"`
}

// unknownEntry is one entry in the unknowns array. Phase 1 extraction
// failures carry File+Reason; resolved dependencies that came back "unknown"
// carry Name+File+Reason.
type unknownEntry struct {
	Name   string `json:"name,omitempty"`
	File   string `json:"file,omitempty"`
	Reason string `json:"reason"`
}

// counts summarizes the report. Tier and status counts are derived from the
// findings so the consumer never has to recompute them. The JSON keys are a
// deliberate, tested contract ("unknown" and "unknowns"), so they are pinned
// with explicit tags while the Go field names carry the fuller meaning.
type counts struct {
	Total  int `json:"total"`
	T1     int `json:"t1"`
	T2     int `json:"t2"`
	T3     int `json:"t3"`
	Update int `json:"update"`
	// StatusUnknown counts the dependencies whose status is unknown. It is
	// distinct from UnknownsTotal, which is the length of the unknowns array.
	StatusUnknown int `json:"unknown"`
	OK            int `json:"ok"`
	Hygiene       int `json:"hygiene"`
	Ignored       int `json:"ignored"`
	UnknownsTotal int `json:"unknowns"`
}

// report is the top-level JSON object.
type report struct {
	Findings []finding      `json:"findings"`
	Unknowns []unknownEntry `json:"unknowns"`
	Counts   counts         `json:"counts"`
}

// findingID is the canonical identity of a finding for ignore matching:
// category + "/" + name. It mirrors the id convention used in deps-ignore.json.
func findingID(dep common.Dependency) string {
	return dep.Category + "/" + dep.Name
}

// wantedFor returns the JSON "wanted" value: the latest version generally, and
// empty when the latest is unknown (nothing sensible to pin toward).
func wantedFor(r common.Resolved) string {
	if r.Status == common.StatusUnknown {
		return ""
	}
	return r.Latest
}

// bestURL derives the most useful upstream URL for a dependency. The Source
// field is a URL for most resolvers (github, PyPI, download pages); registry
// refs (docker.io/..., snapshot.debian.org) and the File path are not URLs, so
// they yield "".
func bestURL(dep common.Dependency) string {
	if strings.HasPrefix(dep.Source, "http://") || strings.HasPrefix(dep.Source, "https://") {
		return dep.Source
	}
	return ""
}

// toFinding converts a resolved record into the JSON finding shape.
func toFinding(r common.Resolved) finding {
	return finding{
		Category:    r.Dep.Category,
		Name:        r.Dep.Name,
		Current:     r.Dep.Version,
		Wanted:      wantedFor(r),
		Latest:      r.Latest,
		Tier:        r.Tier.String(),
		Source:      r.Dep.Source,
		URL:         bestURL(r.Dep),
		ReleaseDate: r.Date,
		Status:      string(r.Status),
		File:        r.Dep.File,
		Reasons:     slices.Clone(r.Reasons),
		Infos:       slices.Clone(r.Infos),
	}
}

// buildReport assembles the full JSON report from the resolved dependencies,
// the Phase 1 extraction unknowns, and the resolved "unknown" status records,
// then applies the ignore set and derives the counts. today is injected so the
// until-expiry logic is deterministic and testable. It makes a single pass over
// the resolved dependencies: each one yields its finding (with Ignored set),
// contributes its tier/status/ignored tallies, and contributes an unknowns
// entry when it resolved "unknown"; the calendar date is formatted once and
// threaded through isIgnoredOn so matching never re-formats it.
func buildReport(all []common.Resolved, unknowns []common.ExtractionUnknown, ignores parsedIgnoreSet, today time.Time) report {
	var rep report
	calToday := calendarDate(today)
	rep.Findings = make([]finding, 0, len(all))
	rep.Unknowns = make([]unknownEntry, 0, len(unknowns)+len(all))
	for _, r := range all {
		f := toFinding(r)
		f.Ignored = ignores.isIgnoredOn(findingID(r.Dep), calToday)
		rep.Findings = append(rep.Findings, f)
		accumulateCounts(&rep.Counts, r, f.Ignored)
		if u, ok := resolvedUnknownEntry(r); ok {
			rep.Unknowns = append(rep.Unknowns, u)
		}
	}
	for _, unk := range unknowns {
		rep.Unknowns = append(rep.Unknowns, unknownEntry{File: unk.File, Reason: unk.Reason})
	}
	rep.Counts.Total = len(all)
	sortFindings(rep.Findings)
	sortUnknowns(rep.Unknowns)
	rep.Counts.UnknownsTotal = len(rep.Unknowns)
	return rep
}

// accumulateCounts adds one resolved dependency's tier, status, and ignored
// contributions to the running counts. It counts directly from the typed
// enums: common.Tier.Normalized() rests any unrecognized tier at TierT3 (the
// explicit catch-all resting tier), and an unrecognized status contributes
// nothing to the status tallies rather than silently skewing one of the four
// known states.
func accumulateCounts(c *counts, r common.Resolved, ignored bool) {
	switch r.Tier.Normalized() {
	case common.TierT1:
		c.T1++
	case common.TierT2:
		c.T2++
	default:
		c.T3++ // the explicit catch-all resting tier
	}
	switch r.Status {
	case common.StatusUpdate:
		c.Update++
	case common.StatusUnknown:
		c.StatusUnknown++
	case common.StatusOK:
		c.OK++
	case common.StatusHygiene:
		c.Hygiene++
	default:
		// An unrecognized status is not one of the four known report states;
		// it is not counted so the tallies stay honest.
	}
	if ignored {
		c.Ignored++
	}
}

// resolvedUnknownEntry builds the unknowns-array entry for a resolved
// dependency that came back "unknown", reporting whether one applies.
func resolvedUnknownEntry(r common.Resolved) (unknownEntry, bool) {
	if r.Status != common.StatusUnknown {
		return unknownEntry{}, false
	}
	return unknownEntry{
		Name:   firstNonEmpty(r.Dep.Name, r.Dep.Category),
		File:   r.Dep.File,
		Reason: strings.Join(r.Reasons, "; "),
	}, true
}

// sortUnknowns orders unknowns deterministically by file, then name, then
// reason.
func sortUnknowns(unknowns []unknownEntry) {
	slices.SortFunc(unknowns, func(a, b unknownEntry) int {
		if a.File != b.File {
			return strings.Compare(a.File, b.File)
		}
		if a.Name != b.Name {
			return strings.Compare(a.Name, b.Name)
		}
		return strings.Compare(a.Reason, b.Reason)
	})
}

// firstNonEmpty returns a when it is non-empty, otherwise b.
func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// marshalReport serializes the report with a stable field order and
// deterministic indentation. Failures are surfaced so main can exit non-zero.
func marshalReport(rep report) ([]byte, error) {
	return json.MarshalIndent(rep, "", "  ")
}

// tier parses the JSON Tier string back into the typed enum for the console
// renderer. The JSON schema owns the string form (Tier); this is the single
// parse boundary where the console re-derives the enum, so bucketing never
// string-compares "T1"/"T2" directly. Unrecognized strings rest at TierT3,
// mirroring common.Tier.Normalized()'s catch-all fallback.
func (f finding) tier() common.Tier {
	switch f.Tier {
	case "T1":
		return common.TierT1
	case "T2":
		return common.TierT2
	default:
		return common.TierT3
	}
}

// renderConsole produces the tiered human-readable report. T1 and T2 findings
// are listed individually; T3 findings are collapsed into a count with a
// compact name list; unknowns are listed with reasons; ignored findings are
// collapsed.
func renderConsole(rep report, root string) string {
	var b strings.Builder
	b.WriteString("== strimserver check-deps ==\n")
	b.WriteString("repo root: " + root + "\n\n")

	var t1, t2, t3, ignored []finding
	for _, f := range rep.Findings {
		if f.Ignored {
			ignored = append(ignored, f)
			continue
		}
		switch f.tier() {
		case common.TierT1:
			t1 = append(t1, f)
		case common.TierT2:
			t2 = append(t2, f)
		default:
			t3 = append(t3, f)
		}
	}

	writeFindingSection(&b, "T1 (security)", t1)
	writeFindingSection(&b, "T2 (review)", t2)

	fmt.Fprintf(&b, "T3 (minor) — %d\n", len(t3))
	if len(t3) > 0 {
		b.WriteString("  names: " + joinNames(t3) + "\n")
	}

	fmt.Fprintf(&b, "\nUnknown — %d\n", len(rep.Unknowns))
	for _, unk := range rep.Unknowns {
		who := unk.Name
		if who == "" {
			who = unk.File
		}
		fmt.Fprintf(&b, "  - %s: %s\n", who, unk.Reason)
	}

	fmt.Fprintf(&b, "\nIgnored — %d\n", len(ignored))
	if len(ignored) > 0 {
		b.WriteString("  names: " + joinNames(ignored) + "\n")
	}

	return b.String()
}

// displayName returns the name to show for a finding, falling back to its
// category when the name is empty.
func displayName(f finding) string {
	return firstNonEmpty(f.Name, f.Category)
}

// writeFindingSection renders one tier's findings as individual lines.
func writeFindingSection(b *strings.Builder, title string, findings []finding) {
	fmt.Fprintf(b, "%s — %d\n", title, len(findings))
	for _, f := range findings {
		fmt.Fprintf(b, "  - %s", displayName(f))
		current := f.Current
		if current == "" {
			current = "(digest)"
		}
		latest := f.Latest
		if latest == "" {
			latest = "-"
		}
		fmt.Fprintf(b, "  %s -> %s", current, latest)
		if f.Source != "" {
			fmt.Fprintf(b, "  (%s)", f.Source)
		}
		if f.File != "" {
			fmt.Fprintf(b, "  [%s]", f.File)
		}
		fmt.Fprintf(b, "  [%s]", f.Status)
		if len(f.Reasons) > 0 {
			fmt.Fprintf(b, "  | %s", strings.Join(f.Reasons, " | "))
		}
		if len(f.Infos) > 0 {
			fmt.Fprintf(b, "  | %s", strings.Join(f.Infos, " | "))
		}
		fmt.Fprintf(b, "\n")
	}
	if len(findings) > 0 {
		b.WriteString("\n")
	}
}

// joinNames renders the compact comma-separated name list for a collapsed
// group, preserving the deterministic report order.
func joinNames(findings []finding) string {
	names := make([]string, 0, len(findings))
	for _, f := range findings {
		names = append(names, displayName(f))
	}
	return strings.Join(names, ", ")
}

// sortFindings orders findings deterministically (category, name, current) so
// both the console and JSON output are stable across runs.
func sortFindings(findings []finding) {
	slices.SortFunc(findings, func(a, b finding) int {
		if a.Category != b.Category {
			return strings.Compare(a.Category, b.Category)
		}
		if a.Name != b.Name {
			return strings.Compare(a.Name, b.Name)
		}
		return strings.Compare(a.Current, b.Current)
	})
}
