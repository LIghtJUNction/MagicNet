package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
)

func writeFixture(t *testing.T, target string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, data, 0o644); err != nil {
		t.Fatal(err)
	}
}
func zipFixture(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	var out bytes.Buffer
	w := zip.NewWriter(&out)
	for name, data := range files {
		f, err := w.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = f.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}
func part(t *testing.T, id, name, value string) (component, []byte) {
	t.Helper()
	data := []byte(value)
	payload := zipFixture(t, map[string][]byte{name: data})
	sum := fmt.Sprintf("%x", sha256.Sum256(payload))
	return component{ID: id, SHA256: sum, Size: int64(len(payload)), Asset: "MagicNet-component-" + id + "-" + sum + ".zip",
		Files: []payloadFile{{Path: name, SHA256: fmt.Sprintf("%x", sha256.Sum256(data)), Size: int64(len(data)), Mode: 0o755}}}, payload
}
func manifestFixture(parts ...component) manifest {
	return manifest{Schema: 1, Module: "MagicNet", Version: "v1.4.8", Architecture: runtime.GOARCH, Repository: "LIghtJUNction/MagicNet", Components: parts}
}
func archiveFixture(t *testing.T, root string, m manifest, bundled map[string][]byte) string {
	t.Helper()
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	files := map[string][]byte{"components.json": raw}
	for name, data := range bundled {
		files[name] = data
	}
	target := filepath.Join(root, "module.zip")
	writeFixture(t, target, zipFixture(t, files))
	return target
}
func optionsFixture(t *testing.T, archive string) options {
	t.Helper()
	root := t.TempDir()
	return options{Archive: archive, ModuleDir: filepath.Join(root, "new"), PreviousDir: filepath.Join(root, "old"), CacheDir: filepath.Join(root, "cache"), Offline: true, mirrors: []string{}, log: io.Discard}
}
func assertContent(t *testing.T, name, value string) {
	t.Helper()
	got, err := os.ReadFile(name)
	if err != nil || string(got) != value {
		t.Fatalf("%s = %q (%v), want %q", name, got, err, value)
	}
}

func TestFullPackageNeedsNoNetwork(t *testing.T) {
	c, _ := part(t, "engine", "bin/sing-box", "engine")
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), map[string][]byte{"bin/sing-box": []byte("engine")}))
	if err := run(o); err != nil {
		t.Fatal(err)
	}
	assertContent(t, filepath.Join(o.ModuleDir, "bin/sing-box"), "engine")
	st, err := os.Stat(filepath.Join(o.ModuleDir, "bin/sing-box"))
	if err != nil || st.Mode().Perm() != 0o755 {
		t.Fatal("executable mode was not restored", err)
	}
	files, _ := filepath.Glob(filepath.Join(o.CacheDir, "*.zip"))
	if len(files) != 0 {
		t.Fatal("offline install unnecessarily cached payload archives")
	}
}
func TestUnchangedOldComponentIsReusedWithoutManifest(t *testing.T) {
	c, _ := part(t, "engine", "bin/sing-box", "same")
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), nil))
	writeFixture(t, filepath.Join(o.PreviousDir, "bin/sing-box"), []byte("same"))
	if err := run(o); err != nil {
		t.Fatal(err)
	}
	assertContent(t, filepath.Join(o.ModuleDir, "bin/sing-box"), "same")
}
func TestCorruptOldComponentUsesVerifiedCache(t *testing.T) {
	c, payload := part(t, "engine", "bin/sing-box", "good")
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), nil))
	writeFixture(t, filepath.Join(o.PreviousDir, "bin/sing-box"), []byte("evil"))
	writeFixture(t, filepath.Join(o.CacheDir, c.SHA256+".zip"), payload)
	if err := run(o); err != nil {
		t.Fatal(err)
	}
	assertContent(t, filepath.Join(o.ModuleDir, "bin/sing-box"), "good")
	assertContent(t, filepath.Join(o.PreviousDir, "bin/sing-box"), "evil")
}
func TestMissingSecondComponentLeavesOldInstallationUntouched(t *testing.T) {
	a, _ := part(t, "a", "bin/a", "new-a")
	b, _ := part(t, "b", "bin/b", "new-b")
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(a, b), map[string][]byte{"bin/a": []byte("new-a")}))
	writeFixture(t, filepath.Join(o.ModuleDir, "bin/a"), []byte("old-a"))
	writeFixture(t, filepath.Join(o.ModuleDir, "bin/b"), []byte("old-b"))
	if err := run(o); err == nil {
		t.Fatal("missing required component was accepted")
	}
	assertContent(t, filepath.Join(o.ModuleDir, "bin/a"), "old-a")
	assertContent(t, filepath.Join(o.ModuleDir, "bin/b"), "old-b")
}
func TestOnlyChangedComponentDownloads(t *testing.T) {
	a, _ := part(t, "a", "bin/a", "unchanged")
	b, payload := part(t, "b", "bin/b", "new")
	var calls atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/"+b.Asset {
			t.Errorf("unexpected request %s", r.URL.Path)
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
	writeFixture(t, filepath.Join(o.PreviousDir, "bin/a"), []byte("unchanged"))
	writeFixture(t, filepath.Join(o.PreviousDir, "bin/b"), []byte("old"))
	if err := run(o); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatalf("expected one small-component download without a probe, got %d", calls.Load())
	}
	// Reinstall from cached payloads/installed files must make zero further requests.
	if err := run(o); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatal("unchanged reinstall accessed network")
	}
}
func TestDownloadChecksumFailurePreservesInstalledFile(t *testing.T) {
	c, _ := part(t, "engine", "bin/sing-box", "good")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(bytes.Repeat([]byte("x"), int(c.Size))) }))
	defer server.Close()
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), nil))
	o.Offline = false
	o.client = server.Client()
	o.baseURL = server.URL + "/"
	writeFixture(t, filepath.Join(o.ModuleDir, "bin/sing-box"), []byte("old"))
	if err := run(o); err == nil {
		t.Fatal("tampered download was accepted")
	}
	assertContent(t, filepath.Join(o.ModuleDir, "bin/sing-box"), "old")
	if _, err := os.Stat(filepath.Join(o.CacheDir, c.SHA256+".zip")); !os.IsNotExist(err) {
		t.Fatal("invalid download published to cache")
	}
	partial, _ := filepath.Glob(filepath.Join(o.CacheDir, ".download-*"))
	if len(partial) > 0 {
		t.Fatal("partial downloads leaked")
	}
}
func TestTruncatedDownloadIsNotCached(t *testing.T) {
	c, _ := part(t, "engine", "bin/sing-box", "good")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(c.Size))
		_, _ = w.Write([]byte("short"))
	}))
	defer server.Close()
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), nil))
	o.Offline = false
	o.client = server.Client()
	o.baseURL = server.URL + "/"
	if err := run(o); err == nil {
		t.Fatal("truncated payload accepted")
	}
	if _, err := os.Stat(filepath.Join(o.CacheDir, c.SHA256+".zip")); !os.IsNotExist(err) {
		t.Fatal("partial cache exists")
	}
}
func TestWrongArchitectureFails(t *testing.T) {
	c, _ := part(t, "engine", "bin/sing-box", "engine")
	m := manifestFixture(c)
	m.Architecture = "not-this-architecture"
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), m, nil))
	if err := run(o); err == nil {
		t.Fatal("incompatible architecture accepted")
	}
}
func TestUnsafeManifestPathsFail(t *testing.T) {
	for _, name := range []string{"../outside", "/bin/root", "bin/../../escape", "bin\\evil", ".config/sing-box/config.json", "bin/magicnet-components"} {
		t.Run(name, func(t *testing.T) {
			c, _ := part(t, "engine", name, "bad")
			m := manifestFixture(c)
			if err := m.validate(); err == nil {
				t.Fatal("unsafe manifest accepted")
			}
		})
	}
}
func TestDuplicateOwnershipAndParentCollisionFail(t *testing.T) {
	a, _ := part(t, "a", "bin/a", "x")
	b := a
	b.ID = "b"
	b.Asset = "MagicNet-component-b-" + b.SHA256 + ".zip"
	if manifestFixture(a, b).validate() == nil {
		t.Fatal("duplicate file ownership accepted")
	}
	a, _ = part(t, "a", "webroot/a", "x")
	b, _ = part(t, "b", "webroot/a/b", "x")
	if manifestFixture(a, b).validate() == nil {
		t.Fatal("file/directory overlap accepted")
	}
}
func TestUnexpectedArchiveEntryFails(t *testing.T) {
	c, _ := part(t, "engine", "bin/sing-box", "good")
	payload := zipFixture(t, map[string][]byte{"bin/sing-box": []byte("good"), "../escape": []byte("bad")})
	c.SHA256 = fmt.Sprintf("%x", sha256.Sum256(payload))
	c.Size = int64(len(payload))
	c.Asset = "MagicNet-component-" + c.ID + "-" + c.SHA256 + ".zip"
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), nil))
	writeFixture(t, filepath.Join(o.CacheDir, c.SHA256+".zip"), payload)
	if err := run(o); err == nil {
		t.Fatal("unsafe payload accepted")
	}
}
func TestDestinationSymlinkFailsWithoutWritingOutside(t *testing.T) {
	c, _ := part(t, "engine", "bin/sing-box", "new")
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), map[string][]byte{"bin/sing-box": []byte("new")}))
	outside := t.TempDir()
	writeFixture(t, filepath.Join(outside, "sing-box"), []byte("outside"))
	if err := os.MkdirAll(o.ModuleDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(o.ModuleDir, "bin")); err != nil {
		t.Fatal(err)
	}
	if err := run(o); err == nil {
		t.Fatal("symlink destination accepted")
	}
	assertContent(t, filepath.Join(outside, "sing-box"), "outside")
}
func TestCorruptBundledPayloadFails(t *testing.T) {
	c, _ := part(t, "engine", "bin/sing-box", "good")
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), map[string][]byte{"bin/sing-box": []byte("evil")}))
	if err := run(o); err == nil {
		t.Fatal("corrupt offline payload accepted")
	}
}
func TestPromotionRollsBackOnLaterFailure(t *testing.T) {
	root, stage := t.TempDir(), t.TempDir()
	writeFixture(t, filepath.Join(root, "bin/a"), []byte("old-a"))
	writeFixture(t, filepath.Join(stage, "bin/a"), []byte("new-a"))
	files := []payloadFile{{Path: "bin/a"}, {Path: "bin/missing"}}
	if err := promote(stage, root, files, nil); err == nil {
		t.Fatal("expected promotion failure")
	}
	assertContent(t, filepath.Join(root, "bin/a"), "old-a")
}
func TestObsoleteManagedFilesAreRemovedButConfigSurvives(t *testing.T) {
	c, _ := part(t, "webui", "webroot/new.js", "new")
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), map[string][]byte{"webroot/new.js": []byte("new")}))
	old, _ := part(t, "old", "webroot/old.js", "old")
	old.Files = append(old.Files, payloadFile{Path: ".config/sing-box/config.json"})
	raw, _ := json.Marshal(manifestFixture(old))
	writeFixture(t, filepath.Join(o.ModuleDir, "components.installed.json"), raw)
	writeFixture(t, filepath.Join(o.ModuleDir, "webroot/old.js"), []byte("old"))
	writeFixture(t, filepath.Join(o.ModuleDir, ".config/sing-box/config.json"), []byte("private config"))
	if err := run(o); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(o.ModuleDir, "webroot/old.js")); !os.IsNotExist(err) {
		t.Fatal("obsolete managed file remains")
	}
	assertContent(t, filepath.Join(o.ModuleDir, ".config/sing-box/config.json"), "private config")
}
func TestMirrorFallbackAfterDirectFailure(t *testing.T) {
	c, payload := part(t, "engine", "bin/sing-box", "good")
	var mirrorCalls atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/mirror/") {
			mirrorCalls.Add(1)
			_, _ = w.Write(payload)
			return
		}
		http.Error(w, "unavailable", 503)
	}))
	defer server.Close()
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), nil))
	o.Offline = false
	o.client = server.Client()
	o.baseURL = server.URL + "/"
	o.mirrors = []string{server.URL + "/mirror/"}
	if err := run(o); err != nil {
		t.Fatal(err)
	}
	if mirrorCalls.Load() != 1 {
		t.Fatal("small mirrored component should download once without a redundant probe")
	}
}

func TestAndroidBootstrapDoesNotDependOnLibcDNS(t *testing.T) {
	r := bootstrapResolver("android")
	if r == nil || !r.PreferGo || r.Dial == nil {
		t.Fatal("pure-Go Android download cannot resolve host names without a DNS transport")
	}
	if bootstrapResolver("linux") != nil {
		t.Fatal("host tests should retain native DNS")
	}
}
