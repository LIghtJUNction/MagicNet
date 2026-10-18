package main

// TEMPORARY migration for releases through v1.6.2.
// Remove this file, legacy_cleanup_test.go, the --cleanup-legacy flag and the
// packager's migration call when direct upgrades from <=v1.6.2 are retired.
// This is an installation boundary, never a boot-time or recurring cleaner.

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var legacyArchiveName = regexp.MustCompile(`^[0-9a-f]{64}\.zip$`)
var legacyDownloadName = regexp.MustCompile(`^\.download-[0-9]+$`)
var legacyBackupName = regexp.MustCompile(`^MagicNet\.install-backup\.([1-9][0-9]*)$`)
var legacyFarewellName = regexp.MustCompile(`^\.magicnet-farewell\.[A-Za-z0-9]{6}$`)
var legacyToken = regexp.MustCompile(`^[0-9a-f]{32}\n$`)

func legacyExact(name, expected string) bool {
	data, err := readBounded(name, int64(len(expected)))
	return err == nil && string(data) == expected
}

func legacyDirectory(name string) bool {
	if physical(name, false) != nil {
		return false
	}
	st, err := os.Stat(name)
	return err == nil && st.IsDir()
}

func legacyRemoveEmpty(name string) error {
	err := os.Remove(name)
	if errors.Is(err, syscall.ENOTEMPTY) || errors.Is(err, syscall.EEXIST) || os.IsNotExist(err) {
		return nil
	}
	return err
}

func cleanupLegacyComponentCache(cache string) error {
	if !legacyDirectory(cache) {
		return nil
	}
	// The old updater locks this inode. Never create a second lock or remove
	// archives while an older installation is using them.
	lockPath := filepath.Join(cache, "install.lock")
	if regular(lockPath) != nil {
		return nil
	}
	lock, err := os.Open(lockPath)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("legacy component cache is busy: %w", err)
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	entries, err := os.ReadDir(cache)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !legacyArchiveName.MatchString(entry.Name()) && !legacyDownloadName.MatchString(entry.Name()) {
			continue
		}
		name := filepath.Join(cache, entry.Name())
		if regular(name) == nil {
			if err := os.Remove(name); err != nil {
				return err
			}
		}
	}
	// Retain the lock when unrecognized contents remain. An empty, retired
	// cache can disappear completely; no new release writes to it.
	entries, err = os.ReadDir(cache)
	if err != nil {
		return err
	}
	if len(entries) == 1 && entries[0].Name() == "install.lock" {
		if err = os.Remove(lockPath); err != nil {
			return err
		}
		return legacyRemoveEmpty(cache)
	}
	return nil
}

func cleanupLegacyLogs(directory string) error {
	if !legacyDirectory(directory) {
		return nil
	}
	for _, filename := range []string{"kam.log", "kam.log.1"} {
		name := filepath.Join(directory, filename)
		if regular(name) == nil {
			if err := os.Remove(name); err != nil {
				return err
			}
		}
	}
	return legacyRemoveEmpty(directory)
}

func cleanupLegacyBackups(parent string) error {
	if !legacyDirectory(parent) {
		return nil
	}
	entries, err := os.ReadDir(parent)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		match := legacyBackupName.FindStringSubmatch(entry.Name())
		if match == nil {
			continue
		}
		pid, err := strconv.Atoi(match[1])
		if err != nil || !errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
			continue // A live or inaccessible owner is not stale.
		}
		directory := filepath.Join(parent, entry.Name())
		if !legacyDirectory(directory) || !legacyExact(filepath.Join(directory, ".magicnet-install-backup-v1"), "magicnet-install-backup-v1\n") {
			continue
		}
		// Old backups preserve read-only directory modes. Walk physically and
		// change only owned directories, never symlink targets or user files.
		if err := filepath.WalkDir(directory, func(path string, item os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if item.IsDir() {
				info, err := item.Info()
				if err != nil {
					return err
				}
				return os.Chmod(path, info.Mode().Perm()|0o700)
			}
			return nil
		}); err != nil {
			return err
		}
		if !legacyExact(filepath.Join(directory, ".magicnet-install-backup-v1"), "magicnet-install-backup-v1\n") {
			return fmt.Errorf("legacy backup ownership changed: %s", directory)
		}
		if err := os.RemoveAll(directory); err != nil {
			return err
		}
	}
	return nil
}

func legacyFarewellIdle(directory string) bool {
	st, err := os.Stat(directory)
	if err != nil || time.Since(st.ModTime()) < 10*time.Minute {
		return false // The old worker can legitimately live for 480 seconds.
	}
	processes, err := os.ReadDir("/proc")
	if err != nil {
		return false
	}
	for _, process := range processes {
		if _, err := strconv.Atoi(process.Name()); err != nil {
			continue
		}
		command, err := os.ReadFile(filepath.Join("/proc", process.Name(), "cmdline"))
		if err != nil && !os.IsNotExist(err) {
			return false
		}
		if bytes.Contains(command, []byte(directory+"/")) {
			return false
		}
	}
	return true
}

func cleanupLegacyFarewell(parent string) error {
	entries, err := os.ReadDir(parent)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !legacyFarewellName.MatchString(entry.Name()) {
			continue
		}
		directory := filepath.Join(parent, entry.Name())
		if !legacyDirectory(directory) || !legacyFarewellIdle(directory) {
			continue
		}
		// These old directories have no owner marker. Require their exact
		// public worker contract; a matching directory name alone is not proof.
		worker := "#!/system/bin/sh\nMN_FAREWELL_RUN=${0%/*}\n. \"$MN_FAREWELL_RUN/uninstall.sh\" || exit 1\nmagicnet_farewell_worker \"$MN_FAREWELL_RUN\"\n"
		if !legacyExact(filepath.Join(directory, "worker.sh"), worker) ||
			!legacyExact(filepath.Join(directory, "httpd.conf"), "A:127.0.0.1\nD:*\n") {
			continue
		}
		token, err := readBounded(filepath.Join(directory, "token"), 33)
		if err != nil || !legacyToken.Match(token) {
			continue
		}
		page, err := readBounded(filepath.Join(directory, "www", strings.TrimSpace(string(token)), "index.html"), 256*1024)
		if err != nil || !bytes.Contains(page, []byte(`id="farewell"`)) {
			continue
		}
		allowed := map[string]bool{}
		for _, name := range []string{".", "busybox", "uninstall.sh", "launcher.sh", "token", "version", "httpd.conf", "worker.sh", "www", "www/" + strings.TrimSpace(string(token)), "www/" + strings.TrimSpace(string(token)) + "/index.html"} {
			allowed[name] = true
		}
		if err := filepath.WalkDir(directory, func(path string, item os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			name, err := filepath.Rel(directory, path)
			if err != nil || !allowed[filepath.ToSlash(name)] || item.Type()&os.ModeSymlink != 0 {
				return fmt.Errorf("unrecognized farewell contents")
			}
			return nil
		}); err != nil {
			continue
		}
		if err := os.RemoveAll(directory); err != nil {
			return err
		}
	}
	return nil
}

func cleanupLegacyStorage(moduleDir string) error {
	moduleDir = filepath.Clean(moduleDir)
	parent := filepath.Dir(moduleDir)
	if !filepath.IsAbs(moduleDir) || filepath.Base(moduleDir) != "MagicNet" ||
		(filepath.Base(parent) != "modules" && filepath.Base(parent) != "modules_update") ||
		!legacyDirectory(moduleDir) {
		return fmt.Errorf("legacy cleanup requires a physical MagicNet manager directory")
	}
	props, err := readBounded(filepath.Join(moduleDir, "module.prop"), 64*1024)
	if err != nil {
		return err
	}
	identities := 0
	for _, line := range strings.Split(string(props), "\n") {
		if strings.HasPrefix(line, "id=") {
			if line != "id=MagicNet" {
				return fmt.Errorf("legacy cleanup module identity mismatch")
			}
			identities++
		}
	}
	if identities != 1 {
		return fmt.Errorf("legacy cleanup requires one MagicNet module identity")
	}
	adb := filepath.Dir(parent)
	return errors.Join(
		cleanupLegacyComponentCache(filepath.Join(adb, "magicnet-components")),
		cleanupLegacyLogs(filepath.Join(adb, "cache", "MagicNet")),
		cleanupLegacyBackups(filepath.Join(adb, "modules")),
		cleanupLegacyBackups(filepath.Join(adb, "modules_update")),
		cleanupLegacyFarewell(adb),
	)
}
