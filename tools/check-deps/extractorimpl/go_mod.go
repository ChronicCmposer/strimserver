package extractorimpl

import (
	"regexp"

	"strimserver-check-deps/common"
)

var goDirectiveRe = regexp.MustCompile(`(?m)^go\s+([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$`)

func ExtractGoMod(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	return common.ReadAndParse(root, "core/controller/go.mod", parseGoMod)
}

// ExtractGoMod must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractGoMod

// parseGoMod extracts the Go toolchain version from the `go` directive. The
// individual Go module requires are checked in a later phase via `go list -u`.
func parseGoMod(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	m := goDirectiveRe.FindSubmatch(data)
	if m == nil {
		return nil, []common.ExtractionUnknown{{File: file, Reason: "no `go` directive found"}}
	}
	return []common.Dependency{{
		Category: common.CategoryToolchain,
		Name:     "Go",
		Version:  string(m[1]),
		Source:   "core/controller/go.mod `go` directive",
		File:     file,
	}}, nil
}
