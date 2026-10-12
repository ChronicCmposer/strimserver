package extractorimpl

import (
	"strings"

	"strimserver-check-deps/common"
)

// ExtractEnv reads the repository .env and reports its Go toolchain pins:
// PROJECT_GO_VERSION_TAG (normalized from go1.26.4 to 1.26.4) and
// GOROOT_BOOTSTRAP.
func ExtractEnv(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	return common.ReadAndParse(root, ".env", parseEnv)
}

// ExtractEnv must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractEnv

// parseEnv extracts the two Go toolchain pins from the repo .env. Each missing
// key surfaces as an unknown rather than a silent drop.
func parseEnv(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	assignments := parseEnvAssignments(string(data))
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown

	tag, ok := assignments["PROJECT_GO_VERSION_TAG"]
	if !ok {
		unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "PROJECT_GO_VERSION_TAG not found"})
	} else {
		deps = append(deps, common.Dependency{
			Category: common.CategoryToolchain,
			Name:     "Go",
			Version:  strings.TrimPrefix(tag, "go"),
			Source:   file + " `PROJECT_GO_VERSION_TAG`",
			File:     file,
		})
	}

	bootstrap, ok := assignments["GOROOT_BOOTSTRAP"]
	if !ok {
		unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "GOROOT_BOOTSTRAP not found"})
	} else {
		deps = append(deps, common.Dependency{
			Category: common.CategoryToolchain,
			Name:     "GOROOT_BOOTSTRAP",
			Version:  bootstrap,
			Source:   file + " `GOROOT_BOOTSTRAP`",
			File:     file,
			Note:     "bootstrap Go toolchain path",
		})
	}

	return deps, unknowns
}

// parseEnvAssignments parses dotenv-style KEY=value lines into a map. Blank
// lines and '#' comment lines are skipped, as are lines without '='. A later
// assignment of a key overrides an earlier one, matching dotenv semantics.
func parseEnvAssignments(content string) map[string]string {
	assignments := make(map[string]string)
	for _, line := range strings.Split(content, "\n") {
		key, value, ok := parseEnvLine(line)
		if !ok {
			continue
		}
		assignments[key] = value
	}
	return assignments
}

// parseEnvLine parses one KEY=value line. It reports ok=false for a blank line,
// a '#' comment, or a line without a non-empty key.
func parseEnvLine(line string) (key, value string, ok bool) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") {
		return "", "", false
	}
	eq := strings.IndexByte(line, '=')
	if eq < 0 {
		return "", "", false
	}
	key = strings.TrimSpace(line[:eq])
	if key == "" {
		return "", "", false
	}
	return key, envValue(line[eq+1:]), true
}

// envValue extracts a value from the text following '='. Quoting and comments
// follow the same rules as module_bazel.go's Starlark scanner (shared
// skipStringOrComment): a quoted value runs to its matching quote, honoring
// backslash escapes, and any trailing text is ignored as a comment; an
// unquoted value runs to an unescaped '#' comment or the end of the line and is
// right-trimmed.
func envValue(rest string) string {
	i := 0
	for i < len(rest) && (rest[i] == ' ' || rest[i] == '\t') {
		i++
	}
	if i >= len(rest) {
		return ""
	}

	if rest[i] == '"' || rest[i] == '\'' {
		quote := rest[i]
		end := skipStringOrComment(rest, i)
		if end > i+1 && rest[end-1] == quote {
			return unescapeEnvValue(rest[i+1 : end-1])
		}
		return unescapeEnvValue(rest[i+1:]) // unterminated quote: take the rest
	}

	if hash := strings.IndexByte(rest, '#'); hash >= 0 {
		rest = rest[:hash]
	}
	return strings.TrimRight(rest, " \t")
}

// unescapeEnvValue resolves backslash escapes the way module_bazel.go's quoted
// scanner does: a backslash escapes the following character.
func unescapeEnvValue(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			i++
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
