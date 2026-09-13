package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type updateTransport struct {
	base   http.RoundTripper
	target *url.URL
}

func (r updateTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	q := req.Clone(req.Context())
	u := *req.URL
	q.URL = &u
	q.URL.Scheme = r.target.Scheme
	q.URL.Host = r.target.Host
	return r.base.RoundTrip(q)
}

type updateFixture struct {
	u     updater
	m     manifest
	rel   updateRelease
	blobs map[string][]byte
	hits  map[string]int
	mu    sync.Mutex
}

func newUpdateFixture(t *testing.T) *updateFixture {
	t.Helper()
	root := t.TempDir()
	f := &updateFixture{blobs: map[string][]byte{}, hits: map[string]int{}}
	a, ab := part(t, "bin-sing-box", "bin/sing-box", "unchanged-engine")
	b, bb := part(t, "bin-jq", "bin/jq", "new-jq")
	f.m = manifestFixture(a, b)
	f.rel = updateRelease{Tag: f.m.Version}
	add := func(name string, data []byte) {
		f.blobs[name] = data
		f.rel.Assets = append(f.rel.Assets, updateAsset{Name: name, URL: "https://github.com/" + updateRepository + "/releases/download/" + f.m.Version + "/" + name, Size: int64(len(data)), Digest: fmt.Sprintf("sha256:%x", sha256.Sum256(data))})
	}
	raw, _ := json.Marshal(f.m)
	add("components.json", raw)
	add(a.Asset, ab)
	add(b.Asset, bb)
	props := []byte("id=MagicNet\nversion=" + f.m.Version + "\n")
	add("MagicNet-core.zip", zipFixture(t, map[string][]byte{"components.json": raw, "module.prop": props}))
	padding := make([]byte, 32768)
	_, _ = rand.Read(padding)
	add("MagicNet-full.zip", zipFixture(t, map[string][]byte{"components.json": raw, "module.prop": props, "padding": padding, "bin/sing-box": []byte("unchanged-engine"), "bin/jq": []byte("new-jq")}))
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		name := filepath.Base(r.URL.Path)
		f.hits[name]++
		if name == "latest" {
			if r.Header.Get("If-None-Match") == `"fixture-v1"` {
				w.WriteHeader(304)
				return
			}
			w.Header().Set("ETag", `"fixture-v1"`)
			_ = json.NewEncoder(w).Encode(f.rel)
			return
		}
		data, ok := f.blobs[name]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(data)
	}))
	t.Cleanup(server.Close)
	target, _ := url.Parse(server.URL)
	c := server.Client()
	c.Transport = updateTransport{c.Transport, target}
	f.u = updater{o: options{ModuleDir: filepath.Join(root, "installed"), CacheDir: filepath.Join(root, "cache"), client: c, mirrors: []string{}, log: io.Discard}, state: filepath.Join(root, "state"), pending: filepath.Join(root, "pending"), now: func() time.Time { return time.Unix(2000000, 0) }, install: func(string) error { return errors.New("unexpected install") }}
	return f
}
func (f *updateFixture) hit(name string) int { f.mu.Lock(); defer f.mu.Unlock(); return f.hits[name] }
func (f *updateFixture) installed(t *testing.T, version string) {
	writeFixture(t, filepath.Join(f.u.o.ModuleDir, "module.prop"), []byte("id=MagicNet\nversion="+version+"\n"))
	writeFixture(t, filepath.Join(f.u.o.ModuleDir, "bin/sing-box"), []byte("unchanged-engine"))
	writeFixture(t, filepath.Join(f.u.o.ModuleDir, "bin/jq"), []byte("new-jq"))
}
func TestSmartCurrentHasNoPayloadOrProbeTraffic(t *testing.T) {
	f := newUpdateFixture(t)
	f.installed(t, f.m.Version)
	for i := 0; i < 2; i++ {
		p, e := f.u.plan()
		if e != nil {
			t.Fatal(e)
		}
		if p.Needed || p.DownloadBytes != 0 {
			t.Fatal(p)
		}
	}
	if f.hit("latest") != 2 || f.hit("components.json") != 1 {
		t.Fatal("ETag or manifest cache not reused")
	}
	for _, a := range f.rel.Assets {
		if a.Name != "components.json" && f.hit(a.Name) != 0 {
			t.Fatal("unchanged payload was requested", a.Name)
		}
	}
}
func TestSmartOnlyChangedComponentDownloads(t *testing.T) {
	f := newUpdateFixture(t)
	f.installed(t, "v1.4.7")
	writeFixture(t, filepath.Join(f.u.o.ModuleDir, "bin/jq"), []byte("old"))
	p, e := f.u.plan()
	if e != nil {
		t.Fatal(e)
	}
	if !p.Needed || p.Package != "core" {
		t.Fatal(p)
	}
	file, e := f.u.prepare(p)
	if e != nil {
		t.Fatal(e)
	}
	if e = verifyUpdateBundle(file, p); e != nil {
		t.Fatal(e)
	}
	if f.hit(f.m.Components[0].Asset) != 0 || f.hit(f.m.Components[1].Asset) == 0 {
		t.Fatal("download set differs from plan")
	}
	calls := f.hit(f.m.Components[1].Asset)
	if _, e = f.u.prepare(p); e != nil {
		t.Fatal(e)
	}
	if f.hit(f.m.Components[1].Asset) != calls {
		t.Fatal("verified cache redownloaded")
	}
	assertContent(t, filepath.Join(f.u.o.ModuleDir, "bin/jq"), "old")
}
func TestSmartUsesCheaperCachedFull(t *testing.T) {
	f := newUpdateFixture(t)
	a, e := releaseAsset(f.rel, "MagicNet-full.zip")
	if e != nil {
		t.Fatal(e)
	}
	writeFixture(t, filepath.Join(f.u.o.CacheDir, strings.TrimPrefix(a.Digest, "sha256:")+".zip"), f.blobs[a.Name])
	p, e := f.u.plan()
	if e != nil {
		t.Fatal(e)
	}
	if p.Package != "full" || p.DownloadBytes != 0 || !p.Needed {
		t.Fatal(p)
	}
	if _, e = f.u.prepare(p); e != nil {
		t.Fatal(e)
	}
	if f.hit(a.Name) != 0 {
		t.Fatal("cached full downloaded")
	}
}
func TestSmartRejectsCorruptManifestBeforePayloads(t *testing.T) {
	f := newUpdateFixture(t)
	f.mu.Lock()
	f.blobs["components.json"] = []byte(`{}`)
	f.mu.Unlock()
	if _, e := f.u.plan(); e == nil {
		t.Fatal("bad manifest accepted")
	}
	if f.hit("MagicNet-core.zip") != 0 {
		t.Fatal("downloaded before authentication")
	}
}
func TestSmartRejectsUntrustedAssetAndMissingDigest(t *testing.T) {
	for _, mutate := range []func(*updateAsset){func(a *updateAsset) { a.Digest = "" }, func(a *updateAsset) { a.URL = "http://github.com/file" }, func(a *updateAsset) { a.URL = strings.Replace(a.URL, "github.com", "mirror.invalid", 1) }, func(a *updateAsset) { a.URL += "?token=bad" }, func(a *updateAsset) { a.Size = -1 }} {
		f := newUpdateFixture(t)
		mutate(&f.rel.Assets[0])
		if _, e := f.u.plan(); e == nil {
			t.Fatal("untrusted metadata accepted")
		}
	}
}
func TestSmartRejectsInstallerTagsDraftsAndDowngrades(t *testing.T) {
	for _, change := range []func(*updateFixture){func(f *updateFixture) { f.rel.Tag = "magicnet-installer-v1.1.0" }, func(f *updateFixture) { f.rel.Draft = true }, func(f *updateFixture) { f.rel.Prerelease = true }, func(f *updateFixture) { f.installed(t, "v1.5.0") }} {
		f := newUpdateFixture(t)
		change(f)
		if _, e := f.u.plan(); e == nil {
			t.Fatal("invalid release accepted")
		}
	}
}
func TestSmartPendingReleaseIsNotInstalledAgain(t *testing.T) {
	f := newUpdateFixture(t)
	f.installed(t, "v1.4.7")
	writeFixture(t, filepath.Join(f.u.pending, "module.prop"), []byte("id=MagicNet\nversion="+f.m.Version+"\n"))
	writeFixture(t, filepath.Join(f.u.pending, "bin/sing-box"), []byte("unchanged-engine"))
	writeFixture(t, filepath.Join(f.u.pending, "bin/jq"), []byte("new-jq"))
	if e := f.u.perform(true); e != nil {
		t.Fatal(e)
	}
	s, e := f.u.status()
	if e != nil || s.Phase != "pending-reboot" || s.Plan.Needed {
		t.Fatal(s, e)
	}
	if f.hit("MagicNet-core.zip") != 0 {
		t.Fatal("pending update downloaded again")
	}
}
func TestSmartInstallationFailureDoesNotClaimSuccess(t *testing.T) {
	f := newUpdateFixture(t)
	f.installed(t, "v1.4.7")
	if e := f.u.perform(true); e == nil {
		t.Fatal("manager failure accepted")
	}
	s, e := f.u.status()
	if e != nil || s.Phase != "error" || s.Failures != 1 {
		t.Fatal(s, e)
	}
	if s.NextCheck != f.u.now().Unix()+3600 {
		t.Fatal("missing backoff")
	}
}
func TestSmartManagerMustReallyStageExpectedVersion(t *testing.T) {
	f := newUpdateFixture(t)
	f.installed(t, "v1.4.7")
	f.u.install = func(string) error { return nil }
	if e := f.u.perform(true); e == nil {
		t.Fatal("manager's empty success accepted")
	}
	f.u.install = func(string) error {
		writeFixture(t, filepath.Join(f.u.pending, "module.prop"), []byte("id=MagicNet\nversion="+f.m.Version+"\n"))
		return nil
	}
	if e := f.u.perform(true); e != nil {
		t.Fatal(e)
	}
	s, _ := f.u.status()
	if s.Phase != "pending-reboot" {
		t.Fatal(s)
	}
}
func TestSmartDownloadFailureNeverInvokesManager(t *testing.T) {
	f := newUpdateFixture(t)
	f.installed(t, "v1.4.7")
	writeFixture(t, filepath.Join(f.u.o.ModuleDir, "bin/jq"), []byte("old"))
	f.mu.Lock()
	f.blobs[f.m.Components[1].Asset] = []byte("broken")
	f.mu.Unlock()
	called := false
	f.u.install = func(string) error { called = true; return nil }
	if e := f.u.perform(true); e == nil || called {
		t.Fatal("bad payload reached manager", e)
	}
	assertContent(t, filepath.Join(f.u.o.ModuleDir, "bin/jq"), "old")
}
func TestSmartSettingsAndSchedule(t *testing.T) {
	f := newUpdateFixture(t)
	s, e := f.u.settings()
	if e != nil || s.Enabled || !s.WiFiOnly || s.IntervalHours != 24 {
		t.Fatal(s, e)
	}
	for _, hours := range []int{0, -1, 169} {
		s.IntervalHours = hours
		if s.validate() == nil {
			t.Fatal("invalid interval")
		}
	}
	s.IntervalHours = 24
	for failures, want := range []int64{24, 1, 2, 4, 8, 16, 24, 24} {
		if nextUpdate(100, s, failures) != 100+want*3600 {
			t.Fatal("bad retry schedule", failures)
		}
	}
	if e = f.u.daemon(); e != nil {
		t.Fatal("disabled daemon did not exit", e)
	}
	if f.hit("latest") != 0 {
		t.Fatal("disabled scheduler used network")
	}
}
func TestSmartMutualExclusionAndSymlinkState(t *testing.T) {
	f := newUpdateFixture(t)
	unlock, e := updateLock(f.u.state, "operation.lock")
	if e != nil {
		t.Fatal(e)
	}
	if e = f.u.perform(false); e == nil {
		t.Fatal("concurrent check accepted")
	}
	unlock()
	if f.hit("latest") != 0 {
		t.Fatal("concurrent operation used network")
	}
	outside := filepath.Join(t.TempDir(), "outside")
	writeFixture(t, outside, []byte("keep"))
	if e = os.Symlink(outside, filepath.Join(f.u.state, "settings.json")); e != nil {
		t.Fatal(e)
	}
	if e = saveUpdateJSON(filepath.Join(f.u.state, "settings.json"), defaultUpdateSettings()); e == nil {
		t.Fatal("symlink state accepted")
	}
	assertContent(t, outside, "keep")
}
func TestSmartRejectsBundleManifestMismatch(t *testing.T) {
	f := newUpdateFixture(t)
	p, e := f.u.plan()
	if e != nil {
		t.Fatal(e)
	}
	bad := filepath.Join(t.TempDir(), "bad.zip")
	writeFixture(t, bad, zipFixture(t, map[string][]byte{"module.prop": []byte("id=MagicNet\nversion=" + p.Version + "\n"), "components.json": []byte(`{}`)}))
	if verifyUpdateBundle(bad, p) == nil {
		t.Fatal("mismatched core accepted")
	}
}
func TestSmartNoMetadataFallbackAfterNetworkFailure(t *testing.T) {
	f := newUpdateFixture(t)
	f.installed(t, f.m.Version)
	if _, e := f.u.plan(); e != nil {
		t.Fatal(e)
	}
	f.u.api = "https://github.com/unavailable"
	if _, e := f.u.plan(); e == nil {
		t.Fatal("stale metadata substituted")
	}
}
func TestVersionOrdering(t *testing.T) {
	for _, v := range [][2]string{{"v1.10.0", "v1.9.9"}, {"v2.0.0", "v1.99.99"}, {"v1.0.1", "v1.0.0"}} {
		if !newerVersion(v[0], v[1]) || newerVersion(v[1], v[0]) {
			t.Fatal(v)
		}
	}
	if newerVersion("v1.0.0", "v1.0.0") || newerVersion("v99999999999999999999.0.0", "v1.0.0") {
		t.Fatal("bad version ordering")
	}
}
func TestSmartPreparedCoreUsesExistingOfflineBootstrap(t *testing.T) {
	f := newUpdateFixture(t)
	f.installed(t, "v1.4.7")
	writeFixture(t, filepath.Join(f.u.o.ModuleDir, "bin/jq"), []byte("old"))
	p, e := f.u.plan()
	if e != nil {
		t.Fatal(e)
	}
	file, e := f.u.prepare(p)
	if e != nil {
		t.Fatal(e)
	}
	o := f.u.o
	o.Archive = file
	o.PreviousDir = o.ModuleDir
	o.ModuleDir = filepath.Join(t.TempDir(), "next")
	o.Offline = true
	var log bytes.Buffer
	o.log = &log
	if e = run(o); e != nil {
		t.Fatal(e)
	}
	assertContent(t, filepath.Join(o.ModuleDir, "bin/sing-box"), "unchanged-engine")
	assertContent(t, filepath.Join(o.ModuleDir, "bin/jq"), "new-jq")
}

func TestSmartDoesNotReplaceAnotherPendingVersion(t *testing.T) {
	f := newUpdateFixture(t)
	writeFixture(t, filepath.Join(f.u.pending, "module.prop"), []byte("id=MagicNet\nversion=v9.0.0\n"))
	if e := f.u.perform(true); e == nil {
		t.Fatal("overwrote unrelated pending version")
	}
	if f.hit("MagicNet-core.zip") != 0 {
		t.Fatal("download before pending version check")
	}
	assertContent(t, filepath.Join(f.u.pending, "module.prop"), "id=MagicNet\nversion=v9.0.0\n")
}
