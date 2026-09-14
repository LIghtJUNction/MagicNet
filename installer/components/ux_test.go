package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestDownloadRouteIsReusedAcrossChangedComponents(t *testing.T) {
	a, payloadA := part(t, "a", "bin/a", "new-a")
	b, payloadB := part(t, "b", "bin/b", "new-b")
	payloads := map[string][]byte{
		"/" + a.Asset: payloadA,
		"/" + b.Asset: payloadB,
	}
	var calls atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		payload, ok := payloads[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(payload)
	}))
	defer server.Close()

	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(a, b), nil))
	o.Offline = false
	o.client = server.Client()
	o.baseURL = server.URL + "/"
	o.mirrors = []string{}
	if err := run(o); err != nil {
		t.Fatal(err)
	}
	// First component: one speed probe + one download. Second component reuses
	// the verified route directly, so it needs only the real download request.
	if calls.Load() != 3 {
		t.Fatalf("expected one route probe and two downloads, got %d requests", calls.Load())
	}
}

func TestDownloadProgressIsHumanReadable(t *testing.T) {
	var log bytes.Buffer
	p := progress{
		total: 2048,
		start: time.Now().Add(-time.Second),
		o:     options{log: &log},
		id:    "engine",
	}
	if _, err := p.Write(make([]byte, 2048)); err != nil {
		t.Fatal(err)
	}
	text := log.String()
	for _, want := range []string{"100%", "2.0 KiB/2.0 KiB", "KiB/s", "ETA 0s"} {
		if !strings.Contains(text, want) {
			t.Fatalf("progress output %q missing %q", text, want)
		}
	}
}
