package common

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// This file tests the shared HTTP client in client.go: the bounded response
// body size cap, the single rate-limit retry, and the no-retry path for
// non-rate-limit failures. Every request goes through a httptest server-backed
// client; backoff sleeps are recorded via the injectable Sleep hook instead of
// blocking.

// --- fetcher size cap ------------------------------------------------------

func TestFetchBytesRejectsOversizedBody(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("0123456789ABCDEF")) // 16 bytes
	}))
	defer ts.Close()

	f := &Fetcher{Client: ts.Client(), MaxBytes: 8}
	_, err := f.FetchBytes(ts.URL)
	if err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Errorf("oversized body: got err=%v, want one mentioning 'exceeds'", err)
	}
}

func TestFetchBytesAcceptsWithinLimit(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("small"))
	}))
	defer ts.Close()

	f := &Fetcher{Client: ts.Client(), MaxBytes: 1024}
	data, err := f.FetchBytes(ts.URL)
	if err != nil || string(data) != "small" {
		t.Errorf("within-limit body: data=%q err=%v", data, err)
	}
}

// --- fetcher retry and size-cap boundary -------------------------------------

// sleepRecorder implements the Fetcher.Sleep injection point, recording every
// backoff duration instead of blocking so tests can assert the retry schedule
// without real sleeps.
type sleepRecorder struct {
	calls []time.Duration
}

func (r *sleepRecorder) Sleep(d time.Duration) {
	r.calls = append(r.calls, d)
}

// newCountingServer serves the given statuses in order (the last one repeats)
// and counts every request it receives, so tests can assert exactly how many
// GETs FetchBytes issues.
func newCountingServer(statuses ...int) (*httptest.Server, *atomic.Int32) {
	if len(statuses) == 0 {
		panic("newCountingServer: at least one status is required")
	}
	var hits atomic.Int32
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := int(hits.Add(1)) - 1
		status := statuses[len(statuses)-1]
		if n < len(statuses) {
			status = statuses[n]
		}
		if status == http.StatusOK {
			w.Write([]byte("ok"))
			return
		}
		http.Error(w, http.StatusText(status), status)
	}))
	return ts, &hits
}

func TestFetchBytesRetriesRateLimitOnce(t *testing.T) {
	// First attempt is rate-limited; the single retry succeeds. This exercises
	// the attempt==0 backoff branch and the two-attempt loop bound.
	ts, hits := newCountingServer(http.StatusTooManyRequests, http.StatusOK)
	defer ts.Close()

	rec := &sleepRecorder{}
	f := &Fetcher{
		Client:     ts.Client(),
		MaxBytes:   1024,
		RetryDelay: 750 * time.Millisecond,
		Sleep:      rec.Sleep,
	}

	data, err := f.FetchBytes(ts.URL)
	if err != nil {
		t.Fatalf("rate-limited then 200: FetchBytes returned err=%v, want nil", err)
	}
	if string(data) != "ok" {
		t.Errorf("rate-limited then 200: data=%q, want %q", data, "ok")
	}
	if got := hits.Load(); got != 2 {
		t.Errorf("rate-limited then 200: server received %d requests, want exactly 2 (one retry)", got)
	}
	if len(rec.calls) != 1 || rec.calls[0] != f.RetryDelay {
		t.Errorf("rate-limited then 200: Sleep calls=%v, want exactly one call of %v", rec.calls, f.RetryDelay)
	}
}

func TestFetchBytesRateLimitTwiceFails(t *testing.T) {
	// Every attempt is rate-limited: the loop must stop after exactly two
	// attempts and report the failure instead of retrying again.
	ts, hits := newCountingServer(http.StatusTooManyRequests)
	defer ts.Close()

	rec := &sleepRecorder{}
	f := &Fetcher{
		Client:     ts.Client(),
		MaxBytes:   1024,
		RetryDelay: 750 * time.Millisecond,
		Sleep:      rec.Sleep,
	}

	_, err := f.FetchBytes(ts.URL)
	if err == nil {
		t.Fatal("two rate-limited attempts: FetchBytes returned nil err, want an error")
	}
	if got := hits.Load(); got != 2 {
		t.Errorf("two rate-limited attempts: server received %d requests, want exactly 2 (no third attempt)", got)
	}
	if len(rec.calls) != 1 || rec.calls[0] != f.RetryDelay {
		t.Errorf("two rate-limited attempts: Sleep calls=%v, want exactly one call of %v", rec.calls, f.RetryDelay)
	}
}

func TestFetchBytesNonRateLimitErrorNoRetry(t *testing.T) {
	// A 500 is not rate-limit: FetchBytes must report it immediately without
	// backing off or making a second request.
	ts, hits := newCountingServer(http.StatusInternalServerError)
	defer ts.Close()

	rec := &sleepRecorder{}
	f := &Fetcher{
		Client:     ts.Client(),
		MaxBytes:   1024,
		RetryDelay: 750 * time.Millisecond,
		Sleep:      rec.Sleep,
	}

	_, err := f.FetchBytes(ts.URL)
	if err == nil || !strings.Contains(err.Error(), "HTTP 500") {
		t.Errorf("HTTP 500: FetchBytes err=%v, want one mentioning %q", err, "HTTP 500")
	}
	if got := hits.Load(); got != 1 {
		t.Errorf("HTTP 500: server received %d requests, want exactly 1 (no retry on non-rate-limit)", got)
	}
	if len(rec.calls) != 0 {
		t.Errorf("HTTP 500: Sleep calls=%v, want none (no backoff for non-rate-limit errors)", rec.calls)
	}
}

func TestFetchBytesExactCapBoundary(t *testing.T) {
	// A body of exactly MaxBytes bytes must be accepted; one byte more must
	// fail loud. This pins the > (not >=) comparison at the size cap.
	body := "01234567" // 8 bytes
	tsExact := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(body))
	}))
	defer tsExact.Close()
	tsOver := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(body + "X")) // 9 bytes
	}))
	defer tsOver.Close()

	f := &Fetcher{Client: tsExact.Client(), MaxBytes: 8}
	data, err := f.FetchBytes(tsExact.URL)
	if err != nil || string(data) != body {
		t.Errorf("exactly MaxBytes bytes: data=%q err=%v, want body accepted without error", data, err)
	}

	fOver := &Fetcher{Client: tsOver.Client(), MaxBytes: 8}
	_, err = fOver.FetchBytes(tsOver.URL)
	if err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Errorf("MaxBytes+1 bytes: err=%v, want one mentioning 'exceeds'", err)
	}
}
