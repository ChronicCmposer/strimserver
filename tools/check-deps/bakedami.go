package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// This file owns the baked-AMI driver-floor advisory. The deploy design bakes an
// NVIDIA driver into an AMI with a CloudFormation Image Builder pipeline and
// publishes its id to a single SSM parameter; the launch path trusts that AMI.
// This check closes the loop: it reads the driver version the AMI was tagged
// with (strimserver:nvidia-driver) and compares it to the repository's one
// floor constant (NVIDIA_DRIVER_FLOOR in deploy/aws/lib/nvidia.sh). A stale
// baked AMI is advisory, never fatal: the check warns and lets the run proceed,
// exactly like the cache/ignore warnings.

const (
	// bakedAMISSMParam is the us-east-2 SSM parameter the Image Builder
	// pipeline publishes the latest baked AMI id to.
	bakedAMISSMParam = "/strimserver/ami/baked/latest"
	// bakedAMIRegion is the region the baked AMI and its parameter live in.
	bakedAMIRegion = "us-east-2"
	// bakedAMIDriverTagKey is the EC2 tag the Image Builder recipe writes with
	// the baked driver version as its value.
	bakedAMIDriverTagKey = "strimserver:nvidia-driver"
	// nvidiaFloorPath is the repository-relative source of truth for the
	// driver floor. It is read, never modified.
	nvidiaFloorPath = "deploy/aws/lib/nvidia.sh"
	// bakedAMIStaleWarningID is the stable advisory identifier emitted when
	// the baked AMI's driver tag is below the floor. T-id style keeps warnings
	// greppable without tying them to a line number.
	bakedAMIStaleWarningID = "T-stale-baked-ami"
)

// nvidiaFloorRe matches the one active floor assignment in lib/nvidia.sh.
// Double, single, and bare values are accepted; a line whose first non-space
// character is '#' is a comment and never matches because the regexp anchors on
// the variable name at the start of the line.
var nvidiaFloorRe = regexp.MustCompile(`(?m)^[ \t]*NVIDIA_DRIVER_FLOOR[ \t]*=[ \t]*(?:"([^"]*)"|'([^']*)'|([^\s#]+))`)

// bakedAMIIDRe matches a bare EC2 image id from the SSM read: the literal
// "ami-" prefix plus 8 or 17 hex digits.
var bakedAMIIDRe = regexp.MustCompile(`^ami-[0-9a-f]{8,17}$`)

// parseNvidiaDriverFloor extracts the active NVIDIA_DRIVER_FLOOR value from the
// shell library source. It is a boundary parser: an absent, empty, or
// commented-out floor is an error, never a silent empty string.
func parseNvidiaDriverFloor(src []byte) (string, error) {
	m := nvidiaFloorRe.FindSubmatch(src)
	if m == nil {
		return "", fmt.Errorf("no NVIDIA_DRIVER_FLOOR assignment found")
	}
	for _, group := range m[1:] {
		if value := strings.TrimSpace(string(group)); value != "" {
			return value, nil
		}
	}
	return "", fmt.Errorf("NVIDIA_DRIVER_FLOOR has an empty value")
}

// parseImageTagsOutput parses `aws ec2 describe-images --query Images[0].Tags
// --output json` into a key/value map. AWS prints "null" when the image has no
// tags, which is not an error: it is an untagged image, so an empty map is the
// honest result. Malformed JSON is an error.
func parseImageTagsOutput(data []byte) (map[string]string, error) {
	trimmed := strings.TrimSpace(string(data))
	tags := map[string]string{}
	if trimmed == "" || trimmed == "null" {
		return tags, nil
	}
	var entries []struct {
		Key   string `json:"Key"`
		Value string `json:"Value"`
	}
	if err := json.Unmarshal([]byte(trimmed), &entries); err != nil {
		return nil, fmt.Errorf("aws describe-images tags unparseable: %w", err)
	}
	for _, entry := range entries {
		if entry.Key != "" {
			tags[entry.Key] = entry.Value
		}
	}
	return tags, nil
}

// driverVersionCompare compares two dotted numeric versions component by
// component. It returns -1, 0, or 1 and whether both inputs were comparable; a
// non-numeric or empty component is incomparable (ok=false), never silently
// treated as zero. A shorter version that is a prefix of a longer one sorts
// first (620.70 < 620.70.06).
func driverVersionCompare(a, b string) (int, bool) {
	ac, ok := parseDriverVersion(a)
	if !ok {
		return 0, false
	}
	bc, ok := parseDriverVersion(b)
	if !ok {
		return 0, false
	}
	for i := 0; i < len(ac) && i < len(bc); i++ {
		switch {
		case ac[i] < bc[i]:
			return -1, true
		case ac[i] > bc[i]:
			return 1, true
		}
	}
	switch {
	case len(ac) < len(bc):
		return -1, true
	case len(ac) > len(bc):
		return 1, true
	}
	return 0, true
}

// parseDriverVersion splits a dotted numeric version into its components,
// rejecting empty or non-numeric components.
func parseDriverVersion(v string) ([]int, bool) {
	if v == "" {
		return nil, false
	}
	parts := strings.Split(v, ".")
	nums := make([]int, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			return nil, false
		}
		n, err := strconv.Atoi(part)
		if err != nil || n < 0 {
			return nil, false
		}
		nums = append(nums, n)
	}
	return nums, true
}

// checkBakedAMI resolves the baked AMI id from SSM, reads its driver tag, and
// warns when the tagged driver is below the repository's NVIDIA_DRIVER_FLOOR.
// Every "not applicable yet" path (missing floor, missing parameter, untagged
// image, unreadable tags, incomparable versions) is silent: the advisory only
// speaks when it has both a floor and a concrete below-floor tag.
func checkBakedAMI(root string, timeout time.Duration, warn func(string, ...any)) {
	if warn == nil {
		return
	}
	floorSrc, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(nvidiaFloorPath)))
	if err != nil {
		return
	}
	floor, err := parseNvidiaDriverFloor(floorSrc)
	if err != nil {
		return
	}
	id, err := awsBakedAMIID(timeout)
	if err != nil || id == "" {
		return
	}
	tags, err := awsImageTags(timeout, id)
	if err != nil {
		return
	}
	tag, ok := tags[bakedAMIDriverTagKey]
	if !ok || tag == "" {
		return
	}
	cmp, ok := driverVersionCompare(tag, floor)
	if !ok || cmp >= 0 {
		return
	}
	warn("%s: baked AMI %s in %s carries NVIDIA driver %s in tag %s, below the %s floor in %s; bump NVIDIA_DRIVER_FLOOR there and re-run the Image Builder pipeline so %s is refreshed",
		bakedAMIStaleWarningID, id, bakedAMIRegion, tag, bakedAMIDriverTagKey, floor, nvidiaFloorPath, bakedAMISSMParam)
}

// awsBakedAMIID resolves the single baked AMI id from the Image Builder SSM
// parameter. Any aws failure (missing binary, missing credentials, parameter
// not published) is an error; the caller treats it as not applicable.
func awsBakedAMIID(timeout time.Duration) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "aws", "ssm", "get-parameter",
		"--region", bakedAMIRegion,
		"--name", bakedAMISSMParam,
		"--query", "Parameter.Value",
		"--output", "text")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("aws ssm get-parameter failed for %s: %w", bakedAMISSMParam, err)
	}
	id := strings.TrimSpace(string(out))
	if !bakedAMIIDRe.MatchString(id) {
		return "", fmt.Errorf("aws ssm get-parameter output for %s is not a bare ami id: %q", bakedAMISSMParam, id)
	}
	return id, nil
}

// awsImageTags reads one image's EC2 tags. Any aws failure is an error; the
// caller treats it as not applicable.
func awsImageTags(timeout time.Duration, id string) (map[string]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "aws", "ec2", "describe-images",
		"--region", bakedAMIRegion,
		"--image-ids", id,
		"--query", "Images[0].Tags",
		"--output", "json")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("aws ec2 describe-images failed for %s: %w", id, err)
	}
	return parseImageTagsOutput(out)
}
