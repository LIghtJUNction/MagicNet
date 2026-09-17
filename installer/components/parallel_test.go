package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func parallelFixture(id string, size int) (component, []byte) {
	payload := bytes.Repeat([]byte(id), (size+len(id)-1)/len(id))[:size]
	copy(payload, []byte("PK\x03\x04"))
	return component{ID: id, Size: int64(size), SHA256: fmt.Sprintf("%x", sha256.Sum256(payload))}, payload
}

func TestComponentDownloadsUseBoundedParallelism(t *testing.T) {
	const count = 6
	payloads := map[string][]byte{}
	components := make([]component, 0, count)
	for i := 0; i < count; i++ {
		id := fmt.Sprintf("part-%d", i)
		c, payload := parallelFixture(id, 64<<10)
		components = append(components, c)
		payloads["/"+id] = payload
	}
	var active, peak atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		current := active.Add(1)
		defer active.Add(-1)
		for previous := peak.Load(); current > previous; previous = peak.Load() {
			if peak.CompareAndSwap(previous, current) {
				break
			}
		}
		time.Sleep(60 * time.Millisecond)
		payload := payloads[r.URL.Path]
		w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
		_, _ = w.Write(payload)
	}))
	defer server.Close()

	cache := t.TempDir()
	var log bytes.Buffer
	o := options{client: server.Client(), CacheDir: cache, log: &log, mirrors: []string{},
		route: &routeHint{set: true, name: "GitHub", sampleSize: routeProbeBytes}}
	jobs := make([]componentDownload, 0, count)
	for _, c := range components {
		jobs = append(jobs, componentDownload{component: c, direct: server.URL + "/" + c.ID,
			destination: filepath.Join(cache, c.SHA256+".zip")})
	}
	if err := o.downloadComponents(jobs); err != nil {
		t.Fatal(err)
	}
	if got := peak.Load(); got < 2 || got > componentDownloadWorkers {
		t.Fatalf("unexpected component download concurrency: %d", got)
	}
	for _, c := range components {
		if !validFile(filepath.Join(cache, c.SHA256+".zip"), c.Size, c.SHA256) {
			t.Fatalf("component %s was not verified", c.ID)
		}
	}
	partials, _ := filepath.Glob(filepath.Join(cache, ".download-*"))
	if len(partials) != 0 {
		t.Fatalf("partial downloads survived: %v", partials)
	}
	if log.Len() == 0 {
		t.Fatal("parallel download logging disappeared")
	}
}

func TestComponentDownloadFailureStopsQueueAndCleansPartials(t *testing.T) {
	good, payload := parallelFixture("good", 32<<10)
	bad := good
	bad.ID = "bad"
	bad.SHA256 = fmt.Sprintf("%x", sha256.Sum256([]byte("different")))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(len(payload)))
		_, _ = io.Copy(w, bytes.NewReader(payload))
	}))
	defer server.Close()
	cache := t.TempDir()
	o := options{client: server.Client(), CacheDir: cache, log: io.Discard, mirrors: []string{},
		route: &routeHint{set: true, name: "GitHub", sampleSize: routeProbeBytes}}
	jobs := []componentDownload{
		{component: bad, direct: server.URL + "/bad", destination: filepath.Join(cache, "bad.zip")},
		{component: good, direct: server.URL + "/good", destination: filepath.Join(cache, "good.zip")},
	}
	if err := o.downloadComponents(jobs); err == nil {
		t.Fatal("checksum failure was hidden")
	}
	partials, _ := filepath.Glob(filepath.Join(cache, ".download-*"))
	if len(partials) != 0 {
		t.Fatalf("failed parallel download left partials: %v", partials)
	}
}
