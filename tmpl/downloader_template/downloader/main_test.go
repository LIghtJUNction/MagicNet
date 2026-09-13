package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func moduleZip(t *testing.T, id string, extra string) []byte {
	t.Helper()
	var b bytes.Buffer
	z := zip.NewWriter(&b)
	w, _ := z.Create("module.prop")
	fmt.Fprintf(w, "id=%s\n", id)
	if extra != "" {
		w, _ = z.Create(extra)
		w.Write([]byte("payload"))
	}
	if e := z.Close(); e != nil {
		t.Fatal(e)
	}
	return b.Bytes()
}

type transport func(*http.Request) (*http.Response, error)

func (f transport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestDownloadRoutes(t *testing.T) {
	for _, tc := range []struct {
		name    string
		direct  bool
		corrupt bool
	}{{"direct", true, false}, {"mirror fallback", false, false}, {"corrupt fastest mirror", false, true}} {
		t.Run(tc.name, func(t *testing.T) {
			data := moduleZip(t, "MagicNet", "")
			h := sha256.Sum256(data)
			a := asset{Name: "MagicNet.zip", URL: "https://github.com/owner/repo/releases/download/v1/MagicNet.zip", Digest: "sha256:" + hex.EncodeToString(h[:]), Size: int64(len(data))}
			metadata, _ := json.Marshal(release{Tag: "v1", Assets: []asset{a}})
			var mu sync.Mutex
			downloads := []string{}
			c := &http.Client{Transport: transport(func(r *http.Request) (*http.Response, error) {
				body := data
				status := 200
				host := r.URL.Host
				if host == "api.github.com" {
					body = metadata
				} else if host == "github.com" && !tc.direct {
					status = 503
				} else if host == "slow.example" {
					time.Sleep(20 * time.Millisecond)
				}
				if r.Header.Get("Range") == "" && host != "api.github.com" {
					mu.Lock()
					downloads = append(downloads, host)
					mu.Unlock()
					if host == "fast.example" && tc.corrupt {
						body = bytes.Repeat([]byte("x"), len(data))
					}
				}
				return &http.Response{StatusCode: status, Body: io.NopCloser(bytes.NewReader(body)), Header: make(http.Header)}, nil
			})}
			cfg := config{Repository: "owner/repo", Asset: "MagicNet.zip", ModuleID: "MagicNet", Proxies: []string{"https://slow.example/", "https://fast.example/"}, DirectMinKiB: 1}
			out := filepath.Join(t.TempDir(), "module.zip")
			if e := runWithClient(cfg, out, c); e != nil {
				t.Fatal(e)
			}
			got, _ := os.ReadFile(out)
			if !bytes.Equal(got, data) {
				t.Fatal("wrong output")
			}
			if tc.direct && (len(downloads) != 1 || downloads[0] != "github.com") {
				t.Fatal(downloads)
			}
			if tc.corrupt && downloads[len(downloads)-1] != "slow.example" {
				t.Fatal(downloads)
			}
		})
	}
}
func TestArchiveValidation(t *testing.T) {
	for _, tc := range []struct {
		name, id, entry string
		bad             bool
	}{{"valid", "MagicNet", "", false}, {"wrong id", "Other", "", true}, {"traversal", "MagicNet", "../escape", true}, {"absolute", "MagicNet", "/escape", true}, {"duplicate", "MagicNet", "module.prop", true}} {
		t.Run(tc.name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "a.zip")
			os.WriteFile(p, moduleZip(t, tc.id, tc.entry), 0600)
			e := checkZip(p, "MagicNet")
			if (e != nil) != tc.bad {
				t.Fatal(e)
			}
		})
	}
}
func TestInvalidLocalHeader(t *testing.T) {
	b := moduleZip(t, "MagicNet", "")
	b[0] = 0
	p := filepath.Join(t.TempDir(), "a.zip")
	os.WriteFile(p, b, 0600)
	if checkZip(p, "MagicNet") == nil {
		t.Fatal("invalid local header accepted")
	}
}
func TestProbeRejectsHTML(t *testing.T) {
	c := &http.Client{Transport: transport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("<html>not a zip</html>"))}, nil
	})}
	if probe(context.Background(), c, "https://mirror.example").Speed != 0 {
		t.Fatal("HTML accepted")
	}
}
func TestMetadataCannotUseMirrors(t *testing.T) {
	c := &http.Client{Transport: transport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.github.com" {
			t.Fatal("metadata sent to mirror")
		}
		return &http.Response{StatusCode: 403, Body: io.NopCloser(strings.NewReader("limited"))}, nil
	})}
	if runWithClient(config{Repository: "owner/repo", Asset: "MagicNet.zip", ModuleID: "MagicNet", DirectMinKiB: 256}, filepath.Join(t.TempDir(), "a.zip"), c) == nil {
		t.Fatal("missing metadata accepted")
	}
}

func TestRangeFailureStillTriesFullDownload(t *testing.T) {
	data := moduleZip(t, "MagicNet", "")
	h := sha256.Sum256(data)
	a := asset{Name: "MagicNet.zip", URL: "https://github.com/owner/repo/releases/download/v1/MagicNet.zip", Digest: "sha256:" + hex.EncodeToString(h[:]), Size: int64(len(data))}
	meta, _ := json.Marshal(release{Tag: "v1", Assets: []asset{a}})
	c := &http.Client{Transport: transport(func(r *http.Request) (*http.Response, error) {
		b := data
		status := 200
		if r.URL.Host == "api.github.com" {
			b = meta
		} else if r.Header.Get("Range") != "" {
			status = 416
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(bytes.NewReader(b))}, nil
	})}
	cfg := config{Repository: "owner/repo", Asset: "MagicNet.zip", ModuleID: "MagicNet", DirectMinKiB: 256}
	if e := runWithClient(cfg, filepath.Join(t.TempDir(), "module.zip"), c); e != nil {
		t.Fatal(e)
	}
}
