import assert from "node:assert/strict";
import { test } from "node:test";

import { formatBuild, isDevVersion, parseSemver, shortCommit, versionMismatch } from "./version.ts";

test("parseSemver parses bare X.Y.Z", () => {
   assert.deepEqual(parseSemver("1.2.3"), { major: 1, minor: 2, patch: 3 });
   assert.deepEqual(parseSemver("0.0.0"), { major: 0, minor: 0, patch: 0 });
   assert.deepEqual(parseSemver("10.20.30"), { major: 10, minor: 20, patch: 30 });
});

test("parseSemver rejects non-semver input", () => {
   assert.equal(parseSemver("unknown"), null);
   assert.equal(parseSemver("v1.2.3"), null);
   assert.equal(parseSemver("1.2"), null);
   assert.equal(parseSemver("1.2.3.4"), null);
   assert.equal(parseSemver("1.2.3-rc1"), null);
   assert.equal(parseSemver("__BUILD_VERSION__"), null);
});

test("isDevVersion is true only for unknown and 0.0.0", () => {
   assert.equal(isDevVersion("unknown"), true);
   assert.equal(isDevVersion("0.0.0"), true);
   assert.equal(isDevVersion("1.2.3"), false);
   assert.equal(isDevVersion("0.0.1"), false);
});

test("versionMismatch is false for equal versions", () => {
   assert.equal(versionMismatch("1.2.3", "1.2.3"), false);
});

test("versionMismatch is true when major, minor, or patch differ", () => {
   assert.equal(versionMismatch("2.2.3", "1.2.3"), true);
   assert.equal(versionMismatch("1.3.3", "1.2.3"), true);
   assert.equal(versionMismatch("1.2.4", "1.2.3"), true);
});

test("versionMismatch is false when either side is dev or unknown", () => {
   assert.equal(versionMismatch("unknown", "1.2.3"), false);
   assert.equal(versionMismatch("1.2.3", "unknown"), false);
   assert.equal(versionMismatch("0.0.0", "1.2.3"), false);
   assert.equal(versionMismatch("1.2.3", "0.0.0"), false);
   assert.equal(versionMismatch("unknown", "unknown"), false);
});

test("shortCommit keeps the first 12 characters", () => {
   assert.equal(shortCommit("0123456789abcdef0123456789abcdef01234567"), "0123456789ab");
   assert.equal(shortCommit("abc"), "abc");
});

test("formatBuild renders version and short commit", () => {
   assert.equal(formatBuild("1.2.3", "abc123def4567890"), "1.2.3 (commit abc123def456)");
});
