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

// dedupe drops duplicate dependencies keyed by (category, name, source,
// version), keeping the first occurrence. Script groups (e.g. build.sh +
// publish.sh) declare the same pins, so each pin is reported exactly once. The
// identity deliberately includes Source so it matches cacheKey's (category,
// name, source, version) grouping: a "deduplicated" set and a "cached" set
// must mean the same thing, because distinct pins can share a name+version
// while coming from different sources (e.g. the same tool mirrored from two
// upstream locations).
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
