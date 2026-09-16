package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestStalledCachedRouteFallsBackAndCleansPartial(t *testing.T) {
	c, payload := part(t, "engine", "bin/sing-box", "verified content")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/mirror/") {
			_, _ = w.Write(payload)
			return
		}
		// Headers alone must not keep a stalled response alive indefinitely.
		w.Header().Set("Content-Length", "")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	cache := t.TempDir()
	o := options{client: server.Client(), CacheDir: cache, log: io.Discard,
		route: &routeHint{set: true, name: "direct"}, mirrors: []string{server.URL + "/mirror/"}, bodyIdleTimeout: 80 * time.Millisecond}
	o.client.Timeout = 3 * time.Second
	target := filepath.Join(cache, "verified.zip")
	if err := o.download(c, server.URL+"/component", target); err != nil {
		t.Fatal(err)
	}
	actual, err := os.ReadFile(target)
	if err != nil || !bytes.Equal(actual, payload) {
		t.Fatalf("invalid verified payload: %v", err)
	}
	if o.route.prefix != server.URL+"/mirror/" {
		t.Fatal("failed route was retained")
	}
	partials, err := filepath.Glob(filepath.Join(cache, ".download-*"))
	if err != nil || len(partials) != 0 {
		t.Fatalf("leaked partial downloads: %v %v", partials, err)
	}
}

func TestProgressResetsBodyIdleDeadline(t *testing.T) {
	payload := bytes.Repeat([]byte("abcdefgh"), 12)
	hash := sha256.Sum256(payload)
	c := component{ID: "test", Size: int64(len(payload)), SHA256: hex.EncodeToString(hash[:])}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, value := range []int{0, 1, 2, 3, 4, 5} {
			_, _ = w.Write(payload[value*16 : (value+1)*16])
			w.(http.Flusher).Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(30 * time.Millisecond):
			}
		}
	}))
	defer server.Close()
	o := options{client: server.Client(), CacheDir: t.TempDir(), log: io.Discard, bodyIdleTimeout: 120 * time.Millisecond}
	if err := o.downloadAttempt(c, server.URL, filepath.Join(o.CacheDir, "good")); err != nil {
		t.Fatal(err)
	}
}

func TestIdleDeadlineNeverPublishesTruncatedBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("part"))
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	o := options{client: server.Client(), CacheDir: t.TempDir(), log: io.Discard, bodyIdleTimeout: 50 * time.Millisecond}
	target := filepath.Join(o.CacheDir, "bad")
	if err := o.downloadAttempt(component{ID: "test", Size: 100, SHA256: strings.Repeat("0", 64)}, server.URL, target); err == nil {
		t.Fatal("stalled partial passed verification")
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("published incomplete download: %v", err)
	}
	entries, err := os.ReadDir(o.CacheDir)
	if err != nil || len(entries) != 0 {
		t.Fatalf("failed attempt leaked staging files: %v %v", entries, err)
	}
}
