// Pure version-comparison helpers. Deliberately free of any @elgato/streamdeck
// (or other runtime) import so the module is unit-testable with `node --test`
// and safe to evaluate at import time.

/** First 12 characters of a git SHA; short enough to read, long enough to be unique. */
export function shortCommit(commit: string): string {
   return commit.slice(0, 12);
}

/** Parses a bare `X.Y.Z` semver, or null for anything else (`unknown`, tokens, suffixes). */
export function parseSemver(v: string): { major: number; minor: number; patch: number } | null {
   const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v);
   if (!m) return null;
   return { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]) };
}

/** Dev builds carry no meaningful version: `unknown` (unbuilt) or `0.0.0` (untagged). */
export function isDevVersion(v: string): boolean {
   return v === "unknown" || v === "0.0.0";
}

/**
 * True only when BOTH sides are real releases that disagree on major/minor/patch.
 * A dev/unknown side never mismatches: there is nothing to compare against.
 */
export function versionMismatch(plugin: string, server: string): boolean {
   if (isDevVersion(plugin) || isDevVersion(server)) return false;
   const p = parseSemver(plugin);
   const s = parseSemver(server);
   if (p === null || s === null) return false;
   return p.major !== s.major || p.minor !== s.minor || p.patch !== s.patch;
}

/** Human-readable build identity, e.g. `1.2.3 (commit abc123def456)`. */
export function formatBuild(version: string, commit: string): string {
   return `${version} (commit ${shortCommit(commit)})`;
}
