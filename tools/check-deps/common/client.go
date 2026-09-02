package common

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// This file owns the shared HTTP client. Every registry call goes through
// FetchBytes so a timeout and a bounded response body are guaranteed, and so
// rate-limit responses read as errors that resolvers convert into "unknown"
// instead of crashing the tool. A rate-limited request is retried once after a
// short backoff because the anonymous registry APIs (Docker Hub especially)
// throttle intermittently; a second failure is reported as-is.
//
// The Fetcher struct carries every knob as an injected field (client, retry
// sleep, warning sink) so tests can substitute a httptest server-backed client
// and a fake clock; every resolver is closure-bound to the fetcher it should
// reach through in the composition-root wiring.

const (
	httpTimeout         = 20 * time.Second
	maxResponseBytes    = 16 << 20
	userAgent           = "strimserver-check-deps"
	rateLimitRetryDelay = 750 * time.Millisecond
)

// Fetcher performs bounded, retrying GET requests. The zero value is not
// usable: build one with NewFetcher or populate every field explicitly.
type Fetcher struct {
	Client     *http.Client
	UserAgent  string
	MaxBytes   int64
	RetryDelay time.Duration
	// Sleep is the backoff between a rate-limited attempt and its retry;
	// injectable so tests avoid real sleeps.
	Sleep func(time.Duration)
	// Warn receives non-fatal warnings; injected so tests capture them.
	Warn func(string, ...any)
}

// NewFetcher wires the production defaults: a 20s-timeout client, the standard
// user agent, a 16MiB response cap, and a 750ms rate-limit backoff.
func NewFetcher(warn func(string, ...any)) *Fetcher {
	return &Fetcher{
		Client:     &http.Client{Timeout: httpTimeout},
		UserAgent:  userAgent,
		MaxBytes:   maxResponseBytes,
		RetryDelay: rateLimitRetryDelay,
		Sleep:      time.Sleep,
		Warn:       warn,
	}
}

// FetchBytes GETs rawURL and returns the response body. A rate-limited attempt
// (403/429) is retried exactly once after the configured backoff; a success or
// any other error returns immediately. The bounded two-attempt loop makes the
// single retry explicit: after the second attempt, whatever happened is
// reported as-is.
func (f *Fetcher) FetchBytes(rawURL string) ([]byte, error) {
	var data []byte
	var err error
	for attempt := 0; attempt < 2; attempt++ {
		data, err = f.fetchBytesOnce(rawURL)
		if err == nil || !isRateLimit(err) {
			return data, err
		}
		if attempt == 0 {
			f.Sleep(f.RetryDelay) // back off before the one retry
		}
	}
	// Both attempts were rate-limited; report the retry's failure as-is.
	return data, err
}

// fetchBytesOnce performs a single GET without retrying.
func (f *Fetcher) fetchBytesOnce(rawURL string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", f.UserAgent)
	resp, err := f.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusTooManyRequests {
		return nil, rateLimitError{
			status:    resp.StatusCode,
			remaining: resp.Header.Get("X-RateLimit-Remaining"),
		}
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d from %s", resp.StatusCode, rawURL)
	}
	// Read MaxBytes+1 so hitting the cap is detectable: a body larger than the
	// cap must fail loud rather than silently truncating a version list.
	data, err := io.ReadAll(io.LimitReader(resp.Body, f.MaxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > f.MaxBytes {
		return nil, fmt.Errorf("response from %s exceeds %d bytes", rawURL, f.MaxBytes)
	}
	return data, nil
}

// rateLimitError marks a 403/429 response so FetchBytes can retry it once
// without retrying unrelated failures.
type rateLimitError struct {
	status    int
	remaining string
}

func (e rateLimitError) Error() string {
	return fmt.Sprintf("HTTP %d (rate-limited): x-ratelimit-remaining=%s", e.status, e.remaining)
}

func isRateLimit(err error) bool {
	var rl rateLimitError
	return errors.As(err, &rl)
}
