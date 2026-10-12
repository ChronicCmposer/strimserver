package resolverimpl

import (
	"fmt"
	"strings"

	"strimserver-check-deps/common"
)

// mbedTLS releases are tagged "mbedtls-3.6.7" (some mirrors use a leading v).
// normalizeMbedtlsTag strips the project prefix and an optional leading v so
// the result compares against the "3.6.7" the extractor recorded.
func normalizeMbedtlsTag(tag string) (string, error) {
	version := strings.TrimPrefix(tag, "mbedtls-")
	version = strings.TrimPrefix(version, "v")
	if version == "" {
		return "", fmt.Errorf("mbedtls tag %q carries no version", tag)
	}
	return version, nil
}

// parseMbedtlsRelease is the pure bytes->VersionInfo parser for an mbedTLS
// GitHub release body.
func parseMbedtlsRelease(data []byte) (common.VersionInfo, error) {
	vi, err := parseGitHubRelease(data)
	if err != nil {
		return common.VersionInfo{}, err
	}
	version, err := normalizeMbedtlsTag(vi.Version)
	if err != nil {
		return common.VersionInfo{}, err
	}
	vi.Version = version
	return vi, nil
}

// MbedtlsResolve builds the Mbed-TLS/mbedtls release resolver.
func MbedtlsResolve(f *common.Fetcher) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		return resolveGitHubTagged("Mbed-TLS", "mbedtls", parseMbedtlsRelease, normalizeMbedtlsTag, f)
	}
}
