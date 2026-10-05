import commonjs from "@rollup/plugin-commonjs";
import nodeResolve from "@rollup/plugin-node-resolve";
import typescript from "@rollup/plugin-typescript";

const sdPlugin = "com.chroniccmposer.strimserver.sdPlugin";

// Injects build metadata (src/client/build-info.ts) into the bundle from the
// same env vars Bazel forwards to the action via --action_env. The GIT_TAG
// rules mirror scripts/gen-manifest.sh exactly so the manifest Version and the
// plugin's self-reported version can never disagree:
//   empty GIT_TAG (dev build) -> 0.0.0
//   vX.Y.Z                    -> X.Y.Z
//   anything malformed        -> hard failure
// GIT_COMMIT is optional; an empty value becomes "unknown".
function resolveVersion() {
   const tag = process.env.GIT_TAG ?? "";
   if (tag === "") return "0.0.0";
   const m = /^v([0-9]+)\.([0-9]+)\.([0-9]+)$/.exec(tag);
   if (!m) {
      throw new Error(
         `GIT_TAG='${tag}' is not a valid vX.Y.Z git tag ` +
         "(expected ^v[0-9]+\\.[0-9]+\\.[0-9]+$; leave empty for the dev default 0.0.0).",
      );
   }
   return `${m[1]}.${m[2]}.${m[3]}`;
}

function buildInfo() {
   const replacements = {
      __BUILD_VERSION__: resolveVersion(),
      __BUILD_COMMIT__: process.env.GIT_COMMIT || "unknown",
   };
   return {
      name: "build-info",
      transform(code) {
         return {
            code: code.replace(/__BUILD_VERSION__|__BUILD_COMMIT__/g, (token) => replacements[token]),
            map: null,
         };
      },
   };
}

export default {
  input: "src/plugin.ts",
  output: {
    file: `${sdPlugin}/bin/plugin.js`,
    format: "esm",
    sourcemap: true,
  },
  plugins: [
    buildInfo(),
    typescript({ tsconfig: "./tsconfig.json" }),
    nodeResolve({ browser: false, exportConditions: ["node"] }),
    commonjs(),
  ],
};
