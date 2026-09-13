package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sum(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func makeZip(t *testing.T, payload map[string][]byte) []byte {
	t.Helper()
	var b bytes.Buffer
	z := zip.NewWriter(&b)
	for p, b := range payload {
		f, e := z.Create(p)
		if e != nil {
			t.Fatal(e)
		}
		if _, e = f.Write(b); e != nil {
			t.Fatal(e)
		}
	}
	if e := z.Close(); e != nil {
		t.Fatal(e)
	}
	return b.Bytes()
}
func write(t *testing.T, p string, b []byte) {
	t.Helper()
	if e := os.MkdirAll(filepath.Dir(p), 0755); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(p, b, 0644); e != nil {
		t.Fatal(e)
	}
}

type fixture struct {
	m                         Manifest
	assets                    map[string][]byte
	files                     map[string][]byte
	root, prev, cache, bundle string
}

func setup(t *testing.T, full bool) fixture {
	t.Helper()
	dir := t.TempDir()
	f := fixture{m: Manifest{Schema: 1, Module: "MagicNet", Version: "v1.2.3", Arch: "arm64", BaseURL: "https://github.com/LIghtJUNction/MagicNet/releases/download/v1.2.3/"}, assets: map[string][]byte{}, files: map[string][]byte{}, root: filepath.Join(dir, "module"), prev: filepath.Join(dir, "old"), cache: filepath.Join(dir, "cache"), bundle: filepath.Join(dir, "bundle.zip")}
	for _, id := range []string{"sing-box", "jq", "webui"} {
		p := "bin/" + id
		if id == "webui" {
			p = "webroot/index.html"
		}
		b := []byte("verified-" + id)
		f.files[p] = b
		asset := makeZip(t, map[string][]byte{p: b})
		f.assets[id] = asset
		f.m.Components = append(f.m.Components, Component{ID: id, Version: sum(b), Asset: "MagicNet-component-" + id + "-arm64-fixture.zip", SHA256: sum(asset), Size: int64(len(asset)), Files: []File{{Path: p, SHA256: sum(b), Size: int64(len(b)), Mode: 0755}}})
	}
	payload := map[string][]byte{"module.prop": []byte("id=MagicNet\nversion=v1.2.3\n")}
	if full {
		for p, b := range f.files {
			payload[p] = b
		}
	}
	write(t, f.bundle, makeZip(t, payload))
	return f
}
func (f fixture) manager(t *testing.T, calls *int) manager {
	return manager{log: io.Discard, fetch: func(_ context.Context, _ Manifest, c Component, p string) error {
		*calls++
		return os.WriteFile(p, f.assets[c.ID], 0600)
	}}
}
func (f fixture) run(x manager) error {
	return x.install(context.Background(), f.m, f.root, f.prev, f.bundle, f.cache)
}
func checkFiles(t *testing.T, f fixture) {
	t.Helper()
	for _, c := range f.m.Components {
		if !filesOK(f.root, c) {
			t.Fatalf("component not installed: %s", c.ID)
		}
	}
}

func TestFullOffline(t *testing.T) {
	f := setup(t, true)
	calls := 0
	if e := f.run(f.manager(t, &calls)); e != nil {
		t.Fatal(e)
	}
	checkFiles(t, f)
	if calls != 0 {
		t.Fatal("full installation accessed network")
	}
	if _, e := os.Stat(f.cache); !os.IsNotExist(e) {
		t.Fatal("offline installation should not require a cache")
	}
}
func TestFreshAndRepeat(t *testing.T) {
	f := setup(t, false)
	calls := 0
	x := f.manager(t, &calls)
	if e := f.run(x); e != nil {
		t.Fatal(e)
	}
	checkFiles(t, f)
	if calls != 3 {
		t.Fatalf("want 3 downloads, got %d", calls)
	}
	if e := f.run(x); e != nil {
		t.Fatal(e)
	}
	if calls != 3 {
		t.Fatal("identical reinstall downloaded again")
	}
}
func TestLegacyReuseWithoutState(t *testing.T) {
	f := setup(t, false)
	for p, b := range f.files {
		write(t, filepath.Join(f.prev, p), b)
	}
	calls := 0
	if e := f.run(f.manager(t, &calls)); e != nil {
		t.Fatal(e)
	}
	checkFiles(t, f)
	if calls != 0 {
		t.Fatal("legacy installed bytes should be reused")
	}
}
func TestOnlyChangedComponentDownloads(t *testing.T) {
	f := setup(t, false)
	for p, b := range f.files {
		write(t, filepath.Join(f.prev, p), b)
	}
	write(t, filepath.Join(f.prev, "bin/jq"), []byte("older jq"))
	calls := 0
	if e := f.run(f.manager(t, &calls)); e != nil {
		t.Fatal(e)
	}
	if calls != 1 {
		t.Fatalf("want only changed component, got %d", calls)
	}
	checkFiles(t, f)
}
func TestCorruptInstalledUsesVerifiedCache(t *testing.T) {
	f := setup(t, false)
	calls := 0
	x := f.manager(t, &calls)
	if e := f.run(x); e != nil {
		t.Fatal(e)
	}
	write(t, filepath.Join(f.root, "bin/jq"), []byte("corrupt"))
	if e := f.run(x); e != nil {
		t.Fatal(e)
	}
	if calls != 3 {
		t.Fatal("verified cache should avoid re-download")
	}
	checkFiles(t, f)
}
func TestCorruptCacheRedownload(t *testing.T) {
	f := setup(t, false)
	calls := 0
	c := f.m.Components[0]
	write(t, filepath.Join(f.cache, c.SHA256+".zip"), []byte("corrupt"))
	if e := f.run(f.manager(t, &calls)); e != nil {
		t.Fatal(e)
	}
	if calls != 3 {
		t.Fatal(calls)
	}
	checkFiles(t, f)
}
func TestFailedDownloadDoesNotTouchExistingFiles(t *testing.T) {
	f := setup(t, false)
	for p := range f.files {
		write(t, filepath.Join(f.root, p), []byte("old bytes"))
	}
	x := manager{log: io.Discard, fetch: func(_ context.Context, _ Manifest, c Component, p string) error {
		if c.ID == "jq" {
			return errors.New("offline")
		}
		return os.WriteFile(p, f.assets[c.ID], 0600)
	}}
	if e := f.run(x); e == nil {
		t.Fatal("expected failure")
	}
	for p := range f.files {
		b, _ := os.ReadFile(filepath.Join(f.root, p))
		if string(b) != "old bytes" {
			t.Fatalf("partial update: %s", p)
		}
	}
}
func TestChecksumFailureDoesNotPublish(t *testing.T) {
	f := setup(t, false)
	calls := 0
	f.assets["jq"] = []byte("bad hash")
	if e := f.run(f.manager(t, &calls)); e == nil {
		t.Fatal("expected checksum failure")
	}
	if _, e := os.Stat(filepath.Join(f.root, "bin/sing-box")); !os.IsNotExist(e) {
		t.Fatal("partial component installation")
	}
}
func TestUserConfigurationUntouched(t *testing.T) {
	f := setup(t, true)
	p := filepath.Join(f.root, ".config/sing-box/config.json")
	write(t, p, []byte("private config"))
	calls := 0
	if e := f.run(f.manager(t, &calls)); e != nil {
		t.Fatal(e)
	}
	b, _ := os.ReadFile(p)
	if string(b) != "private config" {
		t.Fatal("user config modified")
	}
}
func TestUnsafeManifestRejectedBeforeDownload(t *testing.T) {
	for _, p := range []string{"../outside", "/outside", "bin/../../outside", "bin\\sing-box", "bin/magicnet-cli", ".config/sing-box/config.json"} {
		t.Run(p, func(t *testing.T) {
			f := setup(t, false)
			f.m.Components[0].Files[0].Path = p
			calls := 0
			if e := f.run(f.manager(t, &calls)); e == nil {
				t.Fatal("unsafe path accepted")
			}
			if calls != 0 {
				t.Fatal("download before validation")
			}
		})
	}
}
func TestWrongArchitectureAndDuplicateRejected(t *testing.T) {
	f := setup(t, false)
	f.m.Arch = "amd64"
	if f.m.validate() == nil {
		t.Fatal("wrong arch accepted")
	}
	f.m.Arch = "arm64"
	f.m.Components = append(f.m.Components, f.m.Components[0])
	if f.m.validate() == nil {
		t.Fatal("duplicate component accepted")
	}
}
func TestVersionMismatch(t *testing.T) {
	f := setup(t, false)
	f.m.Version = "v1.2.4"
	f.m.BaseURL = strings.Replace(f.m.BaseURL, "v1.2.3", "v1.2.4", 1)
	calls := 0
	if e := f.run(f.manager(t, &calls)); e == nil {
		t.Fatal("mismatched bundle accepted")
	}
	if calls != 0 {
		t.Fatal("network accessed")
	}
}
func TestDestinationSymlinkRefused(t *testing.T) {
	f := setup(t, true)
	outside := filepath.Join(t.TempDir(), "keep")
	write(t, outside, []byte("keep"))
	if e := os.MkdirAll(filepath.Join(f.root, "bin"), 0755); e != nil {
		t.Fatal(e)
	}
	if e := os.Symlink(outside, filepath.Join(f.root, "bin/jq")); e != nil {
		t.Fatal(e)
	}
	calls := 0
	if e := f.run(f.manager(t, &calls)); e == nil {
		t.Fatal("symlink destination accepted")
	}
	b, _ := os.ReadFile(outside)
	if string(b) != "keep" {
		t.Fatal("symlink target overwritten")
	}
	if _, e := os.Stat(filepath.Join(f.root, "bin/sing-box")); !os.IsNotExist(e) {
		t.Fatal("preflight modified files")
	}
}
func TestPromoteRollsBack(t *testing.T) {
	f := setup(t, true)
	stage := t.TempDir()
	for p, b := range f.files {
		write(t, filepath.Join(stage, p), b)
		write(t, filepath.Join(f.root, p), []byte("old"))
	}
	os.Remove(filepath.Join(stage, "bin/jq"))
	if e := promote(f.root, stage, f.m.Components); e == nil {
		t.Fatal("expected failure")
	}
	for p := range f.files {
		b, _ := os.ReadFile(filepath.Join(f.root, p))
		if string(b) != "old" {
			t.Fatalf("rollback failed: %s", p)
		}
	}
}
func TestArchiveTraversalAndExtraFiles(t *testing.T) {
	for _, extra := range []string{"../outside", "unexpected"} {
		t.Run(extra, func(t *testing.T) {
			f := setup(t, false)
			c := &f.m.Components[0]
			b := makeZip(t, map[string][]byte{"bin/sing-box": f.files["bin/sing-box"], extra: []byte("bad")})
			f.assets[c.ID] = b
			c.SHA256 = sum(b)
			c.Size = int64(len(b))
			calls := 0
			if e := f.run(f.manager(t, &calls)); e == nil {
				t.Fatal("unsafe archive accepted")
			}
		})
	}
}
func TestDownloadHTTPAndHashChecks(t *testing.T) {
	for _, body := range []string{"valid", "broken", "valid-but-long"} {
		t.Run(body, func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, body) }))
			defer s.Close()
			p := filepath.Join(t.TempDir(), "part")
			write(t, p, nil)
			c := Component{ID: "test", Size: 5, SHA256: sum([]byte("valid"))}
			e := download(context.Background(), s.Client(), s.URL, p, c, io.Discard)
			if (e == nil) != (body == "valid") {
				t.Fatalf("body=%s error=%v", body, e)
			}
		})
	}
}
func TestRedirectDowngradeBlocked(t *testing.T) {
	r, _ := http.NewRequest("GET", "http://example.invalid", nil)
	if httpClient().CheckRedirect(r, nil) == nil {
		t.Fatal("HTTPS downgrade allowed")
	}
}
func TestUnsafeCacheRefused(t *testing.T) {
	f := setup(t, false)
	outside := t.TempDir()
	if e := os.Symlink(outside, f.cache); e != nil {
		t.Fatal(e)
	}
	calls := 0
	if e := f.run(f.manager(t, &calls)); e == nil {
		t.Fatal("symlink cache accepted")
	}
	if calls != 0 {
		t.Fatal("download before cache validation")
	}
}
func TestOnlyOwnedOldCacheFilesPruned(t *testing.T) {
	f := setup(t, false)
	old := filepath.Join(f.cache, strings.Repeat("a", 64)+".zip")
	write(t, old, []byte("old"))
	other := filepath.Join(f.cache, "keep.txt")
	write(t, other, []byte("keep"))
	calls := 0
	if e := f.run(f.manager(t, &calls)); e != nil {
		t.Fatal(e)
	}
	if _, e := os.Stat(old); !os.IsNotExist(e) {
		t.Fatal("obsolete cache retained")
	}
	if _, e := os.Stat(other); e != nil {
		t.Fatal("unowned cache file removed")
	}
}

func TestNormalDownloadWhenRangeUnsupported(t *testing.T) {
	payload := []byte("verified bytes even when Range is unsupported")
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "" {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		_, _ = w.Write(payload)
	}))
	defer server.Close()
	dest := filepath.Join(t.TempDir(), "download")
	if err := os.WriteFile(dest, nil, 0600); err != nil {
		t.Fatal(err)
	}
	c := Component{ID: "sing-box", Asset: "payload.zip", SHA256: sum(payload), Size: int64(len(payload))}
	err := fetchWithClient(server.Client(), io.Discard)(context.Background(), Manifest{BaseURL: server.URL + "/"}, c, dest)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(dest)
	if !bytes.Equal(b, payload) {
		t.Fatal("download differs")
	}
}

func TestFullInstallCacheCleanupDoesNotFollowSymlink(t *testing.T) {
	outside := t.TempDir()
	name := strings.Repeat("a", 64) + ".zip"
	if e := os.WriteFile(filepath.Join(outside, name), []byte("keep"), 0600); e != nil {
		t.Fatal(e)
	}
	link := filepath.Join(t.TempDir(), "cache")
	if e := os.Symlink(outside, link); e != nil {
		t.Fatal(e)
	}
	pruneCache(link, Manifest{}, io.Discard)
	if _, e := os.Stat(filepath.Join(outside, name)); e != nil {
		t.Fatal("followed cache symlink", e)
	}
}

func TestCorruptMirrorFallsBackToVerifiedDirect(t *testing.T) {
	good := []byte("valid")
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/mirror/") {
			_, _ = w.Write([]byte("wrong"))
			return
		}
		if r.Header.Get("Range") != "" {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		_, _ = w.Write(good)
	}))
	defer server.Close()
	dest := filepath.Join(t.TempDir(), "part")
	write(t, dest, nil)
	c := Component{ID: "sing-box", Asset: "component.zip", SHA256: sum(good), Size: int64(len(good))}
	m := Manifest{BaseURL: server.URL + "/", Mirrors: []string{server.URL + "/mirror/"}}
	if e := fetchWithClient(server.Client(), io.Discard)(context.Background(), m, c, dest); e != nil {
		t.Fatal(e)
	}
	b, _ := os.ReadFile(dest)
	if !bytes.Equal(b, good) {
		t.Fatal("accepted corrupt mirror")
	}
}
