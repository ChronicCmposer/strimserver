package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"strimserver-check-deps/common"
	"strimserver-check-deps/extractorimpl"
)

// This file is deliberately self-contained (D-25): it is the sole src of the
// `expected_pins_values_test` go_test target, so it must never reference the
// symbols declared in expected_pins_test.go. The fixture schema types below are
// therefore a private mirror of the fields this assertion needs.
type valuesPinDoc struct {
	Entries []valuesPin `json:"entries"`
}

type valuesPin struct {
	File       string `json:"file"`
	Name       string `json:"name"`
	Version    string `json:"version"`
	Kind       string `json:"kind"`
	TrackedNow bool   `json:"tracked_now"`
}

const (
	valuesPinsPath = "testdata/expected-pins.json"

	valuesGoModFile       = "core/controller/go.mod"
	valuesGoSumFile       = "core/controller/go.sum"
	valuesModuleFile      = "MODULE.bazel"
	valuesPackageJSONFile = "tools/streamdeck-plugin/package.json"

	// valuesTrackedTotal is the fixture's tracked_now total; a non-vacuous run
	// must verify exactly this many rows.
	valuesTrackedTotal = 93
)

// TestExtractionValuesMatchFixture is the GREEN value oracle: it runs the live
// extractors against the resolved workspace and asserts that every
// tracked_now=true fixture row's version is a member of the extracted version
// set. It never skips — a workspace-resolution or fixture-load failure is
// fatal — so a green run is real evidence, not a vacuous pass.
func TestExtractionValuesMatchFixture(t *testing.T) {
	root, err := repoRoot("")
	if err != nil {
		t.Fatalf("resolve repository root: %v", err)
	}
	// Under `bazel test --no-sandbox` the workspace root is the execroot's
	// `_main`, a directory whose entries are per-path symlinks. The
	// discovery-based extractors (go.mod/go.sum/node sub-repo walks) start at
	// the root and do not descend through those symlinks, so canonicalize
	// through a known root file to the live source tree first.
	modulePath, err := filepath.EvalSymlinks(filepath.Join(root, valuesModuleFile))
	if err != nil {
		t.Fatalf("resolve live workspace from %q: %v", root, err)
	}
	root = filepath.Dir(modulePath)

	doc := loadValuesPins(t)
	got := map[string][]string{}

	// Base extraction: the extractors registered by main() that the fixture's
	// tracked rows come from. Each dependency is appended, never assigned
	// last-wins, so a (file,name) with several values keeps them all.
	moduleDeps, _ := extractorimpl.ExtractModuleBazel(root)
	appendDeps(got, moduleDeps)
	toolchainDeps, _ := extractorimpl.ExtractToolchains(root)
	appendDeps(got, toolchainDeps)
	goModDeps, _ := extractorimpl.ExtractGoMod(root)
	appendDeps(got, goModDeps)
	scriptDeps, _ := extractorimpl.ExtractScripts(root)
	appendDeps(got, scriptDeps)
	workflowDeps, _ := extractorimpl.ExtractWorkflows(root)
	appendDeps(got, workflowDeps)

	// Adapters inject fixture-shaped rows that no single extractor emits under
	// the fixture's (file,name) keys. http_file blocks are parsed before the
	// digest adapter so their :sha256 keys are already populated and the digest
	// adapter skips them.
	moduleBazel, err := os.ReadFile(filepath.Join(root, valuesModuleFile))
	if err != nil {
		t.Fatalf("read %s: %v", valuesModuleFile, err)
	}
	injectHTTPFiles(got, string(moduleBazel))
	injectTrackedIntegrity(got, doc, moduleDeps)
	if err := injectPackageJSON(got, root); err != nil {
		t.Fatalf("package.json adapter: %v", err)
	}
	if err := injectGoModRequires(got, root); err != nil {
		t.Fatalf("go.mod require adapter: %v", err)
	}

	verified := 0
	for _, pin := range doc.Entries {
		if !pin.TrackedNow {
			continue
		}
		values := got[valuesKey(pin.File, pin.Name)]
		if !containsValue(values, pin.Version) {
			t.Errorf("tracked pin %s:%s = %q not in extracted set %v", pin.File, pin.Name, pin.Version, values)
			continue
		}
		verified++
	}
	t.Logf("verified %d tracked pins", verified)
	// Also write the count to stdout so `bazel test --test_output=all` records
	// the non-vacuous evidence even on a passing (non `-test.v`) run.
	fmt.Printf("verified %d tracked pins\n", verified)
	if verified != valuesTrackedTotal {
		t.Errorf("verified %d tracked pins, want %d", verified, valuesTrackedTotal)
	}

	// Independent of tracked_now: the go.sum transitive inventory is judged by
	// count against the fixture's recorded pair total.
	goSumDeps, _ := extractorimpl.ExtractGoSum(root)
	goSumPin, ok := findValuesPin(doc, valuesGoSumFile, "go.sum:transitive-module-pairs")
	if !ok {
		t.Fatalf("fixture is missing the %s go.sum:transitive-module-pairs row", valuesGoSumFile)
	}
	wantPairs, err := strconv.Atoi(goSumPin.Version)
	if err != nil {
		t.Fatalf("fixture go.sum pair total %q is not an integer: %v", goSumPin.Version, err)
	}
	if gotPairs := len(goSumDeps); gotPairs != wantPairs {
		t.Errorf("ExtractGoSum returned %d transitive module pairs, want %d", gotPairs, wantPairs)
	}
}

// injectHTTPFiles parses each MODULE.bazel http_file block itself (the shipped
// parseHTTPFile hardcodes the runtime name and is not used here, D-22) and
// injects the version row plus the :sha256 integrity row under the block's own
// name.
func injectHTTPFiles(got map[string][]string, moduleBazel string) {
	for _, args := range httpFileArgs(moduleBazel) {
		name := firstSubmatch(httpFileNameRe, args)
		sha := firstSubmatch(httpFileSHARe, args)
		version := firstSubmatch(iperfVersionRe, firstSubmatch(httpFileURLRe, args))
		if name == "" {
			continue
		}
		if version != "" {
			appendValue(got, valuesModuleFile, name, version)
		}
		if sha != "" {
			appendValue(got, valuesModuleFile, name+":sha256", sha)
		}
	}
}

// injectTrackedIntegrity satisfies the tracked integrity rows that carry no
// version field: a :sha256 row reads its hash from the matching base
// dependency's Note (unless the http_file adapter already filled that key), and
// a digest-only row (oci.pull) reads the sha256: token from the DigestPinned
// dependency's Source and APPENDS it — the base extractor emits that dep with an
// empty Version, so skipping an already-populated key would fail membership.
func injectTrackedIntegrity(got map[string][]string, doc valuesPinDoc, moduleDeps []common.Dependency) {
	for _, pin := range doc.Entries {
		if !pin.TrackedNow || pin.Kind != "integrity" {
			continue
		}
		key := valuesKey(pin.File, pin.Name)
		if strings.HasSuffix(pin.Name, ":sha256") {
			if len(got[key]) > 0 {
				continue
			}
			base := strings.TrimSuffix(pin.Name, ":sha256")
			for _, dep := range moduleDeps {
				if dep.File != pin.File || dep.Name != base {
					continue
				}
				if token := firstSubmatch(sha256NoteRe, dep.Note); token != "" {
					got[key] = append(got[key], token)
					break
				}
			}
			continue
		}
		for _, dep := range moduleDeps {
			if !dep.DigestPinned || dep.File != pin.File || dep.Name != pin.Name {
				continue
			}
			if token := sha256DigestRe.FindString(dep.Source); token != "" {
				got[key] = append(got[key], token)
				break
			}
		}
	}
}

type valuesPackageJSON struct {
	PackageManager  string            `json:"packageManager"`
	Dependencies    map[string]string `json:"dependencies"`
	DevDependencies map[string]string `json:"devDependencies"`
}

// injectPackageJSON injects the packageManager pin and the prefixed dependency
// ranges exactly as the fixture names them.
func injectPackageJSON(got map[string][]string, root string) error {
	data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(valuesPackageJSONFile)))
	if err != nil {
		return err
	}
	var manifest valuesPackageJSON
	if err := json.Unmarshal(data, &manifest); err != nil {
		return err
	}
	if manifest.PackageManager != "" {
		appendValue(got, valuesPackageJSONFile, "packageManager", manifest.PackageManager)
	}
	for name, version := range manifest.Dependencies {
		appendValue(got, valuesPackageJSONFile, "dependencies:"+name, version)
	}
	for name, version := range manifest.DevDependencies {
		appendValue(got, valuesPackageJSONFile, "devDependencies:"+name, version)
	}
	return nil
}

// injectGoModRequires injects the go.mod require pairs, skipping the indirect
// block (D-21). The `go` directive row comes from ExtractGoMod, not this
// adapter, so the two never overlap.
func injectGoModRequires(got map[string][]string, root string) error {
	data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(valuesGoModFile)))
	if err != nil {
		return err
	}
	inRequireBlock := false
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "//") {
			continue
		}
		if inRequireBlock {
			if strings.HasPrefix(trimmed, ")") {
				inRequireBlock = false
				continue
			}
			if strings.Contains(trimmed, "// indirect") {
				continue
			}
			if fields := strings.Fields(trimmed); len(fields) >= 2 {
				appendValue(got, valuesGoModFile, fields[0], fields[1])
			}
			continue
		}
		fields := strings.Fields(trimmed)
		if len(fields) < 2 || fields[0] != "require" {
			continue
		}
		if fields[1] == "(" {
			inRequireBlock = true
			continue
		}
		if len(fields) >= 3 && !strings.Contains(trimmed, "// indirect") {
			appendValue(got, valuesGoModFile, fields[1], fields[2])
		}
	}
	return nil
}

var (
	httpFileCallRe = regexp.MustCompile(`(?m)^http_file\(`)
	httpFileNameRe = regexp.MustCompile(`(?m)^\s*name\s*=\s*"([^"]*)"`)
	httpFileSHARe  = regexp.MustCompile(`(?m)^\s*sha256\s*=\s*"([^"]*)"`)
	httpFileURLRe  = regexp.MustCompile(`(?m)urls\s*=\s*\[\s*"([^"]*)"`)
	iperfVersionRe = regexp.MustCompile(`iperf3-([0-9][0-9.]*-r[0-9]+)\.apk`)
	sha256NoteRe   = regexp.MustCompile(`sha256=([0-9a-f]{64})`)
	sha256DigestRe = regexp.MustCompile(`sha256:[0-9a-f]{64}`)
)

// httpFileArgs returns the argument text inside each top-level http_file(...)
// call. It is quote/comment aware so a parenthesis inside a URL or a build file
// string never unbalances the scan.
func httpFileArgs(content string) []string {
	var calls []string
	for _, loc := range httpFileCallRe.FindAllStringIndex(content, -1) {
		open := strings.IndexByte(content[loc[0]:loc[1]], '(')
		if open < 0 {
			continue
		}
		open += loc[0]
		if end := matchingParen(content, open); end > open {
			calls = append(calls, content[open+1:end])
		}
	}
	return calls
}

// matchingParen returns the index of the ')' that closes the '(' at open, or -1
// when the call is unterminated.
func matchingParen(s string, open int) int {
	depth := 0
	for i := open; i < len(s); i++ {
		switch s[i] {
		case '\'', '"':
			i = skipQuotedValue(s, i) - 1
		case '#':
			for i < len(s) && s[i] != '\n' {
				i++
			}
			i--
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

// skipQuotedValue returns the index just past the closing quote of the quoted
// span starting at start, honoring backslash escapes.
func skipQuotedValue(s string, start int) int {
	quote := s[start]
	for i := start + 1; i < len(s); i++ {
		if s[i] == '\\' {
			i++
			continue
		}
		if s[i] == quote {
			return i + 1
		}
	}
	return len(s)
}

func valuesKey(file, name string) string {
	return file + "\x1f" + name
}

func appendValue(got map[string][]string, file, name, value string) {
	key := valuesKey(file, name)
	got[key] = append(got[key], value)
}

func appendDeps(got map[string][]string, deps []common.Dependency) {
	for _, dep := range deps {
		appendValue(got, dep.File, dep.Name, dep.Version)
	}
}

func containsValue(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func firstSubmatch(re *regexp.Regexp, s string) string {
	m := re.FindStringSubmatch(s)
	if m == nil {
		return ""
	}
	return m[1]
}

func findValuesPin(doc valuesPinDoc, file, name string) (valuesPin, bool) {
	for _, pin := range doc.Entries {
		if pin.File == file && pin.Name == name {
			return pin, true
		}
	}
	return valuesPin{}, false
}

// loadValuesPins reads and parses the fixture, failing the test (never
// skipping) when it is missing or malformed.
func loadValuesPins(t *testing.T) valuesPinDoc {
	t.Helper()
	data, err := os.ReadFile(filepath.FromSlash(valuesPinsPath))
	if err != nil {
		t.Fatalf("cannot read %s: %v", valuesPinsPath, err)
	}
	var doc valuesPinDoc
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("cannot parse %s: %v", valuesPinsPath, err)
	}
	if len(doc.Entries) == 0 {
		t.Fatalf("%s has no entries", valuesPinsPath)
	}
	return doc
}
