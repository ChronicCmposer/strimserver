package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// These tests cover the baked-AMI driver-floor advisory: check-deps resolves the
// Image Builder-published SSM parameter, reads the baked AMI's
// strimserver:nvidia-driver tag, and warns when that tag is below the
// NVIDIA_DRIVER_FLOOR parsed from deploy/aws/lib/nvidia.sh. The aws CLI is
// faked with a PATH shim (the same pattern resolverimpl/aws_test.go uses), so no
// real aws binary, credentials, or network are touched.

// fakeBakedAWS writes an executable aws shim into dir. `ssm get-parameter`
// prints ssmOut and exits ssmExit; `ec2 describe-images` prints tagsOut and
// exits tagsExit. When AWS_BAKED_LOG is set, every invocation appends its
// argument vector to that file so a test can assert the exact command.
func fakeBakedAWS(t *testing.T, dir, ssmOut string, ssmExit int, tagsOut string, tagsExit int) {
	t.Helper()
	script := "#!/bin/sh\n" +
		"if [ -n \"$AWS_BAKED_LOG\" ]; then printf '%s\\n' \"$*\" >> \"$AWS_BAKED_LOG\"; fi\n" +
		"case \"$1\" in\n" +
		"  ssm) if [ \"$2\" = \"get-parameter\" ]; then printf '%s\\n' '" + ssmOut + "'; exit " + strconv.Itoa(ssmExit) + "; fi ;;\n" +
		"  ec2) shift; if [ \"$1\" = \"describe-images\" ]; then printf '%s' '" + tagsOut + "'; exit " + strconv.Itoa(tagsExit) + "; fi ;;\n" +
		"esac\n" +
		"exit 255\n"
	if err := os.WriteFile(filepath.Join(dir, "aws"), []byte(script), 0o755); err != nil {
		t.Fatalf("writing aws shim: %v", err)
	}
}

// bakedFloorRepo writes a throwaway repo tree containing only the floor file.
func bakedFloorRepo(t *testing.T, floor string) string {
	t.Helper()
	return WriteRepoTree(t, map[string]string{
		nvidiaFloorPath: "NVIDIA_DRIVER_FLOOR=\"" + floor + "\"\n",
	})
}

// useFakeAWS puts the shim dir first on PATH for the duration of the test.
func useFakeAWS(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func TestParseNvidiaDriverFloor(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
		err  bool
	}{
		{"double quoted", "NVIDIA_DRIVER_FLOOR=\"620.70.06\"\n", "620.70.06", false},
		{"bare", "NVIDIA_DRIVER_FLOOR=620.70.06\n", "620.70.06", false},
		{"single quoted", "NVIDIA_DRIVER_FLOOR='620.70.06'\n", "620.70.06", false},
		{"surrounded by other lines", "# floor\nNVIDIA_DRIVER_FLOOR=\"620.70.06\"\n# end\n", "620.70.06", false},
		{"commented out only", "# NVIDIA_DRIVER_FLOOR=\"620.70.06\"\n", "", true},
		{"missing", "OTHER=1\n", "", true},
		{"empty value", "NVIDIA_DRIVER_FLOOR=\"\"\n", "", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseNvidiaDriverFloor([]byte(tc.in))
			if tc.err {
				if err == nil {
					t.Errorf("parseNvidiaDriverFloor(%q) = %q, want error", tc.in, got)
				}
				return
			}
			if err != nil || got != tc.want {
				t.Errorf("parseNvidiaDriverFloor(%q) = %q, %v; want %q", tc.in, got, err, tc.want)
			}
		})
	}
}

func TestParseImageTagsOutput(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want map[string]string
		err  bool
	}{
		{"one tag", `[{"Key":"strimserver:nvidia-driver","Value":"620.70.06"}]`, map[string]string{"strimserver:nvidia-driver": "620.70.06"}, false},
		{"several tags", `[{"Key":"a","Value":"1"},{"Key":"strimserver:nvidia-driver","Value":"620.70.06"}]`, map[string]string{"a": "1", "strimserver:nvidia-driver": "620.70.06"}, false},
		{"empty array", `[]`, map[string]string{}, false},
		{"null", `null`, map[string]string{}, false},
		{"malformed", `not json`, nil, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseImageTagsOutput([]byte(tc.in))
			if tc.err {
				if err == nil {
					t.Errorf("parseImageTagsOutput(%q) = %v, want error", tc.in, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseImageTagsOutput(%q): %v", tc.in, err)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("parseImageTagsOutput(%q) = %v, want %v", tc.in, got, tc.want)
			}
			for k, v := range tc.want {
				if got[k] != v {
					t.Errorf("tag %q = %q, want %q", k, got[k], v)
				}
			}
		})
	}
}

func TestDriverVersionCompare(t *testing.T) {
	cases := []struct {
		a, b string
		want int
		ok   bool
	}{
		{"620.70.06", "620.70.06", 0, true},
		{"595.71.05", "620.70.06", -1, true},
		{"630.0.0", "620.70.06", 1, true},
		{"620.70", "620.70.06", -1, true},
		{"620.70.06.1", "620.70.06", 1, true},
		{"", "620.70.06", 0, false},
		{"garbage", "620.70.06", 0, false},
		{"620..06", "620.70.06", 0, false},
	}
	for _, tc := range cases {
		got, ok := driverVersionCompare(tc.a, tc.b)
		if ok != tc.ok {
			t.Errorf("driverVersionCompare(%q,%q) ok = %v, want %v", tc.a, tc.b, ok, tc.ok)
			continue
		}
		if ok && got != tc.want {
			t.Errorf("driverVersionCompare(%q,%q) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}

// TestCheckBakedAMIWarnsWhenTagBelowFloor is the primary contract: a baked AMI
// whose driver tag is below the parsed floor emits the T-stale-baked-ami warning
// with actionable remediation naming both the floor and the Image Builder
// pipeline.
func TestCheckBakedAMIWarnsWhenTagBelowFloor(t *testing.T) {
	binDir := t.TempDir()
	fakeBakedAWS(t, binDir, "ami-0123456789abcdef0", 0,
		`[{"Key":"strimserver:nvidia-driver","Value":"595.71.05"}]`, 0)
	useFakeAWS(t, binDir)
	root := bakedFloorRepo(t, "620.70.06")

	var warns []string
	checkBakedAMI(root, 5*time.Second, captureWarn(&warns))

	if len(warns) != 1 {
		t.Fatalf("checkBakedAMI warned %d time(s), want exactly 1: %v", len(warns), warns)
	}
	got := warns[0]
	for _, want := range []string{bakedAMIStaleWarningID, "595.71.05", "620.70.06", "NVIDIA_DRIVER_FLOOR", "Image Builder", "strimserver:nvidia-driver"} {
		if !strings.Contains(got, want) {
			t.Errorf("warning %q does not contain %q", got, want)
		}
	}
}

// TestCheckBakedAMINoWarningAtOrAboveFloor proves the warning is strictly for a
// below-floor tag: an equal or newer tag is silent.
func TestCheckBakedAMINoWarningAtOrAboveFloor(t *testing.T) {
	for _, tag := range []string{"620.70.06", "621.0.0", "630.1.2"} {
		t.Run(tag, func(t *testing.T) {
			binDir := t.TempDir()
			fakeBakedAWS(t, binDir, "ami-0123456789abcdef0", 0,
				`[{"Key":"strimserver:nvidia-driver","Value":"`+tag+`"}]`, 0)
			useFakeAWS(t, binDir)
			root := bakedFloorRepo(t, "620.70.06")

			var warns []string
			checkBakedAMI(root, 5*time.Second, captureWarn(&warns))
			if len(warns) != 0 {
				t.Errorf("tag %s at/above floor warned: %v", tag, warns)
			}
		})
	}
}

// TestCheckBakedAMINoWarningWhenNotApplicable covers the "not applicable yet"
// paths: the SSM parameter is not published and the AMI carries no driver tag.
// Neither is a staleness signal, so neither warns.
func TestCheckBakedAMINoWarningWhenNotApplicable(t *testing.T) {
	cases := []struct {
		name     string
		ssmOut   string
		ssmExit  int
		tagsOut  string
		tagsExit int
	}{
		{"ssm parameter missing", "ParameterNotFound", 255, `[]`, 0},
		{"ami tags missing", "ami-0123456789abcdef0", 0, `[]`, 0},
		{"driver tag absent", "ami-0123456789abcdef0", 0, `[{"Key":"Name","Value":"baked"}]`, 0},
		{"describe-images fails", "ami-0123456789abcdef0", 0, "aws: error", 255},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			binDir := t.TempDir()
			fakeBakedAWS(t, binDir, tc.ssmOut, tc.ssmExit, tc.tagsOut, tc.tagsExit)
			useFakeAWS(t, binDir)
			root := bakedFloorRepo(t, "620.70.06")

			var warns []string
			checkBakedAMI(root, 5*time.Second, captureWarn(&warns))
			if len(warns) != 0 {
				t.Errorf("%s warned %v, want none (not applicable)", tc.name, warns)
			}
		})
	}
}

// TestCheckBakedAMIQueriesUsEast2 proves the check targets the design-contract
// region and SSM parameter: the Image Builder pipeline publishes the AMI id at
// /strimserver/ami/baked/latest in us-east-2, so the aws reads must name both.
func TestCheckBakedAMIQueriesUsEast2(t *testing.T) {
	binDir := t.TempDir()
	logFile := filepath.Join(t.TempDir(), "aws.log")
	fakeBakedAWS(t, binDir, "ami-0123456789abcdef0", 0,
		`[{"Key":"strimserver:nvidia-driver","Value":"620.70.06"}]`, 0)
	useFakeAWS(t, binDir)
	t.Setenv("AWS_BAKED_LOG", logFile)
	root := bakedFloorRepo(t, "620.70.06")

	checkBakedAMI(root, 5*time.Second, func(string, ...any) {})

	log, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatalf("reading aws log: %v", err)
	}
	joined := string(log)
	if !strings.Contains(joined, "get-parameter") || !strings.Contains(joined, bakedAMISSMParam) {
		t.Errorf("aws log %q does not query the baked SSM parameter %s", joined, bakedAMISSMParam)
	}
	if !strings.Contains(joined, "describe-images") || !strings.Contains(joined, "ami-0123456789abcdef0") {
		t.Errorf("aws log %q does not describe the resolved AMI", joined)
	}
	if strings.Count(joined, bakedAMIRegion) < 2 {
		t.Errorf("aws log %q does not pass --region %s to both reads", joined, bakedAMIRegion)
	}
}

// TestRunEmitsBakedAMIWarning proves the advisory is wired into the run
// pipeline: with Options.CheckBakedAMI enabled, a stale baked AMI surfaces on the
// injected Warn sink during run().
func TestRunEmitsBakedAMIWarning(t *testing.T) {
	binDir := t.TempDir()
	fakeBakedAWS(t, binDir, "ami-0123456789abcdef0", 0,
		`[{"Key":"strimserver:nvidia-driver","Value":"595.71.05"}]`, 0)
	useFakeAWS(t, binDir)

	e := newE2EApp(t, e2eConsole, "", nil)
	e.opts.Root = bakedFloorRepo(t, "620.70.06")
	e.opts.CheckBakedAMI = true
	e.opts.NativeToolTimeout = 5 * time.Second

	if err := run(e.opts, e.cache, e.resolvers, nil, e.extractors, e.classifier); err != nil {
		t.Fatalf("run: %v", err)
	}
	if !strings.Contains(strings.Join(*e.warns, "\n"), bakedAMIStaleWarningID) {
		t.Errorf("run warnings %v do not contain %s", *e.warns, bakedAMIStaleWarningID)
	}
}
