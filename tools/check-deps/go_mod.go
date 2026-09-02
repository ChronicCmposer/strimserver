package main

import (
	"regexp"
)

var goDirectiveRe = regexp.MustCompile(`(?m)^go\s+([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$`)

// extractGoMod reads the controller Go module manifest.
func extractGoMod(root string) ([]dependency, []unknown) {
	return readAndParse(root, "core/controller/go.mod", parseGoMod)
}

// parseGoMod extracts the Go toolchain version from the `go` directive. The
// individual Go module requires are checked in a later phase via `go list -u`.
func parseGoMod(data []byte, file string) ([]dependency, []unknown) {
	m := goDirectiveRe.FindSubmatch(data)
	if m == nil {
		return nil, []unknown{{File: file, Reason: "no `go` directive found"}}
	}
	return []dependency{{
		Category: "toolchain",
		Name:     "Go",
		Version:  string(m[1]),
		Source:   "core/controller/go.mod `go` directive",
		File:     file,
	}}, nil
}
