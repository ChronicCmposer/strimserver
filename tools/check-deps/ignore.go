package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// This file owns deps-ignore.json: the checked-in, git-tracked list of
// intentional pins (e.g. @rollup/rollup-linux-arm64-gnu or the Debian
// reproducibility snapshot) that a plain run reports as updates but a reviewer
// has decided to tolerate. Each rule is a pure predicate over (id, file, today),
// so matching is unit-testable. The until date is validated exactly once, when
// the file is parsed, so matching never re-parses it per rule.

// ignoreRule is one entry in deps-ignore.json. id identifies the dependency
// (category + "/" + name, e.g. "npm/@rollup/rollup-linux-arm64-gnu"); file
// optionally scopes the rule to one repo-relative source file (empty matches
// any file); reason is the human justification; until optionally expires the
// rule (YYYY-MM-DD).
type ignoreRule struct {
	ID     string `json:"id"`
	File   string `json:"file,omitempty"`
	Reason string `json:"reason"`
	Until  string `json:"until,omitempty"`
}

type ignoreSet []ignoreRule

// ignoredRule is the load-time parsed form of an ignoreRule: the until date is
// validated once when the set is parsed, so matching never re-parses it.
// file holds the optional source-file scope (empty matches any file);
// untilStr holds the validated original YYYY-MM-DD string (empty when the rule
// has no expiry, i.e. it never expires); malformedUntil marks a rule whose
// until could not be parsed, failing it closed (treated as already expired) so
// it never matches; emptyReason marks a rule with a blank justification, which
// is not a reviewed exception and therefore never matches (fail closed).
type ignoredRule struct {
	ID             string
	File           string
	Reason         string
	untilStr       string
	malformedUntil bool
	emptyReason    bool
}

// parsedIgnoreSet is the ordered collection of parsed ignore rules. It is the
// trusted form matching operates on; the raw JSON shape exists only at the
// parse boundary.
type parsedIgnoreSet []ignoredRule

func (s ignoreSet) parsed() parsedIgnoreSet {
	out := make(parsedIgnoreSet, 0, len(s))
	for _, rule := range s {
		pr := ignoredRule{ID: rule.ID, Reason: rule.Reason, File: rule.File}
		pr.emptyReason = strings.TrimSpace(rule.Reason) == ""
		if rule.Until != "" {
			if _, err := time.Parse(dateLayout, rule.Until); err != nil {
				pr.malformedUntil = true
			} else {
				pr.untilStr = rule.Until
			}
		}
		out = append(out, pr)
	}
	return out
}

const ignoreFileName = "deps-ignore.json"

// dateLayout is the YYYY-MM-DD calendar-date layout. Both the ignore until
// dates are parsed in it and the report date is formatted in it, so the layout
// string is defined exactly once.
const dateLayout = "2006-01-02"

func calendarDate(t time.Time) string {
	return t.Format(dateLayout)
}

// parseIgnore decodes a deps-ignore.json body into the parsed matching form.
func parseIgnore(data []byte) (parsedIgnoreSet, error) {
	var raw ignoreSet
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	return raw.parsed(), nil
}

// loadIgnore reads deps-ignore.json at the repo root. A missing, unreadable,
// or malformed file yields an empty non-nil set (never a crash or a nil): a
// plain run simply applies no ignores, and malformed JSON additionally warns
// loudly so the failure is never silent.
func loadIgnore(root string, warn func(string, ...any)) parsedIgnoreSet {
	path := filepath.Join(root, ignoreFileName)
	data, err := os.ReadFile(path)
	if err != nil {
		return parsedIgnoreSet{}
	}
	rules, err := parseIgnore(data)
	if err != nil {
		warn("ignoring malformed %s: %v", ignoreFileName, err)
		return parsedIgnoreSet{}
	}
	warnInvalidIgnoreRules(rules, warn)
	return rules
}

// warnInvalidIgnoreRules reports every rule the matcher will refuse to honor
// (an empty reason or an unparseable until), so a hand-edited deps-ignore.json
// that forgot a justification or mistyped a date is never silently ignored.
func warnInvalidIgnoreRules(rules parsedIgnoreSet, warn func(string, ...any)) {
	for _, rule := range rules {
		switch {
		case rule.emptyReason:
			warn("deps-ignore.json rule %q has an empty reason; it is not honored", rule.ID)
		case rule.malformedUntil:
			warn("deps-ignore.json rule %q has a malformed until; it is not honored", rule.ID)
		}
	}
}

// isIgnored reports whether id matches any non-expired rule as of today,
// unconstrained by source file (the empty file matches any file). It formats
// the calendar date once and delegates to isIgnoredOn, so the public entry
// point keeps the time.Time signature while the report pass reuses the
// preformatted date.
func (s parsedIgnoreSet) isIgnored(id string, today time.Time) bool {
	return s.isIgnoredOn(id, "", calendarDate(today))
}

// isIgnoredOn reports whether id matches any non-expired rule on the given
// calendar date (YYYY-MM-DD). A rule with a file scope matches only a finding
// whose source file equals that scope; a rule with an empty file matches any
// file. A rule applies on and before its until date; it is expired once the
// calendar date is strictly after until. Rules without an until never expire,
// and rules whose until failed to parse at load are already expired (fail
// closed). The calendar date is what the expiry rule compares against, not the
// time-of-day, so a rule still applies on its until date regardless of the
// time carried by today. The caller (or isIgnored) preformats the date once,
// so matching many ids during a single report pass never re-formats it.
func (s parsedIgnoreSet) isIgnoredOn(id, file, calToday string) bool {
	for _, rule := range s {
		if rule.ID != id {
			continue
		}
		if rule.File != "" && rule.File != file {
			continue
		}
		if rule.malformedUntil {
			// Fail closed: a malformed until date must never silently pin the
			// dependency forever, so treat the rule as expired.
			continue
		}
		if rule.emptyReason {
			// Fail closed: a rule with no justification is not a reviewed
			// exception, so it never pins anything.
			continue
		}
		if rule.untilStr != "" && calToday > rule.untilStr {
			continue
		}
		return true
	}
	return false
}

// coversFile reports whether any live rule is scoped to exactly file. It is the
// match used for Phase-1 extraction unknowns, which carry only a file and no
// category/name to match against a rule id; a rule with an empty file is
// unscoped and therefore does not cover a nameless extraction unknown. A rule
// whose until is malformed or already expired does not cover (fail closed).
func (s parsedIgnoreSet) coversFile(file, calToday string) bool {
	for _, rule := range s {
		if rule.File == "" || rule.File != file {
			continue
		}
		if rule.malformedUntil {
			continue
		}
		if rule.emptyReason {
			continue
		}
		if rule.untilStr != "" && calToday > rule.untilStr {
			continue
		}
		return true
	}
	return false
}
