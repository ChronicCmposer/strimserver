package utilities

import "testing"

// These tests exercise the string/date/snapshot helpers in utilities.go.

// --- utilities string/date/snapshot helpers --------------------------------

func TestStripTagPrefix(t *testing.T) {
	cases := map[string]string{
		"v2.13.2":          "2.13.2",
		"n13.0.19.0":       "13.0.19.0",
		"10.3p1":           "10.3p1",
		"20260824T082821Z": "20260824T082821Z",
	}
	for in, want := range cases {
		if got := StripTagPrefix(in); got != want {
			t.Errorf("StripTagPrefix(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLeadingInt(t *testing.T) {
	cases := []struct {
		in     string
		want   int
		wantOK bool
	}{
		{"", 0, false},
		{"000", 0, true},
		{"63", 63, true},
		{"007", 7, true},
		{"abc", 0, false},
	}
	for _, c := range cases {
		got, ok := LeadingInt(c.in)
		if got != c.want || ok != c.wantOK {
			t.Errorf("LeadingInt(%q) = (%d, %v), want (%d, %v)", c.in, got, ok, c.want, c.wantOK)
		}
	}
}

func TestIsAllDigits(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"", false},
		{"0", true},
		{"9", true},
		{":", false}, // byte right after '9'
		{"007", true},
		{"123", true},
		{"abc", false},
		{"1a", false},
		{"a1", false},
	}
	for _, c := range cases {
		if got := IsAllDigits(c.in); got != c.want {
			t.Errorf("IsAllDigits(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestExtractSnapshotTs(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"archive/debian/20260824T082821Z/", "20260824T082821Z"},
		{"no timestamp here", ""},
	}
	for _, c := range cases {
		if got := ExtractSnapshotTs(c.in); got != c.want {
			t.Errorf("ExtractSnapshotTs(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestExtractSnapshotTsAll(t *testing.T) {
	in := "20260824T082821Z and 20260901T120000Z and 20260825T000000Z"
	want := []string{"20260824T082821Z", "20260901T120000Z", "20260825T000000Z"}
	got := ExtractSnapshotTsAll(in)
	if len(got) != len(want) {
		t.Fatalf("ExtractSnapshotTsAll(%q) returned %d timestamps, want %d: %v", in, len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("ExtractSnapshotTsAll(%q)[%d] = %q, want %q", in, i, got[i], want[i])
		}
	}
}
