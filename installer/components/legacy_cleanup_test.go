package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func legacyLayout(t *testing.T) (string, string) {
	t.Helper()
	adb := filepath.Join(t.TempDir(), "data", "adb")
	module := filepath.Join(adb, "modules_update", "MagicNet")
	writeFixture(t, filepath.Join(module, "module.prop"), []byte("id=MagicNet\nversion=v1.6.3\n"))
	return adb, module
}

func seedLegacyCache(t *testing.T, adb string) string {
	t.Helper()
	cache := filepath.Join(adb, "magicnet-components")
	writeFixture(t, filepath.Join(cache, "install.lock"), nil)
	for _, version := range []string{"a", "b", "c", "d"} {
		writeFixture(t, filepath.Join(cache, strings.Repeat(version, 64)+".zip"), []byte("old component"))
	}
	writeFixture(t, filepath.Join(cache, ".download-12345"), []byte("interrupted transfer"))
	return cache
}

func assertLegacyPresent(t *testing.T, path string, present bool) {
	t.Helper()
	_, err := os.Lstat(path)
	if (err == nil) != present || (err != nil && !os.IsNotExist(err)) {
		t.Fatalf("path %s: wanted present=%v, got %v", path, present, err)
	}
}

func TestLegacyCleanupRemovesOldVersionsWithoutTouchingCurrentState(t *testing.T) {
	adb, module := legacyLayout(t)
	cache := seedLegacyCache(t, adb)
	log := filepath.Join(adb, "cache", "MagicNet")
	writeFixture(t, filepath.Join(log, "kam.log"), []byte("old log"))
	writeFixture(t, filepath.Join(log, "kam.log.1"), []byte("older log"))
	for _, parent := range []string{"modules", "modules_update"} {
		backup := filepath.Join(adb, parent, "MagicNet.install-backup.2147483647")
		writeFixture(t, filepath.Join(backup, ".magicnet-install-backup-v1"), []byte("magicnet-install-backup-v1\n"))
		writeFixture(t, filepath.Join(backup, "readonly", "old-secret"), []byte("old backup"))
		if err := os.Chmod(filepath.Join(backup, "readonly"), 0o500); err != nil {
			t.Fatal(err)
		}
	}
	protected := []string{
		filepath.Join(module, ".config", "sing-box", "subscription.url"),
		filepath.Join(module, ".config", "sing-box", "config.json.pre-upgrade"),
		filepath.Join(module, ".state", "network-access-recovery", "record.json"),
		filepath.Join(adb, "modules", "AnotherVPN", "keep"),
		filepath.Join(adb, "modules", ".magicnet-components-123", ".rollback", "bin", "sing-box"),
	}
	for _, name := range protected {
		writeFixture(t, name, []byte("preserve these bytes"))
	}
	for i := 0; i < 3; i++ {
		if err := cleanupLegacyStorage(module); err != nil {
			t.Fatal(err)
		}
	}
	assertLegacyPresent(t, cache, false)
	assertLegacyPresent(t, log, false)
	for _, parent := range []string{"modules", "modules_update"} {
		assertLegacyPresent(t, filepath.Join(adb, parent, "MagicNet.install-backup.2147483647"), false)
	}
	for _, name := range protected {
		data, err := os.ReadFile(name)
		if err != nil || string(data) != "preserve these bytes" {
			t.Fatalf("protected file changed: %s: %v", name, err)
		}
	}
}

func TestLegacyCleanupRespectsCacheLock(t *testing.T) {
	adb, module := legacyLayout(t)
	cache := seedLegacyCache(t, adb)
	lock, err := os.Open(filepath.Join(cache, "install.lock"))
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	if err := cleanupLegacyStorage(module); err == nil {
		t.Fatal("busy legacy cache was reported as cleaned")
	}
	assertLegacyPresent(t, filepath.Join(cache, strings.Repeat("a", 64)+".zip"), true)
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	if err := cleanupLegacyStorage(module); err != nil {
		t.Fatal(err)
	}
	assertLegacyPresent(t, cache, false)
}

func TestLegacyCleanupPreservesUnknownAndLinkedFiles(t *testing.T) {
	adb, module := legacyLayout(t)
	cache := seedLegacyCache(t, adb)
	outside := filepath.Join(filepath.Dir(adb), "outside")
	writeFixture(t, outside, []byte("keep outside"))
	linked := filepath.Join(cache, strings.Repeat("e", 64)+".zip")
	if err := os.Symlink(outside, linked); err != nil {
		t.Fatal(err)
	}
	unknown := filepath.Join(cache, "personal.zip")
	writeFixture(t, unknown, []byte("keep unknown"))
	log := filepath.Join(adb, "cache", "MagicNet")
	writeFixture(t, filepath.Join(log, "keep"), []byte("unrelated log"))
	if err := os.Symlink(outside, filepath.Join(log, "kam.log")); err != nil {
		t.Fatal(err)
	}
	if err := cleanupLegacyStorage(module); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{linked, outside, unknown, filepath.Join(cache, "install.lock"), filepath.Join(log, "keep"), filepath.Join(log, "kam.log")} {
		assertLegacyPresent(t, path, true)
	}
	assertLegacyPresent(t, filepath.Join(cache, strings.Repeat("a", 64)+".zip"), false)
}

func TestLegacyCleanupRejectsSymlinkRootsAndWrongIdentity(t *testing.T) {
	for _, mode := range []string{"wrong-id", "duplicate-id", "module-link", "cache-link", "lock-link", "log-parent-link"} {
		t.Run(mode, func(t *testing.T) {
			adb, module := legacyLayout(t)
			cache := seedLegacyCache(t, adb)
			sentinel := filepath.Join(cache, strings.Repeat("a", 64)+".zip")
			wantError := false
			switch mode {
			case "wrong-id", "duplicate-id":
				props := "id=AnotherVPN\n"
				if mode == "duplicate-id" {
					props = "id=MagicNet\nid=MagicNet\n"
				}
				writeFixture(t, filepath.Join(module, "module.prop"), []byte(props))
				wantError = true
			case "module-link", "cache-link", "log-parent-link":
				path := module
				if mode == "cache-link" {
					path = cache
				} else if mode == "log-parent-link" {
					path = filepath.Join(adb, "cache")
					writeFixture(t, filepath.Join(path, "MagicNet", "kam.log"), []byte("keep"))
					sentinel = filepath.Join(path+"-target", "MagicNet", "kam.log")
				}
				if err := os.Rename(path, path+"-target"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(path+"-target", path); err != nil {
					t.Fatal(err)
				}
				wantError = mode == "module-link"
			case "lock-link":
				lock := filepath.Join(cache, "install.lock")
				if err := os.Remove(lock); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(sentinel, lock); err != nil {
					t.Fatal(err)
				}
			}
			if err := cleanupLegacyStorage(module); (err != nil) != wantError {
				t.Fatalf("unexpected cleanup result: %v", err)
			}
			assertLegacyPresent(t, sentinel, true)
		})
	}
}

func TestLegacyCleanupRequiresExactBackupMarkerAndDeadOwner(t *testing.T) {
	adb, module := legacyLayout(t)
	for i, marker := range []string{"", "magicnet-install-backup-v1", "magicnet-install-backup-v1\nextra", "magicnet-install-backup-v1\n\n"} {
		dir := filepath.Join(adb, "modules", fmt.Sprintf("MagicNet.install-backup.%d", 2147483646-i))
		writeFixture(t, filepath.Join(dir, ".magicnet-install-backup-v1"), []byte(marker))
	}
	active := filepath.Join(adb, "modules", fmt.Sprintf("MagicNet.install-backup.%d", os.Getpid()))
	writeFixture(t, filepath.Join(active, ".magicnet-install-backup-v1"), []byte("magicnet-install-backup-v1\n"))
	if err := cleanupLegacyStorage(module); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(adb, "modules"))
	if err != nil || len(entries) != 5 {
		t.Fatalf("unknown/active backups changed: %v, %v", entries, err)
	}
}

func seedLegacyFarewell(t *testing.T, adb, suffix string) string {
	t.Helper()
	dir := filepath.Join(adb, ".magicnet-farewell."+suffix)
	writeFixture(t, filepath.Join(dir, "worker.sh"), []byte("#!/system/bin/sh\nMN_FAREWELL_RUN=${0%/*}\n. \"$MN_FAREWELL_RUN/uninstall.sh\" || exit 1\nmagicnet_farewell_worker \"$MN_FAREWELL_RUN\"\n"))
	writeFixture(t, filepath.Join(dir, "httpd.conf"), []byte("A:127.0.0.1\nD:*\n"))
	token := strings.Repeat("a", 32)
	writeFixture(t, filepath.Join(dir, "token"), []byte(token+"\n"))
	writeFixture(t, filepath.Join(dir, "www", token, "index.html"), []byte(`<main id="farewell">Goodbye</main>`))
	return dir
}

func TestLegacyCleanupOnlyRemovesIdleRecognizedFarewell(t *testing.T) {
	adb, module := legacyLayout(t)
	stale := seedLegacyFarewell(t, adb, "STALE1")
	recent := seedLegacyFarewell(t, adb, "RECENT")
	unknown := seedLegacyFarewell(t, adb, "EXTRA1")
	writeFixture(t, filepath.Join(unknown, "keep"), []byte("user file"))
	for _, dir := range []string{stale, unknown} {
		past := time.Now().Add(-time.Hour)
		if err := os.Chtimes(dir, past, past); err != nil {
			t.Fatal(err)
		}
	}
	if err := cleanupLegacyStorage(module); err != nil {
		t.Fatal(err)
	}
	assertLegacyPresent(t, stale, false)
	assertLegacyPresent(t, recent, true)
	assertLegacyPresent(t, unknown, true)
}
