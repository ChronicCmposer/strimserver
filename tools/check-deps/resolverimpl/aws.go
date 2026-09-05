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
// resolver compares that pin to the current upstream id. The chain is:
// awscli SSM query primary, and unknown when it fails. The awscli primary is
// authoritative when credentials exist; a credential-less run reports unknown
// instead of crashing or inventing a value.

const (
	// dlamiSSMParam is the public SSM parameter the launch script used to float
	// on; the resolver queries it explicitly so check-deps can flag when the
	// pinned AMI has gone stale.
	dlamiSSMParam = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id"
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
// unknown when the query fails. The fetcher parameter is unused — retained
// only so the registration in main.go stays uniform with the other
// resolvers.
func DLAMIResolve(_ *common.Fetcher, timeout time.Duration) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		latestID, err := awscliDLAMIID(timeout)
		if err != nil {
			return common.VersionInfo{Err: err}
		}
		vi := common.VersionInfo{
			Version:  latestID,
			Metadata: map[string]string{},
			Infos:    []string{"resolved via aws ssm get-parameter"},
		}
		// Best-effort metadata: describe-images failures (a stale current id,
		// missing permissions, a transient API error) omit that AMI's metadata
		// rather than failing the resolution — the latest id itself is
		// authoritative from SSM.
		if dep.Version != "" {
			if name, created, err := awsDescribeImage(timeout, dep.Version); err == nil {
				vi.Metadata["current_name"] = name
				vi.Metadata["current_created"] = created
			}
		}
		if name, created, err := awsDescribeImage(timeout, latestID); err == nil {
			vi.Metadata["latest_name"] = name
			vi.Metadata["latest_created"] = created
			vi.Date = created
		}
		return vi
	}
}

// awscliDLAMIID shells out to the aws CLI to resolve the current DLAMI id
// from the public SSM parameter, relying on the default region from the
// user's ~/.aws/config. A missing binary, missing credentials, a timeout, or
// a nonzero exit all fail closed with an error; the resolver reports unknown
// (never a crash).
func awscliDLAMIID(timeout time.Duration) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "aws", "ssm", "get-parameter",
		"--name", dlamiSSMParam,
		"--query", "Parameter.Value",
		"--output", "text")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("aws ssm get-parameter failed: %w", err)
	}
	id, err := parseAWSCLISSMOutput(out)
	if err != nil {
		return "", fmt.Errorf("aws ssm get-parameter output unparseable: %w", err)
	}
	return id, nil
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
