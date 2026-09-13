package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSmartFailedCheckClearsIncompletePlan(t *testing.T) {
	f := newUpdateFixture(t)
	f.rel.Draft = true
	if err := f.u.perform(false); err == nil {
		t.Fatal("draft unexpectedly accepted")
	}
	s, err := f.u.status()
	if err != nil {
		t.Fatal(err)
	}
	if s.Phase != "error" || s.Error == "" || s.Plan != nil {
		t.Fatal(s)
	}
	raw, _ := json.Marshal(s)
	if strings.Contains(string(raw), `"plan"`) {
		t.Fatal("UI received malformed empty plan")
	}
}

func TestSmartInterruptedTaskDoesNotRemainBusy(t *testing.T) {
	f := newUpdateFixture(t)
	for _, phase := range []string{"checking", "downloading", "installing"} {
		if err := saveUpdateJSON(filepath.Join(f.u.state, "status.json"), updateStatus{Phase: phase}); err != nil {
			t.Fatal(err)
		}
		unlock, err := updateLock(f.u.state, "operation.lock")
		if err != nil {
			t.Fatal(err)
		}
		active, err := f.u.status()
		if err != nil || active.Phase != phase {
			t.Fatal(active, err)
		}
		unlock()
		interrupted, err := f.u.status()
		if err != nil || interrupted.Phase != "error" || interrupted.Error == "" {
			t.Fatal(interrupted, err)
		}
	}
}

func TestSmartDaemonDetachesBeforeExecWithoutInterpolatingPaths(t *testing.T) {
	for _, fails := range []bool{false, true} {
		root := filepath.Join(t.TempDir(), "module with 'quote; no-eval")
		marker := filepath.Join(root, "called")
		body := "magicnet_detach_pid_from_app_cgroup() { return 0; }\n"
		if fails {
			body = "magicnet_detach_pid_from_app_cgroup() { return 1; }\n"
		}
		writeFixture(t, filepath.Join(root, "lib/magicnet/primitives.sh"), []byte(body))
		helper := filepath.Join(root, "helper")
		writeFixture(t, helper, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" >\"${0%/*}/called\"\n"))
		if err := os.Chmod(helper, 0755); err != nil {
			t.Fatal(err)
		}
		u := updater{o: options{ModuleDir: root, CacheDir: root + "/cache"}, state: root + "/state", pending: root + "/pending"}
		wrapped := daemonCommand("android", helper, u)
		if wrapped.Path != "/system/bin/sh" || strings.Contains(wrapped.Args[2], root) {
			t.Fatal(wrapped.Args)
		}
		// Host shell runs the exact Android wrapper and quoted arguments; no device
		// cgroups are touched by this fixture.
		err := exec.Command("sh", wrapped.Args[1:]...).Run()
		if (err != nil) != fails {
			t.Fatal(err)
		}
		out, readErr := os.ReadFile(marker)
		if fails {
			if !os.IsNotExist(readErr) {
				t.Fatal("exec ran after failed detachment")
			}
			continue
		}
		if readErr != nil || !strings.Contains(string(out), root) || !strings.HasPrefix(string(out), "update\ndaemon\n") {
			t.Fatal(string(out), readErr)
		}
	}
}
