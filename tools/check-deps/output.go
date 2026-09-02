package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

// This file owns the two renderings of the report: the deterministic JSON
// schema (a struct, not a map, so field order is stable across runs) and the
// tiered human-readable console report. All rendering is pure: it takes a
// report and returns bytes/string, so it is unit-testable without I/O.

// finding is one dependency in the JSON report. The struct field order is the
// JSON field order, chosen once so output is reproducible.
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
// findings so the consumer never has to recompute them.
type counts struct {
	Total    int `json:"total"`
	T1       int `json:"t1"`
	T2       int `json:"t2"`
	T3       int `json:"t3"`
	Update   int `json:"update"`
	Unknown  int `json:"unknown"`
	OK       int `json:"ok"`
	Hygiene  int `json:"hygiene"`
	Ignored  int `json:"ignored"`
	Unknowns int `json:"unknowns"`
}

// report is the top-level JSON object.
type report struct {
	Findings []finding      `json:"findings"`
	Unknowns []unknownEntry `json:"unknowns"`
	Counts   counts         `json:"counts"`
}

// findingID is the canonical identity of a finding for ignore matching:
// category + "/" + name. It mirrors the id convention used in deps-ignore.json.
func findingID(dep dependency) string {
	return dep.Category + "/" + dep.Name
}

// wantedFor returns the JSON "wanted" value: the latest version generally, and
// empty when the latest is unknown (nothing sensible to pin toward).
func wantedFor(r resolved) string {
	if r.Status == statusUnknown {
		return ""
	}
	return r.Latest
}

// bestURL derives the most useful upstream URL for a dependency. The Source
// field is a URL for most resolvers (github, PyPI, download pages); registry
// refs (docker.io/..., snapshot.debian.org) and the File path are not URLs, so
// they yield "".
func bestURL(dep dependency) string {
	if strings.HasPrefix(dep.Source, "http://") || strings.HasPrefix(dep.Source, "https://") {
		return dep.Source
	}
	return ""
}

// toFinding converts a resolved record into the JSON finding shape.
func toFinding(r resolved) finding {
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
		Reasons:     append([]string(nil), r.Reasons...),
		Infos:       append([]string(nil), r.Infos...),
	}
}

// buildReport assembles the full JSON report from the resolved dependencies,
// the Phase 1 extraction unknowns, and the resolved "unknown" status records,
// then applies the ignore set and derives the counts. today is injected so the
// until-expiry logic is deterministic and testable.
func buildReport(all []resolved, unknowns []unknown, ignores ignoreSet, today time.Time) report {
	var rep report
	rep.Findings = make([]finding, 0, len(all))
	for _, r := range all {
		f := toFinding(r)
		f.Ignored = ignores.isIgnored(findingID(r.Dep), today)
		rep.Findings = append(rep.Findings, f)
		switch f.Tier {
		case "T1":
			rep.Counts.T1++
		case "T2":
			rep.Counts.T2++
		default:
			rep.Counts.T3++
		}
		switch f.Status {
		case "update":
			rep.Counts.Update++
		case "unknown":
			rep.Counts.Unknown++
		case "ok":
			rep.Counts.OK++
		case "hygiene":
			rep.Counts.Hygiene++
		}
		if f.Ignored {
			rep.Counts.Ignored++
		}
	}
	rep.Counts.Total = len(rep.Findings)
	sortFindings(rep.Findings)

	for _, unk := range unknowns {
		rep.Unknowns = append(rep.Unknowns, unknownEntry{File: unk.File, Reason: unk.Reason})
	}
	for _, r := range all {
		if r.Status == statusUnknown {
			rep.Unknowns = append(rep.Unknowns, unknownEntry{
				Name:   firstNonEmpty(r.Dep.Name, r.Dep.Category),
				File:   r.Dep.File,
				Reason: strings.Join(r.Reasons, "; "),
			})
		}
	}
	sort.Slice(rep.Unknowns, func(i, j int) bool {
		left, right := rep.Unknowns[i], rep.Unknowns[j]
		if left.File != right.File {
			return left.File < right.File
		}
		if left.Name != right.Name {
			return left.Name < right.Name
		}
		return left.Reason < right.Reason
	})
	rep.Counts.Unknowns = len(rep.Unknowns)
	return rep
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
		switch f.Tier {
		case "T1":
			t1 = append(t1, f)
		case "T2":
			t2 = append(t2, f)
		default:
			t3 = append(t3, f)
		}
	}

	writeFindingSection(&b, "T1 (security)", t1)
	writeFindingSection(&b, "T2 (review)", t2)

	b.WriteString(fmt.Sprintf("T3 (minor) — %d\n", len(t3)))
	if len(t3) > 0 {
		b.WriteString("  names: " + joinNames(t3) + "\n")
	}

	b.WriteString("\nUnknown — " + fmt.Sprint(len(rep.Unknowns)) + "\n")
	for _, unk := range rep.Unknowns {
		who := unk.Name
		if who == "" {
			who = unk.File
		}
		b.WriteString("  - " + who + ": " + unk.Reason + "\n")
	}

	b.WriteString("\nIgnored — " + fmt.Sprint(len(ignored)) + "\n")
	if len(ignored) > 0 {
		b.WriteString("  names: " + joinNames(ignored) + "\n")
	}

	return b.String()
}

// writeFindingSection renders one tier's findings as individual lines.
func writeFindingSection(b *strings.Builder, title string, findings []finding) {
	b.WriteString(fmt.Sprintf("%s — %d\n", title, len(findings)))
	for _, f := range findings {
		line := "  - " + f.Name
		if f.Name == "" {
			line = "  - " + f.Category
		}
		current := f.Current
		if current == "" {
			current = "(digest)"
		}
		latest := f.Latest
		if latest == "" {
			latest = "-"
		}
		line += fmt.Sprintf("  %s -> %s", current, latest)
		if f.Source != "" {
			line += "  (" + f.Source + ")"
		}
		if f.File != "" {
			line += "  [" + f.File + "]"
		}
		line += "  [" + f.Status + "]"
		if len(f.Reasons) > 0 {
			line += "  | " + strings.Join(f.Reasons, " | ")
		}
		if len(f.Infos) > 0 {
			line += "  | " + strings.Join(f.Infos, " | ")
		}
		b.WriteString(line + "\n")
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
		name := f.Name
		if name == "" {
			name = f.Category
		}
		names = append(names, name)
	}
	return strings.Join(names, ", ")
}

// sortFindings orders findings deterministically (category, name, current) so
// both the console and JSON output are stable across runs.
func sortFindings(findings []finding) {
	sort.Slice(findings, func(i, j int) bool {
		if findings[i].Category != findings[j].Category {
			return findings[i].Category < findings[j].Category
		}
		if findings[i].Name != findings[j].Name {
			return findings[i].Name < findings[j].Name
		}
		return findings[i].Current < findings[j].Current
	})
}
