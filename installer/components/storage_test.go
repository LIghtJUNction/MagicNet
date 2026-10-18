package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func assertNoWorkspace(t *testing.T, root string) {
	t.Helper()
	if _, err := os.Lstat(filepath.Join(root, workspaceName)); !os.IsNotExist(err) {
		t.Fatalf("component workspace remains: %v", err)
	}
	if matches, err := filepath.Glob(filepath.Join(filepath.Dir(root), ".magicnet-components*")); err != nil || len(matches) != 0 {
		t.Fatalf("components polluted the module parent: %v (%v)", matches, err)
	}
}

func TestRepeatedOnlineUpgradesKeepOnlyCurrentFiles(t *testing.T) {
	archives := make([]string, 3)
	payloads := map[string][]byte{}
	for version := range archives {
		c, blob := part(t, "webui", fmt.Sprintf("webroot/version-%d/index.js", version), fmt.Sprintf("webui-%d", version))
		m := manifestFixture(c)
		m.Version = fmt.Sprintf("v1.4.%d", 8+version)
		archives[version] = archiveFixture(t, t.TempDir(), m, nil)
		payloads["/"+c.Asset] = blob
	}
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		blob, exists := payloads[r.URL.Path]
		if !exists {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(blob)
	}))
	defer server.Close()
	o := optionsFixture(t, archives[0])
	o.CacheDir = "" // Exercise the production default, with no explicit cache.
	o.client, o.baseURL, o.Offline = server.Client(), server.URL+"/", false
	writeFixture(t, filepath.Join(o.ModuleDir, ".config/subscription.url"), []byte("private fixture"))
	writeFixture(t, filepath.Join(filepath.Dir(o.ModuleDir), "unrelated.txt"), []byte("keep"))
	for version, archive := range archives {
		o.Archive = archive
		if err := run(o); err != nil {
			t.Fatal(err)
		}
		assertContent(t, filepath.Join(o.ModuleDir, fmt.Sprintf("webroot/version-%d/index.js", version)), fmt.Sprintf("webui-%d", version))
		versions, err := filepath.Glob(filepath.Join(o.ModuleDir, "webroot/version-*"))
		if err != nil || len(versions) != 1 {
			t.Fatalf("historical component directories remain: %v (%v)", versions, err)
		}
		assertNoWorkspace(t, o.ModuleDir)
		before := requests.Load()
		if err := run(o); err != nil {
			t.Fatal(err)
		}
		if requests.Load() != before {
			t.Fatal("unchanged reinstallation did not reuse installed files")
		}
		assertNoWorkspace(t, o.ModuleDir)
	}
	assertContent(t, filepath.Join(o.ModuleDir, ".config/subscription.url"), "private fixture")
	assertContent(t, filepath.Join(filepath.Dir(o.ModuleDir), "unrelated.txt"), "keep")
	if requests.Load() != 6 {
		t.Fatalf("want exactly one probe and transfer per changed component, got %d", requests.Load())
	}
}

func TestExplicitArchiveSourceIsNeverCreatedOrPopulated(t *testing.T) {
	c, blob := part(t, "engine", "bin/sing-box", "good")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(blob)
	}))
	defer server.Close()
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), nil))
	o.client, o.baseURL, o.Offline = server.Client(), server.URL+"/", false
	if err := run(o); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(o.CacheDir); !os.IsNotExist(err) {
		t.Fatalf("read-only archive source was created: %v", err)
	}
	assertNoWorkspace(t, o.ModuleDir)
}

func TestFailedInstallCleansWorkspaceAndPreservesUnrelatedFiles(t *testing.T) {
	c, _ := part(t, "engine", "bin/sing-box", "new")
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), nil))
	o.CacheDir = ""
	writeFixture(t, filepath.Join(o.ModuleDir, "bin/sing-box"), []byte("old"))
	writeFixture(t, filepath.Join(o.ModuleDir, ".config/user.json"), []byte("keep"))
	for attempt := 0; attempt < 3; attempt++ {
		if err := run(o); err == nil {
			t.Fatal("missing offline payload was accepted")
		}
		assertNoWorkspace(t, o.ModuleDir)
		assertContent(t, filepath.Join(o.ModuleDir, "bin/sing-box"), "old")
		assertContent(t, filepath.Join(o.ModuleDir, ".config/user.json"), "keep")
	}
}

func TestModuleLockCannotBeBypassedWithAnotherArchiveSource(t *testing.T) {
	c, _ := part(t, "engine", "bin/sing-box", "new")
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), map[string][]byte{"bin/sing-box": []byte("new")}))
	lock, err := lockModule(o.ModuleDir)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	stage, err := prepareWorkspace(o.ModuleDir)
	if err != nil {
		t.Fatal(err)
	}
	writeFixture(t, filepath.Join(stage, ".downloads/active"), []byte("active transfer"))
	o.CacheDir = ""
	if err := run(o); err == nil || !strings.Contains(err.Error(), "another component installation") {
		t.Fatalf("concurrent installation was not rejected: %v", err)
	}
	assertContent(t, filepath.Join(stage, ".downloads/active"), "active transfer")
	if err := lock.Close(); err != nil {
		t.Fatal(err)
	}
	if err := run(o); err != nil {
		t.Fatal(err)
	}
	assertNoWorkspace(t, o.ModuleDir)
}

func TestUnknownWorkspaceAndSymlinksAreLeftUntouched(t *testing.T) {
	for _, kind := range []string{"unknown", "symlink", "wrong-marker"} {
		t.Run(kind, func(t *testing.T) {
			c, _ := part(t, "engine", "bin/sing-box", "new")
			o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), map[string][]byte{"bin/sing-box": []byte("new")}))
			stage := filepath.Join(o.ModuleDir, workspaceName)
			protected := filepath.Join(t.TempDir(), "keep")
			if kind == "symlink" {
				writeFixture(t, protected, []byte("keep"))
				if err := os.MkdirAll(o.ModuleDir, 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(filepath.Dir(protected), stage); err != nil {
					t.Fatal(err)
				}
			} else {
				protected = filepath.Join(stage, "keep")
				writeFixture(t, protected, []byte("keep"))
				if kind == "wrong-marker" {
					writeFixture(t, filepath.Join(stage, workspaceOwner), []byte("not an empty owned marker"))
				}
			}
			if err := run(o); err == nil {
				t.Fatal("unrecognized workspace was adopted")
			}
			assertContent(t, protected, "keep")
		})
	}
}

func promotionFixture(t *testing.T) (string, string, []payloadFile, []string) {
	t.Helper()
	root := t.TempDir()
	stage, err := prepareWorkspace(root)
	if err != nil {
		t.Fatal(err)
	}
	for name, value := range map[string]string{
		"bin/a": "old-a", "components.installed.json": "old manifest",
		"webroot/obsolete/old.js": "old webui", ".config/user.json": "private fixture",
	} {
		writeFixture(t, filepath.Join(root, name), []byte(value))
	}
	files := []payloadFile{{Path: "bin/a"}, {Path: "bin/b"}, {Path: "components.installed.json"}}
	for _, f := range files {
		writeFixture(t, filepath.Join(stage, f.Path), []byte("new "+f.Path))
	}
	return root, stage, files, []string{"webroot/obsolete/old.js"}
}

func promotionMoves(j promotionJournal, root, stage string) [][2]string {
	var moves [][2]string
	for _, c := range j.Changes {
		dst := filepath.Join(root, c.Path)
		if c.Existed {
			moves = append(moves, [2]string{dst, filepath.Join(stage, ".rollback", c.Path)})
		}
		if c.Install {
			moves = append(moves, [2]string{filepath.Join(stage, c.Path), dst})
		}
	}
	return moves
}

func assertOriginalPromotionFiles(t *testing.T, root string) {
	t.Helper()
	assertContent(t, filepath.Join(root, "bin/a"), "old-a")
	assertContent(t, filepath.Join(root, "components.installed.json"), "old manifest")
	assertContent(t, filepath.Join(root, "webroot/obsolete/old.js"), "old webui")
	assertContent(t, filepath.Join(root, ".config/user.json"), "private fixture")
	if _, err := os.Lstat(filepath.Join(root, "bin/b")); !os.IsNotExist(err) {
		t.Fatalf("new file survived transaction rollback: %v", err)
	}
}

func TestInterruptedPromotionRecoversAtEveryRenameBoundary(t *testing.T) {
	// All seven possible process-exit points across replacement, introduction,
	// manifest publication and obsolete-file removal must restore the same set.
	for after := 0; after <= 6; after++ {
		t.Run(fmt.Sprintf("after-%d-renames", after), func(t *testing.T) {
			root, stage, files, obsolete := promotionFixture(t)
			j, err := preparePromotion(stage, root, files, obsolete)
			if err != nil {
				t.Fatal(err)
			}
			for _, move := range promotionMoves(j, root, stage)[:after] {
				if err := os.Rename(move[0], move[1]); err != nil {
					t.Fatal(err)
				}
			}
			recovered, err := prepareWorkspace(root)
			if err != nil {
				t.Fatal(err)
			}
			assertOriginalPromotionFiles(t, root)
			if recovered != stage {
				t.Fatal("recovery created another history directory")
			}
			if err := cleanupWorkspace(recovered); err != nil {
				t.Fatal(err)
			}
			assertNoWorkspace(t, root)
		})
	}
}

func TestInterruptedCleanupKeepsCommittedInstallation(t *testing.T) {
	root, stage, files, obsolete := promotionFixture(t)
	if err := promote(stage, root, files, obsolete); err != nil {
		t.Fatal(err)
	}
	// Simulate a process dying during cleanup, after its completion marker was
	// removed but before the backup tree. The ownership marker remains until last.
	if err := os.Remove(filepath.Join(stage, ".committed")); err != nil {
		t.Fatal(err)
	}
	if _, err := prepareWorkspace(root); err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		assertContent(t, filepath.Join(root, f.Path), "new "+f.Path)
	}
	if _, err := os.Lstat(filepath.Join(root, obsolete[0])); !os.IsNotExist(err) {
		t.Fatal("committed obsolete-file removal was undone")
	}
	assertContent(t, filepath.Join(root, ".config/user.json"), "private fixture")
}

func TestFailedRecoveryRetainsOneBackupAndCanResume(t *testing.T) {
	root, stage, files, obsolete := promotionFixture(t)
	j, err := preparePromotion(stage, root, files, obsolete)
	if err != nil {
		t.Fatal(err)
	}
	for _, move := range promotionMoves(j, root, stage) {
		if err := os.Rename(move[0], move[1]); err != nil {
			t.Fatal(err)
		}
	}
	blocked := filepath.Join(root, "bin/a")
	if err := os.Remove(blocked); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(blocked, 0o700); err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 3; attempt++ {
		if _, err := prepareWorkspace(root); err == nil {
			t.Fatal("blocked recovery was hidden")
		}
		assertContent(t, filepath.Join(stage, ".rollback/bin/a"), "old-a")
	}
	if err := os.Remove(blocked); err != nil {
		t.Fatal(err)
	}
	if _, err := prepareWorkspace(root); err != nil {
		t.Fatal(err)
	}
	assertOriginalPromotionFiles(t, root)
}

func TestInterruptedDownloadWorker(t *testing.T) {
	if os.Getenv("MAGICNET_TEST_DOWNLOAD_WORKER") != "1" {
		return
	}
	err := run(options{
		Archive: os.Getenv("MAGICNET_TEST_ARCHIVE"), ModuleDir: os.Getenv("MAGICNET_TEST_MODULE"),
		client: http.DefaultClient, baseURL: os.Getenv("MAGICNET_TEST_ENDPOINT"),
		mirrors: []string{}, route: &routeHint{set: true}, log: io.Discard,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(93)
	}
}

func TestKilledDownloadReleasesLockAndReclaimsPartialOnRetry(t *testing.T) {
	c, blob := part(t, "engine", "bin/sing-box", strings.Repeat("engine", 1000))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(c.Size))
		_, _ = w.Write(blob[:len(blob)/2])
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	o := optionsFixture(t, archiveFixture(t, t.TempDir(), manifestFixture(c), nil))
	cmd := exec.Command(os.Args[0], "-test.run=^TestInterruptedDownloadWorker$")
	cmd.Env = append(os.Environ(), "MAGICNET_TEST_DOWNLOAD_WORKER=1",
		"MAGICNET_TEST_ARCHIVE="+o.Archive, "MAGICNET_TEST_MODULE="+o.ModuleDir,
		"MAGICNET_TEST_ENDPOINT="+server.URL+"/")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if cmd.ProcessState == nil {
			cmd.Process.Kill()
			cmd.Wait()
		}
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		matches, _ := filepath.Glob(filepath.Join(o.ModuleDir, workspaceName, ".downloads/.download-*"))
		if len(matches) > 0 {
			if st, err := os.Stat(matches[0]); err == nil && st.Size() > 0 {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("worker never started a partial component download")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err == nil {
		t.Fatal("download worker was not interrupted")
	}
	o.Archive = archiveFixture(t, t.TempDir(), manifestFixture(c),
		map[string][]byte{"bin/sing-box": []byte(strings.Repeat("engine", 1000))})
	o.CacheDir = ""
	if err := run(o); err != nil {
		t.Fatal(err)
	}
	assertNoWorkspace(t, o.ModuleDir)
	assertContent(t, filepath.Join(o.ModuleDir, "bin/sing-box"), strings.Repeat("engine", 1000))
}
