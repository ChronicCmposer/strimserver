package main

import (
   "context"
   "net/http"
   "net/http/httptest"
   "strings"
   "testing"
   "time"

   "github.com/coder/websocket"
)

// TestWithBuildHeadersSetsHeaders covers the plain-response path: both build
// headers must be present on any response the middleware wraps, before the
// downstream handler ever writes a status.
func TestWithBuildHeadersSetsHeaders(t *testing.T) {
   handler := withBuildHeaders(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
      w.WriteHeader(http.StatusOK)
   }))

   rec := httptest.NewRecorder()
   handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/status", nil))

   if got := rec.Header().Get("X-Strimserver-Version"); got != Version {
      t.Errorf("X-Strimserver-Version = %q; want %q", got, Version)
   }
   if got := rec.Header().Get("X-Strimserver-Commit"); got != Commit {
      t.Errorf("X-Strimserver-Commit = %q; want %q", got, Commit)
   }
}

// TestWithBuildHeadersOnWebSocketUpgrade proves the middleware does not swallow
// the build headers on the 101: because it sets them on the untouched
// ResponseWriter's header map (rather than wrapping it), coder/websocket's
// Accept writes them onto the upgrade response too.
func TestWithBuildHeadersOnWebSocketUpgrade(t *testing.T) {
   server := httptest.NewServer(withBuildHeaders(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
      conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{ InsecureSkipVerify: true })
      if err != nil { return }
      _ = conn.Close(websocket.StatusNormalClosure, "")
   })))
   defer server.Close()

   ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
   defer cancel()

   conn, resp, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
   if err != nil { t.Fatalf("websocket.Dial returned unexpected error: %v", err) }
   defer func() { _ = conn.CloseNow() }()

   if got := resp.Header.Get("X-Strimserver-Version"); got != Version {
      t.Errorf("101 X-Strimserver-Version = %q; want %q", got, Version)
   }
   if got := resp.Header.Get("X-Strimserver-Commit"); got != Commit {
      t.Errorf("101 X-Strimserver-Commit = %q; want %q", got, Commit)
   }
}

func TestShortCommit(t *testing.T) {
   const fullSHA = "0123456789abcdef0123456789abcdef01234567"

   for _, tc := range []struct {
      name string
      in   string
      want string
   }{
      {name: "full sha truncates to twelve", in: fullSHA, want: "0123456789ab"},
      {name: "unknown passes through", in: "unknown", want: "unknown"},
      {name: "empty passes through", in: "", want: ""},
      {name: "exactly twelve passes through", in: "0123456789ab", want: "0123456789ab"},
   } {
      t.Run(tc.name, func(t *testing.T) {
         if got := shortCommit(tc.in); got != tc.want {
            t.Errorf("shortCommit(%q) = %q; want %q", tc.in, got, tc.want)
         }
      })
   }
}
