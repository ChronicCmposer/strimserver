package extractorimpl

import (
	"path/filepath"
	"strings"
	"testing"

	"strimserver-check-deps/common"
)

// envFixture mirrors the quoting/comment shapes of the real .env: a quoted pin
// with a `go` prefix, a quoted path, a quoted value with a trailing comment,
// and an unquoted value with a trailing comment.
const envFixture = `# golang configuration
PROJECT_GO_VERSION_TAG="go1.26.4"
PROJECT_GO_ROOT="$HOME/strimserver/go"
GOROOT_BOOTSTRAP="/usr/lib/go-1.26"

# other settings
CFN_STACK_NAME="strimserver"      # stack from strimserver-infra.yaml
UNQUOTED=value   # trailing comment
`

func TestParseEnv(t *testing.T) {
	deps, unknowns := parseEnv([]byte(envFixture), ".env")
	if len(unknowns) != 0 {
		t.Fatalf("parseEnv unknowns = %v, want none", unknowns)
	}
	goDep := findDepVersion(t, deps, common.CategoryToolchain, "Go", "1.26.4")
	if goDep == nil {
		t.Fatalf("PROJECT_GO_VERSION_TAG not normalized to 1.26.4: %v", deps)
	}
	if goDep.File != ".env" {
		t.Errorf("Go File = %q, want .env", goDep.File)
	}
	bootDep := findDepVersion(t, deps, common.CategoryToolchain, "GOROOT_BOOTSTRAP", "/usr/lib/go-1.26")
	if bootDep == nil {
		t.Errorf("GOROOT_BOOTSTRAP not extracted: %v", deps)
	}
}

// TestParseEnvSingleQuotes proves single-quoted values are read and a value
// without the `go` prefix is left untouched.
func TestParseEnvSingleQuotes(t *testing.T) {
	const fixture = "PROJECT_GO_VERSION_TAG='1.25.1'\nGOROOT_BOOTSTRAP='/opt/go'\n"
	deps, unknowns := parseEnv([]byte(fixture), ".env")
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if got := findDepVersion(t, deps, common.CategoryToolchain, "Go", "1.25.1"); got == nil {
		t.Errorf("single-quoted tag not extracted: %v", deps)
	}
	if got := findDepVersion(t, deps, common.CategoryToolchain, "GOROOT_BOOTSTRAP", "/opt/go"); got == nil {
		t.Errorf("single-quoted bootstrap not extracted: %v", deps)
	}
}

// TestParseEnvMissingKeys proves a .env lacking the two pins fails loud rather
// than silently dropping them.
func TestParseEnvMissingKeys(t *testing.T) {
	_, unknowns := parseEnv([]byte("# nothing here\nOTHER=1\n"), ".env")
	if len(unknowns) != 2 {
		t.Fatalf("unknowns = %v, want two (PROJECT_GO_VERSION_TAG + GOROOT_BOOTSTRAP)", unknowns)
	}
	if !strings.Contains(unknowns[0].Reason, "PROJECT_GO_VERSION_TAG") ||
		!strings.Contains(unknowns[1].Reason, "GOROOT_BOOTSTRAP") {
		t.Errorf("unknown reasons = %v, want one per missing key", unknowns)
	}
}

func TestExtractEnv(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, ".env"), envFixture)

	deps, unknowns := ExtractEnv(root)
	if len(unknowns) != 0 {
		t.Fatalf("ExtractEnv unknowns = %v, want none", unknowns)
	}
	if len(deps) != 2 {
		t.Fatalf("ExtractEnv deps = %v, want exactly Go + GOROOT_BOOTSTRAP", deps)
	}
}

// ExtractEnv must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractEnv
