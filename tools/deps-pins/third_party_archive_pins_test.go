package pins

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// thisThirdPartyArchiveLib describes one library whose MODULE.bazel
// http_archive pin must agree with its third_party/<name>/pin.json. header is
// the configure-generated file overlaid from the main repo via the rule's
// `files` map; it is empty when the fetched repo needs no overlay.
type thisThirdPartyArchiveLib struct {
	name   string
	header string
}

var thisThirdPartyArchiveLibs = []thisThirdPartyArchiveLib{
	{name: "yyjson"},
	{name: "libmicrohttpd", header: "MHD_config.h"},
	{name: "wslay", header: "config.h"},
}

// thisThirdPartyArchivePin mirrors the subset of third_party/<lib>/pin.json
// that MODULE.bazel duplicates.
type thisThirdPartyArchivePin struct {
	Name     string `json:"name"`
	Version  string `json:"version"`
	Upstream string `json:"upstream"`
	Sha256   string `json:"sha256"`
}

// TestThirdPartyArchivePins is the offline drift guard between MODULE.bazel's
// http_archive rules and third_party/<lib>/pin.json. Each rule is located by a
// balanced-paren scan (never a whole-file regex) and fails closed on a missing
// block or attribute, so a renamed or malformed rule turns the test red.
func TestThirdPartyArchivePins(t *testing.T) {
	root, err := repoRoot()
	if err != nil {
		t.Fatalf("resolve repository root: %v", err)
	}

	module, err := os.ReadFile(filepath.Join(root, "MODULE.bazel"))
	if err != nil {
		t.Fatalf("read MODULE.bazel: %v", err)
	}

	for _, lib := range thisThirdPartyArchiveLibs {
		t.Run(lib.name, func(t *testing.T) {
			block, err := thisFindArchiveBlock(string(module), lib.name)
			if err != nil {
				t.Fatalf("%v", err)
			}

			pin, err := thisReadArchivePin(filepath.Join(root, "third_party", lib.name, "pin.json"))
			if err != nil {
				t.Fatalf("%v", err)
			}

			url, ok := thisArchiveAttr(block, "url")
			if !ok {
				t.Fatalf("http_archive(%q): missing url attribute", lib.name)
			}
			if url != pin.Upstream {
				t.Errorf("http_archive(%q) url = %q, pin.json upstream = %q", lib.name, url, pin.Upstream)
			}

			sha, ok := thisArchiveAttr(block, "sha256")
			if !ok {
				t.Fatalf("http_archive(%q): missing sha256 attribute", lib.name)
			}
			if sha != pin.Sha256 {
				t.Errorf("http_archive(%q) sha256 = %q, pin.json sha256 = %q", lib.name, sha, pin.Sha256)
			}

			strip, ok := thisArchiveAttr(block, "strip_prefix")
			if !ok {
				t.Fatalf("http_archive(%q): missing strip_prefix attribute", lib.name)
			}
			wantStrip := fmt.Sprintf("%s-%s", pin.Name, pin.Version)
			if strip != wantStrip {
				t.Errorf("http_archive(%q) strip_prefix = %q, want %q", lib.name, strip, wantStrip)
			}

			if lib.header == "" {
				return
			}
			files, ok := thisBraceBlock(block, "files")
			if !ok {
				t.Fatalf("http_archive(%q): missing files overlay", lib.name)
			}
			got, ok := thisMapValue(files, lib.header)
			if !ok {
				t.Fatalf("http_archive(%q): files overlay missing %q", lib.name, lib.header)
			}
			wantLabel := fmt.Sprintf("//third_party/%s:%s", lib.name, lib.header)
			if got != wantLabel {
				t.Errorf("http_archive(%q) files[%q] = %q, want %q", lib.name, lib.header, got, wantLabel)
			}
		})
	}
}

// thisFindArchiveBlock returns the parenthesised body of the http_archive rule
// whose name attribute equals name. It scans for balanced parentheses rather
// than matching the whole file, so neighbouring rules cannot bleed together.
func thisFindArchiveBlock(content, name string) (string, error) {
	const call = "http_archive("
	for offset := 0; ; {
		idx := strings.Index(content[offset:], call)
		if idx < 0 {
			return "", fmt.Errorf("MODULE.bazel: no http_archive block named %q", name)
		}
		open := offset + idx + len(call)
		depth := 1
		i := open
		for ; i < len(content) && depth > 0; i++ {
			switch content[i] {
			case '(':
				depth++
			case ')':
				depth--
			}
		}
		if depth != 0 {
			return "", fmt.Errorf("MODULE.bazel: unbalanced parentheses in http_archive near %q", content[offset+idx:])
		}
		block := content[open : i-1]
		if thisArchiveAttrEquals(block, "name", name) {
			return block, nil
		}
		offset = i
	}
}

// thisArchiveAttrEquals reports whether block has a top-level `key = "value"`
// attribute matching value.
func thisArchiveAttrEquals(block, key, value string) bool {
	got, ok := thisArchiveAttr(block, key)
	return ok && got == value
}

// thisArchiveAttr extracts a quoted `key = "..."` attribute from a rule body.
// It requires an identifier boundary before key so `name` does not match
// `strip_prefix` and the like, and returns false for non-string values (e.g.
// the `files = { ... }` map).
func thisArchiveAttr(block, key string) (string, bool) {
	for offset := 0; ; {
		idx := strings.Index(block[offset:], key)
		if idx < 0 {
			return "", false
		}
		start := offset + idx
		offset = start + len(key)
		if start > 0 && thisIsIdentByte(block[start-1]) {
			continue
		}
		rest := strings.TrimLeft(block[offset:], " \t")
		if !strings.HasPrefix(rest, "=") {
			continue
		}
		rest = strings.TrimLeft(rest[1:], " \t")
		if !strings.HasPrefix(rest, `"`) {
			continue
		}
		end := strings.IndexByte(rest[1:], '"')
		if end < 0 {
			return "", false
		}
		return rest[1 : 1+end], true
	}
}

// thisBraceBlock returns the body of a `key = { ... }` map attribute.
func thisBraceBlock(block, key string) (string, bool) {
	for offset := 0; ; {
		idx := strings.Index(block[offset:], key)
		if idx < 0 {
			return "", false
		}
		start := offset + idx
		offset = start + len(key)
		if start > 0 && thisIsIdentByte(block[start-1]) {
			continue
		}
		rest := strings.TrimLeft(block[offset:], " \t")
		if !strings.HasPrefix(rest, "=") {
			continue
		}
		rest = strings.TrimLeft(rest[1:], " \t")
		if !strings.HasPrefix(rest, "{") {
			continue
		}
		depth := 0
		for i := 0; i < len(rest); i++ {
			switch rest[i] {
			case '{':
				depth++
			case '}':
				depth--
				if depth == 0 {
					return rest[1:i], true
				}
			}
		}
		return "", false
	}
}

// thisMapValue extracts the quoted value from a `"key": "value"` map entry.
func thisMapValue(body, key string) (string, bool) {
	needle := `"` + key + `"`
	idx := strings.Index(body, needle)
	if idx < 0 {
		return "", false
	}
	rest := strings.TrimLeft(body[idx+len(needle):], " \t")
	if !strings.HasPrefix(rest, ":") {
		return "", false
	}
	rest = strings.TrimLeft(rest[1:], " \t")
	if !strings.HasPrefix(rest, `"`) {
		return "", false
	}
	end := strings.IndexByte(rest[1:], '"')
	if end < 0 {
		return "", false
	}
	return rest[1 : 1+end], true
}

func thisIsIdentByte(b byte) bool {
	return b == '_' || b == '.' || b == '-' ||
		(b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}

// thisReadArchivePin loads third_party/<lib>/pin.json.
func thisReadArchivePin(path string) (thisThirdPartyArchivePin, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return thisThirdPartyArchivePin{}, fmt.Errorf("read %s: %w", path, err)
	}
	var pin thisThirdPartyArchivePin
	if err := json.Unmarshal(data, &pin); err != nil {
		return thisThirdPartyArchivePin{}, fmt.Errorf("parse %s: %w", path, err)
	}
	if pin.Name == "" || pin.Version == "" || pin.Upstream == "" || pin.Sha256 == "" {
		return thisThirdPartyArchivePin{}, fmt.Errorf("%s: incomplete pin (name/version/upstream/sha256 required)", path)
	}
	return pin, nil
}
