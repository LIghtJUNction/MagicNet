package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func largeDownloadFixture(size int) (component, []byte) {
	payload := bytes.Repeat([]byte("x"), size)
	copy(payload, []byte("PK\x03\x04"))
	return component{ID: "sample", Size: int64(size), SHA256: fmt.Sprintf("%x", sha256.Sum256(payload))}, payload
}

func writeRange(w http.ResponseWriter, r *http.Request, payload []byte) []byte {
	if r.Header.Get("Range") == "" {
		w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
		return payload
	}
	var start, end int
	if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &end); err != nil || start != 0 || end >= len(payload) {
		http.Error(w, "bad range", http.StatusRequestedRangeNotSatisfiable)
		return nil
	}
	w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-%d/%d", end, len(payload)))
	w.Header().Set("Content-Length", fmt.Sprint(end+1))
	w.WriteHeader(http.StatusPartialContent)
	return payload[:end+1]
}

func TestDefaultMirrorCandidatesAreDistinctHTTPS(t *testing.T) {
	seen := map[string]bool{}
	if len(defaultMirrors()) < 7 || len(defaultMirrors()) > maxMirrorRoutes {
		t.Fatal("unexpected candidate pool size")
	}
	for _, raw := range defaultMirrors() {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Path != "/" || u.RawQuery != "" || u.Fragment != "" || seen[raw] {
			t.Fatalf("unsafe or duplicate built-in mirror %q", raw)
		}
		seen[raw] = true
	}
}

func TestProbeChecksRangeContentAndIdentity(t *testing.T) {
	c, payload := largeDownloadFixture(2 << 20)
	for _, name := range []string{"range", "ignore-range", "html", "wrong-length", "wrong-range", "truncated", "encoded", "forbidden"} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Range") != "bytes=0-1048575" || r.Header.Get("Accept-Encoding") != "identity" {
					t.Error("probe is not using its bounded identity-encoded sample")
				}
				switch name {
				case "range":
					_, _ = w.Write(writeRange(w, r, payload))
				case "ignore-range":
					w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
					_, _ = w.Write(payload)
				case "html":
					body := append([]byte("<html>"), payload[6:]...)
					_, _ = w.Write(body)
				case "wrong-length":
					_, _ = w.Write(payload[:16])
				case "wrong-range":
					w.Header().Set("Content-Range", fmt.Sprintf("bytes 1-1048576/%d", len(payload)))
					w.WriteHeader(206)
					_, _ = w.Write(payload[:1<<20])
				case "truncated":
					w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
					_, _ = w.Write(payload[:8192])
				case "encoded":
					w.Header().Set("Content-Encoding", "gzip")
					_, _ = w.Write(payload)
				default:
					http.Error(w, "restricted", http.StatusForbidden)
				}
			}))
			defer server.Close()
			o := options{client: server.Client(), log: io.Discard}
			got := o.probe(c, server.URL, "fixture", "")
			valid := name == "range" || name == "ignore-range"
			if valid && (got.speed <= 0 || got.bytes != routeProbeBytes) {
				t.Fatalf("valid sample rejected: %+v", got)
			}
			if !valid && got.speed != 0 {
				t.Fatalf("invalid sample ranked as usable: %+v", got)
			}
		})
	}
}

func TestTinyProbeRequiresWholePayloadChecksum(t *testing.T) {
	c, payload := largeDownloadFixture(8192)
	payload[20] ^= 1
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(payload)
	}))
	defer server.Close()
	got := (options{client: server.Client()}).probe(c, server.URL, "fixture", "")
	if got.speed != 0 || got.reason != "checksum mismatch" {
		t.Fatalf("tampered tiny ZIP admitted: %+v", got)
	}
}

func TestRoutesMeasureBeyondInitialBurst(t *testing.T) {
	c, payload := largeDownloadFixture(2 << 20)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sample := writeRange(w, r, payload)
		if sample == nil {
			return
		}
		if strings.HasPrefix(r.URL.Path, "/mirror/") {
			_, _ = w.Write(sample)
			return
		}
		// Old 64 KiB probes see only this burst and never inspect the mirror.
		_, _ = w.Write(sample[:65536])
		w.(http.Flusher).Flush()
		for start := 65536; start < len(sample); start += 65536 {
			select {
			case <-r.Context().Done():
				return
			case <-time.After(30 * time.Millisecond):
			}
			if _, err := w.Write(sample[start:min(start+65536, len(sample))]); err != nil {
				return
			}
			w.(http.Flusher).Flush()
		}
	}))
	defer server.Close()
	mirror := server.URL + "/mirror/"
	o := options{client: server.Client(), log: io.Discard, mirrors: []string{mirror}}
	routes := o.routes(c, server.URL+"/asset")
	if len(routes) != 2 || routes[0].prefix != mirror {
		t.Fatalf("initial burst won over sustained throughput: %+v", routes)
	}
}

func TestSmallVerifiedRouteDoesNotSuppressLargeAssetProbe(t *testing.T) {
	small, smallPayload := part(t, "small", "bin/small", "small content")
	large, largePayload := largeDownloadFixture(2 << 20)
	var largeProbes atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		payload := smallPayload
		if r.URL.Path == "/large" {
			payload = largePayload
			if r.Header.Get("Range") != "" {
				largeProbes.Add(1)
			}
		}
		_, _ = w.Write(writeRange(w, r, payload))
	}))
	defer server.Close()
	cache := t.TempDir()
	o := options{client: server.Client(), log: io.Discard, CacheDir: cache, route: &routeHint{}, mirrors: []string{}}
	if err := o.download(small, server.URL+"/small", filepath.Join(cache, "small")); err != nil {
		t.Fatal(err)
	}
	if err := o.download(large, server.URL+"/large", filepath.Join(cache, "large")); err != nil {
		t.Fatal(err)
	}
	if largeProbes.Load() == 0 {
		t.Fatal("a tiny cached success suppressed the large-asset throughput probe")
	}
}

func TestRouteHintExpiryAndSampleSize(t *testing.T) {
	c := component{Size: 2 << 20}
	r := &routeHint{set: true, verifiedAt: time.Now(), sampleSize: 1 << 20}
	if !r.usable(c) {
		t.Fatal("recent meaningful sample was discarded")
	}
	r.verifiedAt = time.Now().Add(-6 * time.Minute)
	if r.usable(c) {
		t.Fatal("stale route is still reusable")
	}
	r.verifiedAt = time.Now()
	r.sampleSize = 1024
	if r.usable(c) || !r.usable(component{Size: 512}) {
		t.Fatal("cache did not distinguish tiny and large assets")
	}
}

func TestMirrorProbePoolIsBoundedDeduplicatedAndRaceFree(t *testing.T) {
	c, payload := largeDownloadFixture(8192)
	var active, peak, calls atomic.Int64
	var log bytes.Buffer
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		current := active.Add(1)
		defer active.Add(-1)
		for previous := peak.Load(); current > previous; previous = peak.Load() {
			if peak.CompareAndSwap(previous, current) {
				break
			}
		}
		calls.Add(1)
		time.Sleep(10 * time.Millisecond)
		_, _ = w.Write(writeRange(w, r, payload))
	}))
	defer server.Close()
	o := options{client: server.Client(), log: &log}
	for i := 0; i < 24; i++ {
		prefix := fmt.Sprintf("%s/m%d/", server.URL, i)
		o.mirrors = append(o.mirrors, prefix, prefix, strings.TrimSuffix(prefix, "/"))
	}
	routes := o.rankRoutes(c, server.URL+"/asset", nil)
	if len(routes) != maxMirrorRoutes+1 || calls.Load() != int64(maxMirrorRoutes+1) {
		t.Fatalf("pool cap/deduplication failed: routes=%d calls=%d", len(routes), calls.Load())
	}
	if peak.Load() > routeProbeWorkers || peak.Load() < 2 {
		t.Fatalf("unexpected worker concurrency %d", peak.Load())
	}
	if strings.Count(log.String(), "[route]") != len(routes) {
		t.Fatal("probe logging was lost")
	}
}

func TestSlowBodySwitchesBeforeIdleDeadline(t *testing.T) {
	c, payload := largeDownloadFixture(2 << 20)
	var directCanceled atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/mirror/") {
			_, _ = w.Write(writeRange(w, r, payload))
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
		_, _ = w.Write(payload[:65536])
		w.(http.Flusher).Flush()
		for {
			select {
			case <-r.Context().Done():
				directCanceled.Store(true)
				return
			case <-time.After(10 * time.Millisecond):
				_, _ = w.Write(payload[:256])
				w.(http.Flusher).Flush()
			}
		}
	}))
	defer server.Close()
	cache := t.TempDir()
	mirror := server.URL + "/mirror/"
	o := options{client: server.Client(), CacheDir: cache, route: &routeHint{set: true, name: "GitHub"},
		mirrors: []string{mirror}, log: io.Discard, bodyIdleTimeout: 500 * time.Millisecond, slowWindow: 40 * time.Millisecond}
	o.client.Timeout = 2 * time.Second
	start := time.Now()
	target := filepath.Join(cache, "verified")
	if err := o.download(c, server.URL+"/asset", target); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) >= time.Second || !directCanceled.Load() || o.route.prefix != mirror {
		t.Fatal("trickling cached route was not replaced promptly")
	}
	if !validFile(target, c.Size, c.SHA256) {
		t.Fatal("fallback bytes not verified")
	}
	partials, _ := filepath.Glob(filepath.Join(cache, ".download-*"))
	if len(partials) != 0 {
		t.Fatal("failed partial survived")
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type delayedReader struct {
	payload []byte
	offset  int
}

func (r *delayedReader) Read(b []byte) (int, error) {
	if r.offset == len(r.payload) {
		return 0, io.EOF
	}
	size := len(b)
	if r.offset == 0 {
		size = min(size, 1024)
	}
	if r.offset == 1024 {
		time.Sleep(40 * time.Millisecond)
		size = min(size, 16)
	}
	n := copy(b[:size], r.payload[r.offset:])
	r.offset += n
	return n, nil
}

func TestSlowFallbackDoesNotRejectOnlyProgressingPath(t *testing.T) {
	c, payload := largeDownloadFixture(512 << 10)
	var directCalls atomic.Int64
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "mirror.invalid" {
			return &http.Response{StatusCode: 503, Body: io.NopCloser(strings.NewReader("no")), Header: make(http.Header)}, nil
		}
		directCalls.Add(1)
		return &http.Response{StatusCode: 200, ContentLength: c.Size,
			Body: io.NopCloser(&delayedReader{payload: payload}), Header: make(http.Header)}, nil
	})}
	cache := t.TempDir()
	o := options{client: client, CacheDir: cache, log: io.Discard, route: &routeHint{set: true},
		mirrors: []string{"https://mirror.invalid/"}, slowWindow: 20 * time.Millisecond}
	if err := o.download(c, "https://direct.invalid/asset", filepath.Join(cache, "verified")); err != nil {
		t.Fatal(err)
	}
	if directCalls.Load() != 2 {
		t.Fatalf("expected exactly one bounded soft-floor retry, got %d", directCalls.Load())
	}
	if !validFile(filepath.Join(cache, "verified"), c.Size, c.SHA256) {
		t.Fatal("slow fallback was not verified")
	}
	if o.route.set {
		t.Fatal("last-resort slow transfer became a sticky route hint")
	}
}

func TestProbeTimeoutRetainsMeasuredSlowCandidate(t *testing.T) {
	c, payload := largeDownloadFixture(2 << 20)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
		_, _ = w.Write(payload[:8192])
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	o := options{client: server.Client(), probeTimeout: 60 * time.Millisecond}
	got := o.probe(c, server.URL, "slow", "")
	if got.speed <= 0 || got.bytes != 8192 || got.elapsed > time.Second {
		t.Fatalf("bounded partial sample mishandled: %+v", got)
	}
}

func TestBadMirrorNeverPublishesUnverifiedBytes(t *testing.T) {
	c, payload := largeDownloadFixture(2 << 20)
	poisoned := append([]byte{}, payload...)
	poisoned[len(poisoned)-1] ^= 1 // Beyond the probe; full hash must still fail.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(writeRange(w, r, poisoned))
	}))
	defer server.Close()
	cache := t.TempDir()
	target := filepath.Join(cache, "verified")
	o := options{client: server.Client(), CacheDir: cache, log: io.Discard}
	if err := o.download(c, server.URL, target); err == nil {
		t.Fatal("fast probe bypassed full payload hash")
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatal("tampered payload published")
	}
}

func TestProbeDoesNotLeakWorkersAfterTimeout(t *testing.T) {
	c, _ := largeDownloadFixture(2 << 20)
	var active atomic.Int64
	o := options{probeTimeout: 20 * time.Millisecond, log: io.Discard}
	o.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		active.Add(1)
		defer active.Add(-1)
		<-r.Context().Done()
		return nil, context.DeadlineExceeded
	})}
	for i := 0; i < 8; i++ {
		o.mirrors = append(o.mirrors, fmt.Sprintf("https://m%d.invalid/", i))
	}
	got := o.rankRoutes(c, "https://github.com/asset", nil)
	if len(got) != 9 || active.Load() != 0 {
		t.Fatalf("timeout leaked workers or lost fallback routes: %d %d", len(got), active.Load())
	}
	for _, candidate := range got {
		if candidate.speed != 0 || !candidate.retryable || candidate.reason == "" {
			t.Fatalf("unknown probe throughput presented as success: %+v", candidate)
		}
	}
}
