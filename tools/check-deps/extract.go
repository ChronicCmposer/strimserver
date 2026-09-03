package main

import "strimserver-check-deps/common"

// extractAll runs every extractor against the repository and aggregates the
// results. Extraction failures never abort the run: they surface as unknown
// records alongside the successful dependencies.
func extractAll(extractors []common.Extractor, root string) ([]common.Dependency, []common.ExtractionUnknown) {
	return common.AggregateExtract(extractors, func(ex common.Extractor) ([]common.Dependency, []common.ExtractionUnknown) {
		return ex(root)
	})
}

// dedupe drops duplicate dependencies keyed by common.DepIdentity (category,
// name, source, version, file), keeping the first occurrence. Because the
// identity includes File, the same pin declared in two different files is
// reported separately: per-tool pins from different scripts (e.g. build.sh +
// publish.sh) stay distinct, so two tools pinning the same qemu version do not
// collide. Only repeats within the same file collapse. The identity
// deliberately includes Source and File so it matches cacheKey's grouping: a
// "deduplicated" set and a "cached" set must mean the same thing, because
// distinct pins can share a name+version while coming from different sources
// (e.g. the same tool mirrored from two upstream locations) or files.
func dedupe(deps []common.Dependency) []common.Dependency {
	seen := make(map[common.DepKey]struct{})
	unique := make([]common.Dependency, 0, len(deps))
	for _, dep := range deps {
		key := common.DepIdentity(dep)
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		unique = append(unique, dep)
	}
	return unique
}
