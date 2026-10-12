package extractorimpl

import (
	"os"
	"path/filepath"
	"strings"
	"unicode"

	"strimserver-check-deps/common"
)

// ExtractBazelrc reads the root .bazelrc and emits every registered toolchain
// and platform selection as a toolchain-category dependency with an integrity
// role. The directives --platforms, --extra_toolchains, and register_toolchains
// choose the toolchain graph the build resolves, but they name a label rather
// than a version, so the integrity role surfaces them in the integrity section
// (they carry no comparable version) without tripping --strict. A missing
// .bazelrc is optional and yields nothing.
func ExtractBazelrc(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	data, err := os.ReadFile(filepath.Join(root, bazelrcFileName))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, []common.ExtractionUnknown{{
			File:   bazelrcFileName,
			Reason: "cannot read file: " + err.Error(),
		}}
	}
	return parseBazelrc(data, bazelrcFileName)
}

// ExtractBazelrc must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractBazelrc

// bazelrcFileName is the root configuration file this extractor owns.
const bazelrcFileName = ".bazelrc"

// bazelrcRegistration is one toolchain/platform label found in .bazelrc,
// together with the directive that registered it.
type bazelrcRegistration struct {
	label  string
	source string
}

// bazelrcToolchainFlags are the flag forms that select a toolchain or platform.
var bazelrcToolchainFlags = []string{"--platforms", "--extra_toolchains"}

// parseBazelrc extracts the toolchain/platform registrations from a .bazelrc
// body. It recognizes --platforms and --extra_toolchains (in `=value` and
// space-separated forms, with comma-separated lists) and register_toolchains
// argument labels. Every match becomes one toolchain-category integrity
// dependency; unrelated flags are not pins. Output order follows the file.
func parseBazelrc(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	seen := make(map[string]struct{})
	add := func(label, source string) {
		if label == "" {
			return
		}
		key := source + "\x1f" + label
		if _, duplicate := seen[key]; duplicate {
			return
		}
		seen[key] = struct{}{}
		deps = append(deps, common.Dependency{
			Category: common.CategoryToolchain,
			Name:     label,
			Source:   source,
			File:     file,
			Role:     common.RoleIntegrity,
		})
	}

	var code strings.Builder
	for _, raw := range strings.Split(string(data), "\n") {
		line := stripBazelrcComment(raw)
		code.WriteString(line)
		code.WriteByte('\n')
		for _, reg := range bazelrcFlagRegistrations(strings.Fields(line)) {
			add(reg.label, reg.source)
		}
	}
	for _, label := range registerToolchainLabels(code.String()) {
		add(label, "register_toolchains")
	}
	return deps, nil
}

// stripBazelrcComment removes a trailing # comment from one .bazelrc line.
func stripBazelrcComment(line string) string {
	if idx := strings.Index(line, "#"); idx >= 0 {
		return line[:idx]
	}
	return line
}

// bazelrcFlagRegistrations returns the toolchain/platform labels a .bazelrc
// line's flags register.
func bazelrcFlagRegistrations(fields []string) []bazelrcRegistration {
	var regs []bazelrcRegistration
	for i := range fields {
		for _, flag := range bazelrcToolchainFlags {
			value, ok := bazelrcFlagValue(fields, i, flag)
			if !ok {
				continue
			}
			for _, label := range splitCommaList(value) {
				regs = append(regs, bazelrcRegistration{label: label, source: flag})
			}
		}
	}
	return regs
}

// bazelrcFlagValue returns the value bound to flag at token i, accepting both
// `--flag=value` and `--flag value` forms.
func bazelrcFlagValue(fields []string, i int, flag string) (string, bool) {
	token := fields[i]
	if value, found := strings.CutPrefix(token, flag+"="); found {
		return value, true
	}
	if token == flag && i+1 < len(fields) {
		return fields[i+1], true
	}
	return "", false
}

// splitCommaList splits a comma-separated flag value, trimming spaces and
// dropping empty entries.
func splitCommaList(value string) []string {
	var out []string
	for _, part := range strings.Split(value, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}

// registerToolchainLabels extracts the label arguments of every
// register_toolchains(...) call in text (comment-stripped, possibly spanning
// lines). Only label-shaped arguments (containing "//") are returned, so
// unrelated positional arguments never become pins.
func registerToolchainLabels(text string) []string {
	var labels []string
	for rest := text; ; {
		idx := strings.Index(rest, "register_toolchains")
		if idx < 0 {
			return labels
		}
		rest = rest[idx+len("register_toolchains"):]
		open := strings.Index(rest, "(")
		if open < 0 {
			return labels
		}
		close := strings.Index(rest[open:], ")")
		if close < 0 {
			return labels
		}
		args := rest[open+1 : open+close]
		rest = rest[open+close+1:]
		for _, token := range strings.FieldsFunc(args, isBazelrcLabelSeparator) {
			if strings.Contains(token, "//") {
				labels = append(labels, token)
			}
		}
	}
}

// isBazelrcLabelSeparator reports whether r separates label tokens in a
// register_toolchains argument list.
func isBazelrcLabelSeparator(r rune) bool {
	return r == ',' || r == '"' || r == '\'' || unicode.IsSpace(r)
}
