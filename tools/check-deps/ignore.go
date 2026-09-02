package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// This file owns deps-ignore.json: the checked-in, git-tracked list of
// intentional pins (e.g. @rollup/rollup-linux-arm64-gnu or the Debian
// reproducibility snapshot) that a plain run reports as updates but a reviewer
// has decided to tolerate. Each rule is a pure predicate over (id, today), so
// matching is unit-testable.

// ignoreRule is one entry in deps-ignore.json. id identifies the dependency
// (category + "/" + name, e.g. "npm/@rollup/rollup-linux-arm64-gnu"); reason is
// the human justification; until optionally expires the rule (YYYY-MM-DD).
type ignoreRule struct {
	ID     string `json:"id"`
	Reason string `json:"reason"`
	Until  string `json:"until,omitempty"`
}

// ignoreSet is the ordered collection of ignore rules from the file.
type ignoreSet []ignoreRule

// ignoreFileName is the checked-in file name at the repo root.
const ignoreFileName = "deps-ignore.json"

// parseIgnore decodes a deps-ignore.json body. Pure: takes the raw bytes and
// returns typed rules, failing loudly on malformed input.
func parseIgnore(data []byte) (ignoreSet, error) {
	var rules ignoreSet
	if err := json.Unmarshal(data, &rules); err != nil {
		return nil, err
	}
	return rules, nil
}

// loadIgnore reads deps-ignore.json at the repo root. A missing or unreadable
// file yields an empty set (never a crash): a plain run simply applies no
// ignores. Malformed JSON is reported as an empty set with a loud warning so
// the failure is never silent.
func loadIgnore(root string) ignoreSet {
	path := filepath.Join(root, ignoreFileName)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	rules, err := parseIgnore(data)
	if err != nil {
		warnf("ignoring malformed %s: %v", ignoreFileName, err)
		return nil
	}
	return rules
}

// isIgnored reports whether id matches any non-expired rule as of today. A
// rule applies on and before its until date; it is expired once today is
// strictly after until. Rules without an until never expire.
func (s ignoreSet) isIgnored(id string, today time.Time) bool {
	for _, rule := range s {
		if rule.ID != id {
			continue
		}
		if rule.Until != "" {
			until, err := time.Parse("2006-01-02", rule.Until)
			if err == nil && today.After(until) {
				// Expired: the pin is no longer a tolerated intentional choice.
				continue
			}
		}
		return true
	}
	return false
}
