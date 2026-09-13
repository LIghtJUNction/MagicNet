package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

type updateSettings struct {
	Enabled       bool `json:"enabled"`
	IntervalHours int  `json:"interval_hours"`
	WifiOnly      bool `json:"wifi_only"`
}
type updateStatus struct {
	Schema           int            `json:"schema"`
	Settings         updateSettings `json:"settings"`
	CurrentVersion   string         `json:"current_version"`
	PendingVersion   string         `json:"pending_version"`
	Phase            string         `json:"phase"`
	LastAttempt      int64          `json:"last_attempt"`
	LastCheck        int64          `json:"last_check"`
	NextCheck        int64          `json:"next_check"`
	LastSuccess      int64          `json:"last_success"`
	Failures         int            `json:"failures"`
	TransferredBytes int64          `json:"transferred_bytes"`
	Plan             *updatePlan    `json:"plan"`
	Error            string         `json:"error"`
	Running          bool           `json:"running"`
}
type updateEngine struct {
	moduleDir, stateDir, cacheDir, pendingDir, apiURL string
	client                                            *http.Client
	mirrors                                           []string
	log                                               io.Writer
	now                                               func() time.Time
	wifi                                              func(context.Context) bool
	installer                                         func(context.Context, string) error
	bytes                                             atomic.Int64
	session                                           *downloadSession
}

func newUpdateEngine() *updateEngine {
	e := &updateEngine{moduleDir: "/data/adb/modules/MagicNet", pendingDir: "/data/adb/modules_update/MagicNet", stateDir: "/data/adb/magicnet-updater", cacheDir: "/data/adb/magicnet-components", apiURL: "https://api.github.com/repos/" + updateRepository + "/releases/latest", mirrors: []string{"https://ghfast.top/", "https://ghproxy.net/", "https://gh-proxy.com/"}, log: os.Stderr, now: time.Now, wifi: androidWifi, session: &downloadSession{}}
	e.client = networkClient()
	e.client.Transport = meteredTransport{base: e.client.Transport, bytes: &e.bytes}
	e.installer = installWithManager
	return e
}
func (e *updateEngine) logf(format string, args ...any) {
	if e.log != nil {
		fmt.Fprintf(e.log, format+"\n", args...)
	}
}
func (e *updateEngine) downloadOptions(ctx context.Context) options {
	return options{CacheDir: e.cacheDir, client: e.client, mirrors: e.mirrors, log: e.log, ctx: ctx, session: e.session}
}
func (e *updateEngine) init() error {
	for _, dir := range []string{e.stateDir, e.cacheDir} {
		if err := privateDirectory(dir); err != nil {
			return err
		}
	}
	return nil
}
func (e *updateEngine) settings() (updateSettings, error) {
	s := updateSettings{Enabled: false, IntervalHours: 24, WifiOnly: true}
	err := readBoundedJSON(filepath.Join(e.stateDir, "settings.json"), &s, 4096)
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		return s, err
	}
	if s.IntervalHours < 1 || s.IntervalHours > 168 {
		return s, errors.New("update interval must be 1-168 hours")
	}
	return s, nil
}
func fileLock(name string) (*os.File, error) {
	if err := physical(name, true); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(name, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, errors.New("another updater operation is running")
	}
	return f, nil
}
func (e *updateEngine) status() (updateStatus, error) {
	s := updateStatus{Schema: 1, Phase: "idle"}
	err := readBoundedJSON(filepath.Join(e.stateDir, "status.json"), &s, 1<<20)
	if err != nil && !os.IsNotExist(err) {
		return s, err
	}
	s.Settings, err = e.settings()
	if err != nil {
		return s, err
	}
	s.CurrentVersion, err = moduleVersion(e.moduleDir)
	if err != nil && !os.IsNotExist(err) {
		return s, err
	}
	s.PendingVersion, err = moduleVersion(e.pendingDir)
	if err != nil && !os.IsNotExist(err) {
		return s, err
	}
	// The manager's staging directory is authoritative, not our last receipt.
	if s.PendingVersion != "" {
		s.Phase = "pending_reboot"
	}
	if s.Phase == "pending_reboot" && s.PendingVersion == "" {
		s.Phase = "idle"
	}
	s.Running = false
	if _, err = os.Stat(filepath.Join(e.stateDir, "operation.lock")); err == nil {
		lock, err := fileLock(filepath.Join(e.stateDir, "operation.lock"))
		if err != nil {
			s.Running = true
		} else {
			lock.Close()
		}
	}
	if !s.Running && (s.Phase == "checking" || s.Phase == "preparing" || s.Phase == "installing") {
		s.Phase = "interrupted"
	}
	if !s.Settings.Enabled {
		s.NextCheck = 0
	}
	return s, nil
}
func (e *updateEngine) save(s *updateStatus) error {
	s.TransferredBytes = e.bytes.Load()
	return atomicJSON(filepath.Join(e.stateDir, "status.json"), s)
}
func retryDelay(failures int) time.Duration {
	if failures < 1 {
		failures = 1
	}
	if failures > 5 {
		failures = 5
	}
	return time.Duration(15*(1<<(failures-1))) * time.Minute
}
func nextDue(s updateStatus, now int64) int64 {
	if !s.Settings.Enabled {
		return 0
	}
	interval := int64(s.Settings.IntervalHours) * 3600
	next := s.LastAttempt + interval
	if s.Failures > 0 {
		next = s.LastAttempt + int64(retryDelay(s.Failures)/time.Second)
	}
	// A corrected wall clock must not postpone checks for days or cause a burst.
	if s.LastAttempt > now {
		next = now
	}
	return next
}
func (e *updateEngine) operation(action, out string, scheduled bool) (err error) {
	if action != "check" && action != "apply" && action != "prepare" {
		return errors.New("invalid update action")
	}
	if err = e.init(); err != nil {
		return err
	}
	s, err := e.status()
	if err != nil {
		return err
	}
	lock, err := fileLock(filepath.Join(e.stateDir, "operation.lock"))
	if err != nil {
		return err
	}
	defer lock.Close()
	// Re-read after acquiring the lock: a concurrent installer may have finished.
	if pending, e2 := moduleVersion(e.pendingDir); e2 == nil && pending != "" {
		s.PendingVersion = pending
		s.Phase = "pending_reboot"
		s.Running = false
		if action == "prepare" {
			return errors.New("a module update is already staged; reboot before installing again")
		}
		return e.save(&s)
	} else if e2 != nil && !os.IsNotExist(e2) {
		return e2
	}
	if scheduled && !s.Settings.Enabled {
		return nil
	}
	if action != "prepare" {
		if _, e2 := moduleVersion(e.moduleDir); e2 != nil {
			return e2
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	s.LastAttempt = e.now().Unix()
	s.Error = ""
	s.Plan = nil
	e.bytes.Store(0)
	defer func() {
		s.Running = false
		if err != nil {
			s.Phase = "error"
			s.Error = err.Error()
			s.Failures++
		}
		s.NextCheck = nextDue(s, e.now().Unix())
		if saveErr := e.save(&s); saveErr != nil {
			err = errors.Join(err, saveErr)
		}
	}()
	if action != "prepare" && s.Settings.WifiOnly && !e.wifi(ctx) {
		s.Phase = "waiting_wifi"
		s.Failures = 1
		return nil
	}
	s.Phase = "checking"
	s.Running = true
	if err = e.save(&s); err != nil {
		return err
	}
	plan, err := e.plan(ctx)
	if err != nil {
		return err
	}
	s.Plan = &plan
	s.LastCheck = e.now().Unix()
	s.Failures = 0
	if action != "prepare" && plan.unchanged(s.CurrentVersion) {
		s.Phase = "current"
		s.Plan.DownloadBytes = 0
		s.Plan.CoreSource = "installed"
		return nil
	}
	s.Phase = "available"
	if action == "check" {
		return nil
	}
	e.logf("[plan] %s: %.2f MiB to download, %.2f MiB reused", plan.Version, float64(plan.DownloadBytes)/(1<<20), float64(plan.ReuseBytes)/(1<<20))
	for _, c := range plan.Components {
		e.logf("[plan] %s: %s (%.2f MiB)", c.ID, c.Source, float64(c.Size)/(1<<20))
	}
	work, err := os.MkdirTemp(e.stateDir, "operation-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	if action != "prepare" {
		out = filepath.Join(work, "MagicNet-ready.zip")
	}
	if !filepath.IsAbs(out) {
		return errors.New("prepared output must use an absolute private path")
	}
	s.Phase = "preparing"
	if err = e.save(&s); err != nil {
		return err
	}
	if err = e.withProgress(s, func() error { return e.prepare(ctx, plan, out) }); err != nil {
		return err
	}
	if action == "prepare" {
		s.Phase = "ready"
		return nil
	}
	// Downloads may take a while. Respect a setting change before installation.
	currentSettings, err := e.settings()
	if err != nil {
		return err
	}
	s.Settings = currentSettings
	if scheduled && !currentSettings.Enabled {
		s.Phase = "ready"
		return nil
	}
	if currentSettings.WifiOnly && !e.wifi(ctx) {
		s.Phase = "waiting_wifi"
		s.Failures = 1
		return nil
	}
	if _, err = os.Stat(e.pendingDir); err == nil {
		return errors.New("a concurrent module update is pending; refusing overwrite")
	} else if !os.IsNotExist(err) {
		return err
	}
	s.Phase = "installing"
	if err = e.save(&s); err != nil {
		return err
	}
	if err = e.installer(ctx, out); err != nil {
		return err
	}
	pending, err := moduleVersion(e.pendingDir)
	if err != nil {
		return fmt.Errorf("manager did not stage the module: %w", err)
	}
	if pending != plan.Version {
		return errors.New("manager staged a different module version")
	}
	s.PendingVersion = pending
	s.LastSuccess = e.now().Unix()
	s.Phase = "pending_reboot"
	e.logf("[ready] %s staged. Reboot manually to activate; no automatic reboot.", pending)
	return nil
}

// Publish an immutable phase snapshot while response-body byte counters change.
// Joining this goroutine before the next phase prevents a late progress write
// from overwriting a success/error receipt.
func (e *updateEngine) withProgress(snapshot updateStatus, work func() error) error {
	done, stopped := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(stopped)
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				progress := snapshot
				progress.TransferredBytes = e.bytes.Load()
				_ = atomicJSON(filepath.Join(e.stateDir, "status.json"), progress)
			}
		}
	}()
	err := work()
	close(done)
	<-stopped
	return err
}

func (e *updateEngine) configure(enabled bool, hours int, wifi bool) error {
	if hours < 1 || hours > 168 {
		return errors.New("update interval must be 1-168 hours")
	}
	if err := e.init(); err != nil {
		return err
	}
	return atomicJSON(filepath.Join(e.stateDir, "settings.json"), updateSettings{enabled, hours, wifi})
}
func (e *updateEngine) daemon(ctx context.Context) error {
	if err := e.init(); err != nil {
		return err
	}
	lock, err := fileLock(filepath.Join(e.stateDir, "daemon.lock"))
	if err != nil {
		return nil
	}
	defer lock.Close()
	timer := time.NewTimer(time.Minute)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-timer.C:
		}
		for _, name := range []string{"disable", "remove"} {
			if _, err := os.Stat(filepath.Join(e.moduleDir, name)); err == nil {
				return nil
			}
		}
		if _, err := moduleVersion(e.moduleDir); err != nil {
			return err
		}
		s, err := e.status()
		if err == nil && s.Settings.Enabled && !s.Running && s.PendingVersion == "" && e.now().Unix() >= nextDue(s, e.now().Unix()) {
			if err = e.operation("apply", "", true); err != nil {
				e.logf("[auto-update] %v", err)
			}
		}
		timer.Reset(time.Minute)
	}
}

var wifiInterfacePattern = regexp.MustCompile(`^wlan[0-9]+$`)

func wifiRoute(text string) bool {
	fields := strings.Fields(text)
	for i, s := range fields {
		if s == "dev" && i+1 < len(fields) {
			return wifiInterfacePattern.MatchString(fields[i+1])
		}
	}
	return false
}
func androidWifi(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	// Root's actual route matters; merely having Wi-Fi enabled is insufficient.
	// Unknown/vendor-specific routing is deferred rather than using cellular.
	b, err := exec.CommandContext(ctx, "/system/bin/ip", "-4", "route", "get", "1.1.1.1").Output()
	return err == nil && wifiRoute(string(b))
}
func installWithManager(ctx context.Context, archive string) error {
	type managerCommand struct {
		binary string
		args   []string
	}
	managers := []managerCommand{
		{"/data/adb/ksud", []string{"module", "install", archive}},
		{"/data/adb/ksu/bin/ksud", []string{"module", "install", archive}},
		{"/data/adb/apd", []string{"module", "install", archive}},
		{"/data/adb/magisk/magisk", []string{"--install-module", archive}},
	}
	for _, m := range managers {
		if regular(m.binary) != nil {
			continue
		}
		cmd := exec.CommandContext(ctx, m.binary, m.args...)
		cmd.Env = []string{"PATH=/data/adb/magisk:/system/bin:/system/xbin", "HOME=/data/adb", "TMPDIR=/data/adb/magicnet-updater", "MAGICNET_NONINTERACTIVE=1"}
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("module manager installation failed: %w", err)
		}
		return nil
	}
	return errors.New("supported root module manager not found; use the verified installer")
}
func updaterCLI(args []string) error {
	e := newUpdateEngine()
	if len(args) == 0 {
		return errors.New("usage: update {status|check|apply|configure <0|1> <hours> <0|1>|daemon}")
	}
	switch args[0] {
	case "status":
		if len(args) != 1 {
			return errors.New("status takes no arguments")
		}
		s, err := e.status()
		if err != nil {
			return err
		}
		s.NextCheck = nextDue(s, e.now().Unix())
		return json.NewEncoder(os.Stdout).Encode(s)
	case "check", "apply":
		if len(args) != 1 {
			return errors.New("update action takes no arguments")
		}
		return e.operation(args[0], "", false)
	case "configure":
		if len(args) != 4 || (args[1] != "0" && args[1] != "1") || (args[3] != "0" && args[3] != "1") {
			return errors.New("configure requires enabled 0|1, hours 1-168, Wi-Fi-only 0|1")
		}
		hours, err := strconv.Atoi(args[2])
		if err != nil {
			return err
		}
		return e.configure(args[1] == "1", hours, args[3] == "1")
	case "daemon":
		if len(args) != 1 {
			return errors.New("daemon takes no arguments")
		}
		return e.daemon(context.Background())
	default:
		return errors.New("unknown updater command")
	}
}
func smartInstallerCLI(args []string) error {
	flags := flag.NewFlagSet("smart-installer", flag.ContinueOnError)
	config := flags.String("config", "", "trusted MagicNet installer configuration")
	out := flags.String("out", "", "private prepared module ZIP")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || *config == "" || *out == "" {
		return errors.New("config and out are required")
	}
	var cfg struct {
		Repository string `json:"repository"`
		ModuleID   string `json:"module_id"`
	}
	if err := readBoundedJSON(*config, &cfg, 65536); err != nil {
		return err
	}
	if cfg.Repository != updateRepository || cfg.ModuleID != "MagicNet" {
		return errors.New("smart installer only accepts the official MagicNet repository")
	}
	return newUpdateEngine().operation("prepare", *out, false)
}
