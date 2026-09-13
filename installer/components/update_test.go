package main

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/json"
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

type rewriteTransport struct {
	base   http.RoundTripper
	origin *url.URL
}

func (r rewriteTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	q := req.Clone(req.Context())
	u := *q.URL
	q.URL = &u
	if q.URL.Host == "github.com" {
		q.URL.Scheme = r.origin.Scheme
		q.URL.Host = r.origin.Host
	}
	return r.base.RoundTrip(q)
}

type updaterFixture struct {
	engine       *updateEngine
	release      moduleRelease
	manifest     manifest
	payload      map[string][]byte
	mu           sync.Mutex
	calls        map[string]int
	notModified  int
	installCalls int
}

func updaterFixtureFor(t *testing.T) *updaterFixture {
	t.Helper()
	root := t.TempDir()
	f := &updaterFixture{payload: map[string][]byte{}, calls: map[string]int{}}
	e := newUpdateEngine()
	e.moduleDir = filepath.Join(root, "module")
	e.pendingDir = filepath.Join(root, "pending")
	e.stateDir = filepath.Join(root, "state")
	e.cacheDir = filepath.Join(root, "cache")
	e.log = io.Discard
	e.wifi = func(context.Context) bool { return true }
	e.mirrors = []string{}
	f.engine = e
	f.manifest = manifestFixture()
	f.manifest.Version = "v1.4.9"
	for _, id := range []string{"sing-box", "magicnet-cli", "magicnet-mcp-server"} {
		c, payload := part(t, "bin-"+id, "bin/"+id, "new-"+id)
		f.manifest.Components = append(f.manifest.Components, c)
		f.payload[c.Asset] = payload
	}
	raw, _ := json.Marshal(f.manifest)
	f.payload["components.json"] = raw
	f.payload["MagicNet-core.zip"] = zipFixture(t, map[string][]byte{"module.prop": []byte("id=MagicNet\nversion=v1.4.9\n"), "customize.sh": []byte("# trusted fixture"), "bin/magicnet-components": []byte("bootstrap fixture"), "components.json": raw})
	f.release = moduleRelease{Tag: "v1.4.9"}
	for _, name := range []string{"components.json", "MagicNet-core.zip"} {
		b := f.payload[name]
		f.release.Assets = append(f.release.Assets, releaseAsset{Name: name, URL: "https://github.com/" + updateRepository + "/releases/download/v1.4.9/" + name, Digest: fmt.Sprintf("sha256:%x", sha256.Sum256(b)), Size: int64(len(b))})
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.URL.Path == "/api" {
			if r.Header.Get("If-None-Match") == `"fixture"` {
				f.notModified++
				w.WriteHeader(304)
				return
			}
			w.Header().Set("ETag", `"fixture"`)
			_ = json.NewEncoder(w).Encode(f.release)
			return
		}
		name := filepath.Base(r.URL.Path)
		f.calls[name]++
		b, ok := f.payload[name]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(b)
	}))
	t.Cleanup(server.Close)
	origin, _ := url.Parse(server.URL)
	e.client = server.Client()
	e.client.Transport = meteredTransport{base: rewriteTransport{base: e.client.Transport, origin: origin}, bytes: &e.bytes}
	e.apiURL = server.URL + "/api"
	e.installer = func(ctx context.Context, archive string) error {
		f.installCalls++
		z, err := zip.OpenReader(archive)
		if err != nil {
			return err
		}
		defer z.Close()
		if err = validateUpdateCore(z, f.manifest); err != nil {
			return err
		}
		// A real manager stages the module; this fixture never executes payload code.
		prop, err := z.Open("module.prop")
		if err != nil {
			return err
		}
		defer prop.Close()
		b, _ := io.ReadAll(prop)
		writeFixture(t, filepath.Join(e.pendingDir, "module.prop"), b)
		return nil
	}
	writeFixture(t, filepath.Join(e.moduleDir, "module.prop"), []byte("id=MagicNet\nversion=v1.4.8\n"))
	writeFixture(t, filepath.Join(e.moduleDir, ".config/sing-box/config.json"), []byte("private configuration"))
	if err := e.init(); err != nil {
		t.Fatal(err)
	}
	return f
}
func (f *updaterFixture) installed(t *testing.T, except string) {
	for _, c := range f.manifest.Components {
		for _, p := range c.Files {
			if p.Path != except {
				writeFixture(t, filepath.Join(f.engine.moduleDir, p.Path), []byte("new-"+strings.TrimPrefix(p.Path, "bin/")))
			}
		}
	}
}
func TestUpdateCheckOnlyGetsManifestNotCoreOrComponents(t *testing.T) {
	f := updaterFixtureFor(t)
	f.installed(t, "")
	if err := f.engine.operation("check", "", false); err != nil {
		t.Fatal(err)
	}
	if f.calls["MagicNet-core.zip"] != 0 {
		t.Fatal("check downloaded the core")
	}
	for _, c := range f.manifest.Components {
		if f.calls[c.Asset] != 0 {
			t.Fatal("check downloaded component", c.ID)
		}
	}
	s, err := f.engine.status()
	if err != nil {
		t.Fatal(err)
	}
	if s.Phase != "available" || s.Plan == nil || len(s.Plan.Components) != 3 {
		t.Fatalf("bad plan %+v", s)
	}
	for _, c := range s.Plan.Components {
		if c.Source != "installed" {
			t.Fatal("unchanged bytes not reused")
		}
	}
}
func TestRepeatedCheckUsesETagAndManifestCache(t *testing.T) {
	f := updaterFixtureFor(t)
	for i := 0; i < 2; i++ {
		if err := f.engine.operation("check", "", false); err != nil {
			t.Fatal(err)
		}
	}
	if f.notModified != 1 || f.calls["components.json"] != 1 {
		t.Fatal("conditional cache not reused", f.notModified, f.calls)
	}
	s, _ := f.engine.status()
	if s.TransferredBytes != 0 {
		t.Fatal("304 check retransferred cached data", s.TransferredBytes)
	}
}
func TestSmartInstallerDownloadsOnlyChangedComponent(t *testing.T) {
	f := updaterFixtureFor(t)
	f.installed(t, "bin/sing-box")
	out := filepath.Join(t.TempDir(), "prepared.zip")
	if err := f.engine.operation("prepare", out, false); err != nil {
		t.Fatal(err)
	}
	for _, c := range f.manifest.Components {
		expected := 0
		if c.ID == "bin-sing-box" {
			expected = 1
		}
		if f.calls[c.Asset] != expected {
			t.Fatalf("component %s downloads=%d want=%d", c.ID, f.calls[c.Asset], expected)
		}
	}
	z, err := zip.OpenReader(out)
	if err != nil {
		t.Fatal(err)
	}
	defer z.Close()
	if err = validateUpdateCore(z, f.manifest); err != nil {
		t.Fatal(err)
	}
	for _, c := range f.manifest.Components {
		for _, p := range c.Files {
			r, err := z.Open(p.Path)
			if err != nil {
				t.Fatal(err)
			}
			b, _ := io.ReadAll(r)
			r.Close()
			if fmt.Sprintf("%x", sha256.Sum256(b)) != p.SHA256 {
				t.Fatal("hydrated payload differs")
			}
		}
	}
	if f.installCalls != 0 {
		t.Fatal("prepare recursively launched a manager")
	}
	assertContent(t, filepath.Join(f.engine.moduleDir, ".config/sing-box/config.json"), "private configuration")
	// Another explicit installation can be prepared entirely from caches/local files.
	if err = f.engine.operation("prepare", out, false); err != nil {
		t.Fatal(err)
	}
	if f.calls["MagicNet-core.zip"] != 1 {
		t.Fatal("core archive downloaded again")
	}
	for _, c := range f.manifest.Components {
		if f.calls[c.Asset] > 1 {
			t.Fatal("component downloaded again")
		}
	}
}
func TestAutomaticUpdateStagesAndNeverTouchesActiveModule(t *testing.T) {
	f := updaterFixtureFor(t)
	f.installed(t, "")
	if err := f.engine.configure(true, 24, true); err != nil {
		t.Fatal(err)
	}
	if err := f.engine.operation("apply", "", true); err != nil {
		t.Fatal(err)
	}
	s, _ := f.engine.status()
	if s.PendingVersion != "v1.4.9" || s.Phase != "pending_reboot" || f.installCalls != 1 {
		t.Fatalf("not pending %+v", s)
	}
	assertContent(t, filepath.Join(f.engine.moduleDir, "module.prop"), "id=MagicNet\nversion=v1.4.8\n")
	count := f.notModified
	if err := f.engine.operation("apply", "", true); err != nil {
		t.Fatal(err)
	}
	if f.installCalls != 1 || f.notModified != count {
		t.Fatal("pending update downloaded or installed again")
	}
}
func TestDisabledAutomaticUpdateIsNoOp(t *testing.T) {
	f := updaterFixtureFor(t)
	if err := f.engine.operation("apply", "", true); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 || f.installCalls != 0 {
		t.Fatal("disabled updater performed work")
	}
}
func TestWiFiOnlyDefersWithoutNetwork(t *testing.T) {
	f := updaterFixtureFor(t)
	f.engine.wifi = func(context.Context) bool { return false }
	if err := f.engine.operation("apply", "", false); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 || f.installCalls != 0 {
		t.Fatal("used cellular")
	}
	s, _ := f.engine.status()
	if s.Phase != "waiting_wifi" {
		t.Fatal(s.Phase)
	}
}
func TestManagerFailureDoesNotReportInstalled(t *testing.T) {
	f := updaterFixtureFor(t)
	f.installed(t, "")
	f.engine.installer = func(context.Context, string) error { return fmt.Errorf("fixture failure") }
	if err := f.engine.operation("apply", "", false); err == nil {
		t.Fatal("manager failure accepted")
	}
	s, _ := f.engine.status()
	if s.Phase != "error" || s.PendingVersion != "" || s.LastSuccess != 0 {
		t.Fatalf("false success %+v", s)
	}
	assertContent(t, filepath.Join(f.engine.moduleDir, ".config/sing-box/config.json"), "private configuration")
}
func TestFalseManagerSuccessRequiresStagingReceipt(t *testing.T) {
	f := updaterFixtureFor(t)
	f.installed(t, "")
	f.engine.installer = func(context.Context, string) error { return nil }
	if err := f.engine.operation("apply", "", false); err == nil {
		t.Fatal("missing receipt accepted")
	}
}
func TestUntrustedMetadataAndDowngradesFail(t *testing.T) {
	for _, bad := range []string{"digest", "tag", "url", "prerelease", "downgrade"} {
		t.Run(bad, func(t *testing.T) {
			f := updaterFixtureFor(t)
			switch bad {
			case "digest":
				f.release.Assets[0].Digest = ""
			case "tag":
				f.release.Tag = "magicnet-installer-v1.1.0"
			case "url":
				f.release.Assets[0].URL = "https://example.invalid/manifest"
			case "prerelease":
				f.release.Prerelease = true
			case "downgrade":
				writeFixture(t, filepath.Join(f.engine.moduleDir, "module.prop"), []byte("id=MagicNet\nversion=v9.0.0\n"))
			}
			if err := f.engine.operation("check", "", false); err == nil {
				t.Fatal("accepted", bad)
			}
			if f.installCalls != 0 {
				t.Fatal("untrusted data reached installer")
			}
		})
	}
}
func TestUpdateLockAndPrivateSymlinkPaths(t *testing.T) {
	f := updaterFixtureFor(t)
	lock, err := fileLock(filepath.Join(f.engine.stateDir, "operation.lock"))
	if err != nil {
		t.Fatal(err)
	}
	if err = f.engine.operation("check", "", false); err == nil {
		t.Fatal("parallel update accepted")
	}
	lock.Close()
	settings := filepath.Join(f.engine.stateDir, "settings.json")
	outside := filepath.Join(t.TempDir(), "keep")
	writeFixture(t, outside, []byte("keep"))
	if err = os.Symlink(outside, settings); err != nil {
		t.Fatal(err)
	}
	if err = f.engine.configure(true, 24, true); err == nil {
		t.Fatal("followed settings symlink")
	}
	assertContent(t, outside, "keep")
}
func TestScheduleBoundsBackoffAndClockCorrection(t *testing.T) {
	f := updaterFixtureFor(t)
	for _, h := range []int{-1, 0, 169, 999999} {
		if f.engine.configure(true, h, true) == nil {
			t.Fatal("accepted invalid interval", h)
		}
	}
	if retryDelay(1) != 15*time.Minute || retryDelay(99) != 4*time.Hour {
		t.Fatal("unbounded retry")
	}
	now := int64(1000000)
	s := updateStatus{Settings: updateSettings{Enabled: true, IntervalHours: 24}, LastAttempt: now - 3600}
	if nextDue(s, now) != now+23*3600 {
		t.Fatal("incorrect cadence")
	}
	s.LastAttempt = now + 86400
	if nextDue(s, now) != now {
		t.Fatal("clock rollback postponed indefinitely")
	}
	for text, want := range map[string]bool{"1.1.1.1 dev wlan0 src 192.168.1.2": true, "1.1.1.1 dev rmnet_data0": false, "1.1.1.1 dev magicnet0": false, "Wifi is enabled": false} {
		if wifiRoute(text) != want {
			t.Fatal("unsafe WiFi detection", text)
		}
	}
}
func TestDisabledWhilePreparingDoesNotInstall(t *testing.T) {
	f := updaterFixtureFor(t)
	f.installed(t, "")
	_ = f.engine.configure(true, 24, true)
	// Disabling at the second Wi-Fi observation must be respected. This emulates
	// settings changed while downloads were in flight without racing fixture maps.
	calls := 0
	f.engine.wifi = func(context.Context) bool {
		calls++
		if calls == 1 {
			_ = f.engine.configure(false, 24, true)
		}
		return true
	}
	if err := f.engine.operation("apply", "", true); err != nil {
		t.Fatal(err)
	}
	if f.installCalls != 0 {
		t.Fatal("disabled automatic install still ran")
	}
}
func TestResumeAndIgnoredRange(t *testing.T) {
	for _, resume := range []bool{true, false} {
		t.Run(fmt.Sprint(resume), func(t *testing.T) {
			c, payload := part(t, "bin-sing-box", "bin/sing-box", strings.Repeat("engine", 200))
			half := len(payload) / 2
			requested := ""
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requested = r.Header.Get("Range")
				if resume {
					w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", half, len(payload)-1, len(payload)))
					w.WriteHeader(206)
					_, _ = w.Write(payload[half:])
				} else {
					_, _ = w.Write(payload)
				}
			}))
			defer server.Close()
			root := t.TempDir()
			partial := filepath.Join(root, c.SHA256+".part")
			writeFixture(t, partial, payload[:half])
			o := options{CacheDir: root, client: server.Client(), ctx: context.Background(), log: io.Discard, mirrors: []string{}}
			dest := filepath.Join(root, "verified.zip")
			if err := o.download(c, server.URL+"/payload", dest); err != nil {
				t.Fatal(err)
			}
			if requested != fmt.Sprintf("bytes=%d-", half) {
				t.Fatal("did not resume", requested)
			}
			if !validFile(dest, c.Size, c.SHA256) {
				t.Fatal("resume produced wrong bytes")
			}
		})
	}
}
func TestInvalidResumeRangeAndBadContentAreRejected(t *testing.T) {
	c, payload := part(t, "bin-sing-box", "bin/sing-box", "engine")
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, c.SHA256+".part"), payload[:10])
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Range", "bytes 0-3/4")
		w.WriteHeader(206)
		_, _ = w.Write([]byte("oops"))
	}))
	defer server.Close()
	o := options{CacheDir: root, client: server.Client(), mirrors: []string{}, log: io.Discard}
	if err := o.download(c, server.URL+"/asset", filepath.Join(root, "verified.zip")); err == nil {
		t.Fatal("wrong Content-Range accepted")
	}
	if _, err := os.Stat(filepath.Join(root, "verified.zip")); !os.IsNotExist(err) {
		t.Fatal("bad partial promoted")
	}
}
