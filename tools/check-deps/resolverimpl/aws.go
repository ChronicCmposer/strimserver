package resolverimpl

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"strimserver-check-deps/common"
)

// AWS DLAMI resolver. The launch script pins a concrete DLAMI id; this
// resolver compares that pin to the current upstream ids for both CPU
// architectures (x86_64 and arm64). The chain is: awscli SSM query primary,
// and unknown when both arch queries fail. The awscli primary is authoritative
// when credentials exist; a credential-less run reports unknown instead of
// crashing or inventing a value.

const (
	// dlamiSSMParam is the public x86_64 SSM parameter the launch script's
	// amd64 path floats on; the resolver queries it explicitly so check-deps
	// can flag when the pinned AMI has gone stale.
	dlamiSSMParam = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id"
	// dlamiSSMParamArm64 is the arm64 sibling parameter the launch script's
	// arm64 path floats on.
	dlamiSSMParamArm64 = "/aws/service/deeplearning/ami/arm64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id"
)

// amiIDRe matches an EC2 ami id: the literal "ami-" prefix plus 8 or 17 hex
// digits (older ids are 8, current ids are 17).
var amiIDRe = regexp.MustCompile(`ami-[0-9a-f]{8,17}`)

// parseAWSCLISSMOutput extracts the ami id from `aws ssm get-parameter
// --query Parameter.Value --output text` output: a single ami-... line with
// surrounding whitespace tolerated. Anything else — an error message, an
// empty line, or extra content — is a parse error, never a silent empty.
func parseAWSCLISSMOutput(data []byte) (string, error) {
	line := strings.TrimSpace(string(data))
	if line == "" {
		return "", errors.New("aws ssm output is empty")
	}
	if m := amiIDRe.FindString(line); m != line {
		return "", fmt.Errorf("aws ssm output %q is not a bare ami id", line)
	}
	return line, nil
}

// parseDescribeImagesOutput extracts the release Name and CreationDate from
// `aws ec2 describe-images --image-ids <id> --query
// 'Images[0].[Name,CreationDate]' --output text` output: a single
// tab-separated Name\tCreationDate line with surrounding whitespace tolerated
// (CreationDate is an ISO-8601 timestamp like 2026-08-06T12:00:00Z). Anything
// else — an empty line, fewer or more than two fields, or an empty field — is
// a parse error, never a silent empty.
func parseDescribeImagesOutput(data []byte) (name, created string, err error) {
	line := strings.TrimSpace(string(data))
	if line == "" {
		return "", "", errors.New("aws describe-images output is empty")
	}
	fields := strings.Split(line, "\t")
	if len(fields) != 2 {
		return "", "", fmt.Errorf("aws describe-images output %q is not Name\tCreationDate", line)
	}
	name = strings.TrimSpace(fields[0])
	created = strings.TrimSpace(fields[1])
	if name == "" || created == "" {
		return "", "", fmt.Errorf("aws describe-images output %q has an empty field", line)
	}
	return name, created, nil
}

// DLAMIResolve builds the resolver for the pinned AWS Deep Learning AMI
// (category "ami", name "dlami"). It shells out to the aws CLI and reports
// unknown when both architecture queries fail. The fetcher parameter is unused
// — retained only so the registration in main.go stays uniform with the other
// resolvers.
func DLAMIResolve(_ *common.Fetcher, timeout time.Duration) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		ids, err := awscliDLAMIID(timeout)
		if err != nil {
			return common.VersionInfo{Err: err}
		}
		vi := common.VersionInfo{
			Version:  primaryDLAMIID(ids),
			Metadata: map[string]string{},
			Infos:    []string{"resolved via aws ssm get-parameter"},
		}
		vi.Infos = appendArchQueryErrors(vi.Infos, ids)
		// Freshness: an AMI id does not encode its CPU architecture, so the
		// pin is current when it equals either family's latest id. Reporting
		// the pin itself keeps the classifier's string-equality freshness
		// check correct for both the amd64 and the arm64 launch path.
		if isCurrentDLAMIPin(dep.Version, ids) {
			vi.Version = dep.Version
		}
		// Best-effort metadata: describe-images failures (a stale current id,
		// missing permissions, a transient API error) omit that AMI's metadata
		// rather than failing the resolution — the latest ids themselves are
		// authoritative from SSM. The x86_64 latest keeps the original
		// latest_name/latest_created keys; the arm64 latest is surfaced under
		// latest_arm64_name/latest_arm64_created. Date pairs with the reported
		// Version, whichever family it came from.
		if dep.Version != "" {
			if name, created, err := awsDescribeImage(timeout, dep.Version); err == nil {
				vi.Metadata["current_name"] = name
				vi.Metadata["current_created"] = created
			}
		}
		if ids.latestX86 != "" {
			if name, created, err := awsDescribeImage(timeout, ids.latestX86); err == nil {
				vi.Metadata["latest_name"] = name
				vi.Metadata["latest_created"] = created
				if vi.Version == ids.latestX86 {
					vi.Date = created
				}
			}
		}
		if ids.latestArm64 != "" {
			if name, created, err := awsDescribeImage(timeout, ids.latestArm64); err == nil {
				vi.Metadata["latest_arm64_name"] = name
				vi.Metadata["latest_arm64_created"] = created
				if vi.Version == ids.latestArm64 {
					vi.Date = created
				}
			}
		}
		return vi
	}
}

// dlamiLatestIDs carries the freshly resolved DLAMI ids for both CPU
// architectures plus each family's query error (nil on success). It is the
// parsed boundary state for the dual-arch SSM resolution: one failing family
// never poisons the other, and the errors stay attached so the resolver can
// report what could not be resolved.
type dlamiLatestIDs struct {
	latestX86   string
	x86Err      error
	latestArm64 string
	arm64Err    error
}

// awscliDLAMIID shells out to the aws CLI to resolve the current DLAMI ids for
// both CPU architectures from the public SSM parameters, relying on the
// default region from the user's ~/.aws/config. A missing binary, missing
// credentials, a timeout, or a nonzero exit all fail closed with an error;
// both queries must fail for the resolution to be unknown, and a single-arch
// failure is carried in the result so the caller reports the other arch's id
// with the error noted.
func awscliDLAMIID(timeout time.Duration) (dlamiLatestIDs, error) {
	x86ID, x86Err := awscliSSMParamID(timeout, dlamiSSMParam)
	arm64ID, arm64Err := awscliSSMParamID(timeout, dlamiSSMParamArm64)
	if x86Err != nil && arm64Err != nil {
		return dlamiLatestIDs{}, fmt.Errorf("aws ssm get-parameter failed for both x86_64 and arm64 (%v; %v)", x86Err, arm64Err)
	}
	return dlamiLatestIDs{latestX86: x86ID, x86Err: x86Err, latestArm64: arm64ID, arm64Err: arm64Err}, nil
}

// awscliSSMParamID shells out to the aws CLI to resolve one public SSM
// parameter's ami id, relying on the default region from the user's
// ~/.aws/config. A missing binary, missing credentials, a timeout, or a
// nonzero exit all fail closed with an error; the resolver reports unknown
// (never a crash).
func awscliSSMParamID(timeout time.Duration, param string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "aws", "ssm", "get-parameter",
		"--name", param,
		"--query", "Parameter.Value",
		"--output", "text")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("aws ssm get-parameter failed for %s: %w", param, err)
	}
	id, err := parseAWSCLISSMOutput(out)
	if err != nil {
		return "", fmt.Errorf("aws ssm get-parameter output for %s unparseable: %w", param, err)
	}
	return id, nil
}

// primaryDLAMIID returns the id to report as the latest when the pin is not
// current: the x86_64 id when resolved, else the arm64 id. The x86_64 family
// is the primary (the launch script's amd64 path), and the arm64 id is the
// fallback so an arm64-only resolution still reports a concrete latest.
func primaryDLAMIID(ids dlamiLatestIDs) string {
	if ids.latestX86 != "" {
		return ids.latestX86
	}
	return ids.latestArm64
}

// isCurrentDLAMIPin reports whether the pinned id is the current DLAMI for
// either CPU architecture. An AMI id does not encode its arch, so a pin that
// matches the x86_64 latest or the arm64 latest is current; a pin matching
// neither is stale. An empty pin (no id to compare) is never current.
func isCurrentDLAMIPin(pin string, ids dlamiLatestIDs) bool {
	return pin != "" && (pin == ids.latestX86 || pin == ids.latestArm64)
}

// appendArchQueryErrors appends one informational note per family whose SSM
// query failed, so a single-arch failure is reported alongside the other
// arch's resolved id instead of being silently dropped.
func appendArchQueryErrors(infos []string, ids dlamiLatestIDs) []string {
	if ids.x86Err != nil {
		infos = append(infos, fmt.Sprintf("x86_64 SSM query failed: %v", ids.x86Err))
	}
	if ids.arm64Err != nil {
		infos = append(infos, fmt.Sprintf("arm64 SSM query failed: %v", ids.arm64Err))
	}
	return infos
}

// awsDescribeImage shells out to the aws CLI to read one image's release Name
// and CreationDate, relying on the same default-region credentials as the SSM
// query. A missing binary, missing credentials, a timeout, or a nonzero exit
// all fail closed with an error. Callers treat the result as best-effort
// metadata and omit it on failure.
func awsDescribeImage(timeout time.Duration, id string) (name, created string, err error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "aws", "ec2", "describe-images",
		"--image-ids", id,
		"--query", "Images[0].[Name,CreationDate]",
		"--output", "text")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", "", fmt.Errorf("aws ec2 describe-images failed for %s: %w", id, err)
	}
	name, created, err = parseDescribeImagesOutput(out)
	if err != nil {
		return "", "", fmt.Errorf("aws ec2 describe-images output for %s unparseable: %w", id, err)
	}
	return name, created, nil
}
