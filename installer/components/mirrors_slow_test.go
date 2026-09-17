package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// A small component can still take longer than the probe budget on mobile.
// Partial measurement is not authentication; the real transfer checks the hash.
func TestSmallSlowProbeIsNotMistakenForChecksumFailure(t *testing.T) {
	c, payload := largeDownloadFixture(512 << 10)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
		_, _ = w.Write(payload[:8192])
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	o := options{client: server.Client(), probeTimeout: 60 * time.Millisecond}
	got := o.probe(c, server.URL, "slow-small", "")
	if got.speed <= 0 || got.bytes != 8192 || got.reason != "" {
		t.Fatalf("partial small sample incorrectly excluded: %+v", got)
	}
}

// Range sampling can time out while an ordinary GET remains usable. Preserve
// a bounded fallback queue rather than turning measurement failure into failure
// of every installation. Unknown probes must never claim measured throughput.
func TestProbeTimeoutStillAllowsVerifiedDownload(t *testing.T) {
	c, payload := largeDownloadFixture(512 << 10)
	var gets atomic.Int64
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("Range") != "" {
			<-r.Context().Done()
			return nil, r.Context().Err()
		}
		gets.Add(1)
		return &http.Response{StatusCode: http.StatusOK, ContentLength: c.Size,
			Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(payload))}, nil
	})}
	cache := t.TempDir()
	target := filepath.Join(cache, "verified")
	o := options{client: client, CacheDir: cache, log: io.Discard,
		mirrors: []string{"https://mirror.invalid/"}, probeTimeout: 20 * time.Millisecond}
	if err := o.download(c, "https://direct.invalid/asset", target); err != nil {
		t.Fatal(err)
	}
	if gets.Load() != 1 || !validFile(target, c.Size, c.SHA256) {
		t.Fatal("inconclusive probe prevented a valid full transfer")
	}
}
