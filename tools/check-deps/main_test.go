package main

import (
	"strings"
	"testing"
)

// TestRunRejectsNonPositiveMaxConcurrentFetches proves run() fails loudly
// before any work begins, so a zero-width worker pool can never deadlock; the
// guard must return before any goroutines spawn.
func TestRunRejectsNonPositiveMaxConcurrentFetches(t *testing.T) {
	e := newE2EApp(t, e2eConsole, "", nil)
	e.opts.MaxConcurrentFetches = 0
	err := run(e.opts, e.cache, e.resolvers, nil, e.extractors, e.classifier)
	if err == nil {
		t.Fatal("run() succeeded, want error for non-positive MaxConcurrentFetches")
	}
	if !strings.Contains(err.Error(), "MaxConcurrentFetches") {
		t.Errorf("error %q does not mention MaxConcurrentFetches", err)
	}
}
