// Build metadata injected by rollup.config.mjs at bundle time. The literal
// tokens below are replaced with the GIT_TAG-derived version and GIT_COMMIT;
// in the source tree (tsc, unit tests) they intentionally remain unexpanded.
export const BUILD_VERSION: string = "__BUILD_VERSION__";
export const BUILD_COMMIT: string = "__BUILD_COMMIT__";
