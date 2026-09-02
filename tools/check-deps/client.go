package main

import (
	"fmt"
	"io"
	"net/http"
	"time"
)

// This file owns the single shared HTTP client. Every registry call goes
// through fetchBytes so a timeout and a bounded response body are guaranteed,
// and so rate-limit responses read as errors that resolvers convert into
// "unknown" instead of crashing the tool. A rate-limited request is retried
// once after a short backoff because the anonymous registry APIs (Docker Hub
// especially) throttle intermittently; a second failure is reported as-is.

const (
	httpTimeout         = 20 * time.Second
	maxResponseBytes    = 16 << 20
	userAgent           = "strimserver-check-deps"
	rateLimitRetryDelay = 750 * time.Millisecond
)

var httpClient = &http.Client{Timeout: httpTimeout}

// fetchBytes GETs rawURL and returns the response body, failing fast on
// non-200 responses and on rate-limit status codes. Callers (the resolvers)
// are responsible for turning an error into an "unknown" result.
func fetchBytes(rawURL string) ([]byte, error) {
	for attempt := 0; ; attempt++ {
		data, err := fetchBytesOnce(rawURL)
		if err == nil || !isRateLimit(err) || attempt >= 1 {
			return data, err
		}
		time.Sleep(rateLimitRetryDelay)
	}
}

// fetchBytesOnce performs a single GET without retrying.
func fetchBytesOnce(rawURL string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	resp, err := httpClient.Do(req)
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
	return io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
}

// rateLimitError marks a 403/429 response so fetchBytes can retry it once
// without retrying unrelated failures.
type rateLimitError struct {
	status    int
	remaining string
}

func (e rateLimitError) Error() string {
	return fmt.Sprintf("HTTP %d (rate-limited): x-ratelimit-remaining=%s", e.status, e.remaining)
}

func isRateLimit(err error) bool {
	_, ok := err.(rateLimitError)
	return ok
}
