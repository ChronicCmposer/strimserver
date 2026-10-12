package main

import (
	"encoding/json"
	"fmt"
	"maps"
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
// JSON field order, chosen once so output is reproducible. The unexported tier
// field carries the typed enum for the console renderer (never serialized, no
// json tag).
type finding struct {
	Category    string            `json:"category"`
	Name        string            `json:"name"`
	Current     string            `json:"current"`
	Wanted      string            `json:"wanted"`
	Latest      string            `json:"latest"`
	Tier        string            `json:"tier"`
	Source      string            `json:"source"`
	URL         string            `json:"url"`
	ReleaseDate string            `json:"releaseDate,omitempty"`
	Status      string            `json:"status"`
	Ignored     bool              `json:"ignored"`
	File        string            `json:"file,omitempty"`
	Pins        []pinEntry        `json:"pins,omitempty"`
	Reasons     []string          `json:"reasons,omitempty"`
	Infos       []string          `json:"infos,omitempty"`
	Metadata    map[string]string `json:"metadata,omitempty"`

	tier common.Tier
}

// pinEntry is one file's declaration of a logical dependency: the repo-relative
// file and the version pinned there. A logical dependency declared in several
// files (or as per-architecture twins) carries one pinEntry per declaration, so
// multi-file and mixed-version drift stays visible in the collapsed finding.
type pinEntry struct {
	File    string `json:"file"`
	Version string `json:"version"`
}

// unknownEntry is one entry in the unknowns array. Phase 1 extraction
// failures carry File+Reason; resolved dependencies that came back "unknown"
// carry Name+File+Reason. Ignored records that a live deps-ignore.json rule
// covers: they stay listed (the honest record) but are marked so a reviewer
// sees which unknowns are reviewed exceptions rather than open questions.
type unknownEntry struct {
	Name    string `json:"name,omitempty"`
	File    string `json:"file,omitempty"`
	Reason  string `json:"reason"`
	Ignored bool   `json:"ignored"`
}

// counts summarizes the report. The JSON keys are a deliberate, tested
// contract ("unknown" and "unknowns"), so they are pinned with explicit tags
// while the Go field names carry the fuller meaning.
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
	// Inventory and Integrity count the inventory and integrity section sizes.
	// They are the per-section totals and are disjoint from the T1/T2/T3
	// tallies: a sectioned dependency is never a finding and never carries a
	// review tier. Total is the number of report entries, so it equals the sum
	// of the tier tallies plus these two sections. Pins of one logical
	// dependency collapse into a single finding, so Total counts logical
	// dependencies rather than physical pins.
	Inventory int `json:"inventory"`
	Integrity int `json:"integrity"`
	// Skipped counts the dependencies whose resolution was deliberately not
	// attempted (a StatusSkipped finding, e.g. a network-backed resolver left
	// unrun by --offline). It completes the status tallies alongside
	// Update/StatusUnknown/OK/Hygiene, so summing them covers every finding
	// rather than silently dropping the skipped ones. It is appended last so
	// the existing keys and their meanings are unchanged.
	Skipped int `json:"skipped"`
}

// reportSchemaVersion is the current JSON report schema version. It is bumped
// whenever the report shape changes incompatibly, so machine consumers can
// branch on it.
const reportSchemaVersion = "2"

// inventoryNote is the extractor tag that marks a lockfile-transitive pin: a
// dependency a lockfile records only transitively, not as a top-level reviewed
// pin. It mirrors the extractors' `inventoryNote` constant; matching by content
// keeps output decoupled from the extractor package.
const inventoryNote = "inventory:transitive"

// inventoryEntry is one row in the report's inventory section: a lockfile
// transitive pin recorded for completeness but not reviewed (it has no
// top-level upstream version to compare). Current carries the locked version.
type inventoryEntry struct {
	Category string `json:"category"`
	Name     string `json:"name"`
	Current  string `json:"current"`
	File     string `json:"file,omitempty"`
	Source   string `json:"source,omitempty"`
	Note     string `json:"note,omitempty"`
}

// integrityEntry is one row in the report's integrity section: a pin whose
// identity is an integrity hash (SRI/sha256) rather than a version to compare.
// Current carries the pinned hash.
type integrityEntry struct {
	Category string `json:"category"`
	Name     string `json:"name"`
	Current  string `json:"current"`
	File     string `json:"file,omitempty"`
	Source   string `json:"source,omitempty"`
	Note     string `json:"note,omitempty"`
}

// reportSection identifies which report array a resolved dependency belongs to.
type reportSection int

const (
	// sectionFinding is a reviewable dependency: it appears in findings and
	// carries a review tier.
	sectionFinding reportSection = iota
	// sectionInventory is a lockfile-transitive pin recorded for completeness.
	sectionInventory
	// sectionIntegrity is an integrity-hash pin with no version to compare.
	sectionIntegrity
)

// sectionFor routes a resolved dependency to its report section. Integrity pins
// (by role or by the classifier's integrity status) win first, then
// lockfile-transitive inventory pins, then everything else is a finding. The
// order is deliberate: a pin that is both an integrity pin and inventory-tagged
// is reported as integrity, the stronger classification.
func sectionFor(r common.Resolved) reportSection {
	if r.Dep.IsIntegrity() || r.Status == common.StatusIntegrity {
		return sectionIntegrity
	}
	if strings.Contains(r.Dep.Note, inventoryNote) {
		return sectionInventory
	}
	return sectionFinding
}

type report struct {
	SchemaVersion string           `json:"schemaVersion"`
	Findings      []finding        `json:"findings"`
	Unknowns      []unknownEntry   `json:"unknowns"`
	Inventory     []inventoryEntry `json:"inventory"`
	Integrity     []integrityEntry `json:"integrity"`
	Counts        counts           `json:"counts"`
}

// newReport returns the empty report envelope: the current schema version and
// non-nil (empty) findings/unknowns/inventory/integrity arrays, so the
// marshalled JSON always carries arrays rather than null.
func newReport() report {
	return report{
		SchemaVersion: reportSchemaVersion,
		Findings:      []finding{},
		Unknowns:      []unknownEntry{},
		Inventory:     []inventoryEntry{},
		Integrity:     []integrityEntry{},
	}
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

// toFinding converts a resolved record into the JSON finding shape. The wire
// Tier is the string form; the unexported tier field carries the normalized
// typed enum so the console renderer buckets exactly as the record's tier
// does (Normalized() rests unrecognized tiers at T3).
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
		Metadata:    maps.Clone(r.Metadata),
		tier:        r.Tier.Normalized(),
	}
}

// buildReport assembles the full JSON report from the resolved dependencies,
// the Phase 1 extraction unknowns, and the resolved "unknown" status records,
// then applies the ignore set and derives the counts. today is injected so the
// until-expiry logic is deterministic and testable. The calendar date is
// formatted once and threaded through isIgnoredOn so matching never re-formats
// it. includeOK decides whether ok (current) findings appear in the findings
// list: false filters them out while counts still cover the full inventory;
// true lists every dependency.
func buildReport(all []common.Resolved, unknowns []common.ExtractionUnknown, ignores parsedIgnoreSet, today time.Time, includeOK bool) report {
	rep := newReport()
	calToday := calendarDate(today)
	rep.Findings = make([]finding, 0, len(all))
	rep.Unknowns = make([]unknownEntry, 0, len(unknowns)+len(all))

	// Route each resolved dependency into its section. Inventory and integrity
	// entries never become findings and never reach the unknowns list: they are
	// recorded in their own section instead of surfacing as "unknown" noise.
	var findings []finding
	for _, r := range all {
		f := toFinding(r)
		f.Ignored = ignores.isIgnoredOn(findingID(r.Dep), r.Dep.File, calToday)
		switch sectionFor(r) {
		case sectionIntegrity:
			rep.Integrity = append(rep.Integrity, toIntegrityEntry(r))
		case sectionInventory:
			rep.Inventory = append(rep.Inventory, toInventoryEntry(r))
		default:
			findings = append(findings, f)
			if u, ok := resolvedUnknownEntry(r, f.Ignored); ok {
				rep.Unknowns = append(rep.Unknowns, u)
			}
		}
	}

	// Collapse pins of one logical dependency (arch twins, multi-file) into a
	// single finding, then count the logical findings so the tier tallies always
	// agree with the findings list.
	findings = collapseFindings(findings)
	for _, f := range findings {
		accumulateFindingCounts(&rep.Counts, f)
		if f.Status != string(common.StatusOK) || includeOK {
			rep.Findings = append(rep.Findings, f)
		}
	}
	for _, unk := range unknowns {
		rep.Unknowns = append(rep.Unknowns, unknownEntry{
			File:    unk.File,
			Reason:  unk.Reason,
			Ignored: ignores.coversFile(unk.File, calToday),
		})
	}

	rep.Counts.Inventory = len(rep.Inventory)
	rep.Counts.Integrity = len(rep.Integrity)
	rep.Counts.Total = len(findings) + rep.Counts.Inventory + rep.Counts.Integrity
	sortFindings(rep.Findings)
	sortInventory(rep.Inventory)
	sortIntegrity(rep.Integrity)
	sortUnknowns(rep.Unknowns)
	rep.Counts.UnknownsTotal = len(rep.Unknowns)
	return rep
}

// accumulateFindingCounts adds one finding's tier, status, and ignored
// contributions to the running counts. common.Tier.Normalized() rests any
// unrecognized tier at TierT3 (the explicit catch-all resting tier), and an
// unrecognized status contributes nothing to the status tallies. It is called
// once per logical finding, so a collapsed multi-file dependency is counted
// once.
func accumulateFindingCounts(c *counts, f finding) {
	switch f.tier.Normalized() {
	case common.TierT1:
		c.T1++
	case common.TierT2:
		c.T2++
	default:
		c.T3++
	}
	switch common.Status(f.Status) {
	case common.StatusUpdate:
		c.Update++
	case common.StatusUnknown:
		c.StatusUnknown++
	case common.StatusOK:
		c.OK++
	case common.StatusHygiene:
		c.Hygiene++
	case common.StatusSkipped:
		c.Skipped++
	default:
		// An unrecognized status is not counted so the tallies stay honest.
	}
	if f.Ignored {
		c.Ignored++
	}
}

// toInventoryEntry converts a lockfile-transitive resolved dependency into the
// inventory section row.
func toInventoryEntry(r common.Resolved) inventoryEntry {
	return inventoryEntry{
		Category: r.Dep.Category,
		Name:     r.Dep.Name,
		Current:  r.Dep.Version,
		File:     r.Dep.File,
		Source:   r.Dep.Source,
		Note:     r.Dep.Note,
	}
}

// toIntegrityEntry converts an integrity-hash resolved dependency into the
// integrity section row. Current carries the pinned hash.
func toIntegrityEntry(r common.Resolved) integrityEntry {
	return integrityEntry{
		Category: r.Dep.Category,
		Name:     r.Dep.Name,
		Current:  r.Dep.Version,
		File:     r.Dep.File,
		Source:   r.Dep.Source,
		Note:     r.Dep.Note,
	}
}

// collapseFindings folds findings that describe the same logical dependency
// into one finding, keyed by category and architecture-normalized name. A group
// of one is returned unchanged (so single pins keep their exact name and shape);
// a group of two or more merges into one finding carrying every pin, so arch
// twins and multi-file declarations stop being reported as duplicates while
// their drift stays visible.
func collapseFindings(findings []finding) []finding {
	groups := make(map[logicalKey][]finding)
	order := make([]logicalKey, 0, len(findings))
	for _, f := range findings {
		key := logicalKey{category: f.Category, name: trimArchSuffix(f.Name)}
		if _, seen := groups[key]; !seen {
			order = append(order, key)
		}
		groups[key] = append(groups[key], f)
	}

	collapsed := make([]finding, 0, len(order))
	for _, key := range order {
		members := groups[key]
		if len(members) == 1 {
			collapsed = append(collapsed, members[0])
			continue
		}
		collapsed = append(collapsed, mergeFindings(key, members))
	}
	return collapsed
}

// logicalKey is the identity of a logical dependency for collapse: its category
// and its architecture-normalized name.
type logicalKey struct {
	category string
	name     string
}

// mergeFindings merges several pins of one logical dependency into a single
// finding. It takes the most severe member as the representative (so no
// actionable twin is hidden), rests the tier at the most severe member's tier,
// records every pin, and marks multi-file version/arch drift in metadata.
func mergeFindings(key logicalKey, members []finding) finding {
	merged := mostSevere(members)
	merged.Name = key.name
	merged.Pins = collectPins(members)
	merged.tier = minTier(members)
	merged.Tier = merged.tier.String()
	merged.Ignored = allIgnored(members)
	merged.Metadata = mergeMetadata(merged.Metadata, members)
	return merged
}

// mostSevere returns the member whose status (then tier, then file) is the most
// actionable, so the collapsed finding surfaces the worst case. Ordering is
// total and deterministic.
func mostSevere(members []finding) finding {
	best := members[0]
	for _, m := range members[1:] {
		if moreSevere(m, best) {
			best = m
		}
	}
	return best
}

// moreSevere reports whether a outranks b: a more severe status wins first,
// then a lower (more severe) tier, then the lexicographically smaller file.
func moreSevere(a, b finding) bool {
	if statusRank(a.Status) != statusRank(b.Status) {
		return statusRank(a.Status) < statusRank(b.Status)
	}
	at, bt := a.tier.Normalized(), b.tier.Normalized()
	if at != bt {
		return at < bt
	}
	return a.File < b.File
}

// statusRank orders statuses by review severity; a lower rank is more severe. An
// unrecognized status rests at the least severe rank.
func statusRank(status string) int {
	switch common.Status(status) {
	case common.StatusUpdate:
		return 0
	case common.StatusUnknown:
		return 1
	case common.StatusHygiene:
		return 2
	case common.StatusIntegrity:
		return 3
	case common.StatusSkipped:
		return 4
	case common.StatusOK:
		return 5
	default:
		return 6
	}
}

// minTier returns the most severe (numerically lowest) normalized tier across
// the members.
func minTier(members []finding) common.Tier {
	t := members[0].tier.Normalized()
	for _, m := range members[1:] {
		if n := m.tier.Normalized(); n < t {
			t = n
		}
	}
	return t
}

// allIgnored reports whether every member is ignored, so a collapsed finding is
// hidden only when all of its pins are intentionally ignored.
func allIgnored(members []finding) bool {
	for _, m := range members {
		if !m.Ignored {
			return false
		}
	}
	return true
}

// collectPins returns the distinct (file, version) declarations across the
// members, sorted by file then version, so every pin and any version drift is
// visible.
func collectPins(members []finding) []pinEntry {
	seen := make(map[pinEntry]struct{}, len(members))
	pins := make([]pinEntry, 0, len(members))
	for _, m := range members {
		p := pinEntry{File: m.File, Version: m.Current}
		if _, duplicate := seen[p]; duplicate {
			continue
		}
		seen[p] = struct{}{}
		pins = append(pins, p)
	}
	slices.SortFunc(pins, func(a, b pinEntry) int {
		if a.File != b.File {
			return strings.Compare(a.File, b.File)
		}
		return strings.Compare(a.Version, b.Version)
	})
	return pins
}

// mergeMetadata copies the representative metadata and records the drift kinds
// the collapse exposed: mixed-version when the pins disagree on version,
// mixed-arch when the members span more than one architecture.
func mergeMetadata(base map[string]string, members []finding) map[string]string {
	md := maps.Clone(base)
	var drift []string
	if mixedVersion(members) {
		drift = append(drift, "mixed-version")
	}
	if mixedArch(members) {
		drift = append(drift, "mixed-arch")
	}
	if len(drift) == 0 {
		return md
	}
	if md == nil {
		md = map[string]string{}
	}
	slices.Sort(drift)
	md["drift"] = strings.Join(drift, ",")
	return md
}

// mixedVersion reports whether the members disagree on the pinned current
// version.
func mixedVersion(members []finding) bool {
	for _, m := range members[1:] {
		if m.Current != members[0].Current {
			return true
		}
	}
	return false
}

// mixedArch reports whether the members span more than one architecture label
// (including the architecture-independent empty label).
func mixedArch(members []finding) bool {
	arches := make(map[string]struct{}, len(members))
	for _, m := range members {
		arches[archLabel(m.Name)] = struct{}{}
	}
	return len(arches) > 1
}

// resolvedUnknownEntry builds the unknowns-array entry for a resolved
// dependency that came back "unknown", reporting whether one applies. ignored
// carries the finding's ignore verdict so the unknowns array agrees with the
// findings list about which unknowns are reviewed exceptions.
func resolvedUnknownEntry(r common.Resolved, ignored bool) (unknownEntry, bool) {
	if r.Status != common.StatusUnknown {
		return unknownEntry{}, false
	}
	return unknownEntry{
		Name:    firstNonEmpty(r.Dep.Name, r.Dep.Category),
		File:    r.Dep.File,
		Reason:  strings.Join(r.Reasons, "; "),
		Ignored: ignored,
	}, true
}

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

// sortInventory orders the inventory rows deterministically (category, name,
// file, current) so the JSON is reproducible.
func sortInventory(entries []inventoryEntry) {
	slices.SortFunc(entries, func(a, b inventoryEntry) int {
		if a.Category != b.Category {
			return strings.Compare(a.Category, b.Category)
		}
		if a.Name != b.Name {
			return strings.Compare(a.Name, b.Name)
		}
		if a.File != b.File {
			return strings.Compare(a.File, b.File)
		}
		return strings.Compare(a.Current, b.Current)
	})
}

// sortIntegrity orders the integrity rows deterministically (category, name,
// file, current) so the JSON is reproducible.
func sortIntegrity(entries []integrityEntry) {
	slices.SortFunc(entries, func(a, b integrityEntry) int {
		if a.Category != b.Category {
			return strings.Compare(a.Category, b.Category)
		}
		if a.Name != b.Name {
			return strings.Compare(a.Name, b.Name)
		}
		if a.File != b.File {
			return strings.Compare(a.File, b.File)
		}
		return strings.Compare(a.Current, b.Current)
	})
}

// archLabel returns the architecture token a pin name carries, or "" for an
// architecture-independent name. It is the inverse view of trimArchSuffix, so
// the collapse and the resolver matcher agree on what counts as an arch suffix.
func archLabel(name string) string {
	base := trimArchSuffix(name)
	if base == name {
		return ""
	}
	return strings.TrimLeft(strings.TrimPrefix(name, base), "_-")
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// marshalReport serializes the report with a stable field order and no
// indentation, so the JSON document is a single compact line (terse for
// machine and LLM consumers).
func marshalReport(rep report) ([]byte, error) {
	return json.Marshal(rep)
}

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
		switch f.tier {
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

	writeIntegritySection(&b, rep.Integrity)
	writeInventorySection(&b, rep.Inventory)

	fmt.Fprintf(&b, "\nUnknown — %d\n", len(rep.Unknowns))
	for _, unk := range rep.Unknowns {
		who := unk.Name
		if who == "" {
			who = unk.File
		}
		marker := ""
		if unk.Ignored {
			marker = " [ignored]"
		}
		fmt.Fprintf(&b, "  - %s: %s%s\n", who, unk.Reason, marker)
	}

	fmt.Fprintf(&b, "\nIgnored — %d\n", len(ignored))
	if len(ignored) > 0 {
		b.WriteString("  names: " + joinNames(ignored) + "\n")
	}

	return b.String()
}

func displayName(f finding) string {
	return firstNonEmpty(f.Name, f.Category)
}

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
		if len(f.Pins) > 0 {
			fmt.Fprintf(b, "  pins: %s", formatPins(f.Pins))
		}
		fmt.Fprintf(b, "  [%s]", f.Status)
		if len(f.Reasons) > 0 {
			fmt.Fprintf(b, "  | %s", strings.Join(f.Reasons, " | "))
		}
		if len(f.Infos) > 0 {
			fmt.Fprintf(b, "  | %s", strings.Join(f.Infos, " | "))
		}
		if len(f.Metadata) > 0 {
			keys := slices.Collect(maps.Keys(f.Metadata))
			slices.Sort(keys)
			pairs := make([]string, 0, len(keys))
			for _, k := range keys {
				pairs = append(pairs, k+"="+f.Metadata[k])
			}
			fmt.Fprintf(b, "  | metadata: %s", strings.Join(pairs, " | "))
		}
		fmt.Fprintf(b, "\n")
	}
	if len(findings) > 0 {
		b.WriteString("\n")
	}
}

func joinNames(findings []finding) string {
	names := make([]string, 0, len(findings))
	for _, f := range findings {
		names = append(names, displayName(f))
	}
	return strings.Join(names, ", ")
}

// formatPins renders a finding's pins as "file@version" pairs joined by ", ",
// so a collapsed multi-file finding shows every declaration on its line.
func formatPins(pins []pinEntry) string {
	parts := make([]string, 0, len(pins))
	for _, p := range pins {
		parts = append(parts, p.File+"@"+p.Version)
	}
	return strings.Join(parts, ", ")
}

// writeIntegritySection renders the integrity (hash-pin) section flat: one line
// per pin with its hash, optional source, and file. It always prints the
// heading (matching the Unknown/Ignored sections) so an empty section is
// explicit rather than absent.
func writeIntegritySection(b *strings.Builder, entries []integrityEntry) {
	fmt.Fprintf(b, "\nIntegrity (hash pins) — %d\n", len(entries))
	for _, e := range entries {
		fmt.Fprintf(b, "  - %s", firstNonEmpty(e.Name, e.Category))
		if e.Current != "" {
			fmt.Fprintf(b, "  %s", e.Current)
		}
		if e.Source != "" {
			fmt.Fprintf(b, "  (%s)", e.Source)
		}
		if e.File != "" {
			fmt.Fprintf(b, "  [%s]", e.File)
		}
		fmt.Fprintf(b, "\n")
	}
}

// writeInventorySection renders the inventory (lockfile-transitive) section
// flat: one line per pin with its locked version and file. It always prints the
// heading so an empty section is explicit rather than absent.
func writeInventorySection(b *strings.Builder, entries []inventoryEntry) {
	fmt.Fprintf(b, "\nInventory (transitive) — %d\n", len(entries))
	for _, e := range entries {
		fmt.Fprintf(b, "  - %s", firstNonEmpty(e.Name, e.Category))
		if e.Current != "" {
			fmt.Fprintf(b, "  %s", e.Current)
		}
		if e.File != "" {
			fmt.Fprintf(b, "  [%s]", e.File)
		}
		fmt.Fprintf(b, "\n")
	}
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
