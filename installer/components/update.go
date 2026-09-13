package main

// The installer and device scheduler use the same release planner, cache and
// existing component verifier. Metadata always comes from GitHub, never mirrors.
import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const updateRepository = "LIghtJUNction/MagicNet"
const updateStateDir = "/data/adb/magicnet-update"

var errUpdateBusy = errors.New("update task already running")

type updateAsset struct {
	Name   string `json:"name"`
	URL    string `json:"browser_download_url"`
	Digest string `json:"digest"`
	Size   int64  `json:"size"`
}
type updateRelease struct {
	Tag        string        `json:"tag_name"`
	Draft      bool          `json:"draft"`
	Prerelease bool          `json:"prerelease"`
	Assets     []updateAsset `json:"assets"`
}
type updateSettings struct {
	Enabled       bool `json:"enabled"`
	IntervalHours int  `json:"interval_hours"`
	WiFiOnly      bool `json:"wifi_only"`
	AutoInstall   bool `json:"auto_install"`
}
type componentPlan struct {
	ID     string `json:"id"`
	SHA256 string `json:"sha256"`
	Source string `json:"source"`
	Bytes  int64  `json:"bytes"`
}
type updatePlan struct {
	Version       string          `json:"version"`
	Current       string          `json:"current"`
	Pending       bool            `json:"pending"`
	Needed        bool            `json:"needed"`
	Package       string          `json:"package"`
	DownloadBytes int64           `json:"download_bytes"`
	SavedBytes    int64           `json:"saved_bytes"`
	Components    []componentPlan `json:"components"`
	asset         updateAsset
	manifest      manifest
}
type updateStatus struct {
	Settings  updateSettings `json:"settings"`
	Phase     string         `json:"phase"`
	Error     string         `json:"error,omitempty"`
	LastCheck int64          `json:"last_check"`
	NextCheck int64          `json:"next_check"`
	Failures  int            `json:"failures"`
	Plan      *updatePlan    `json:"plan,omitempty"`
}
type releaseCache struct {
	ETag string          `json:"etag"`
	Body json.RawMessage `json:"body"`
}
type updater struct {
	o       options
	state   string
	pending string
	api     string // Only tests override the transport/endpoint.
	now     func() time.Time
	install func(string) error
}

func defaultUpdateSettings() updateSettings {
	return updateSettings{IntervalHours: 24, WiFiOnly: true, AutoInstall: true}
}
func (s updateSettings) validate() error {
	if s.IntervalHours < 1 || s.IntervalHours > 168 {
		return errors.New("interval_hours must be 1..168")
	}
	return nil
}
func readJSONFile(p string, dst any, max int64) error {
	if err := regular(p); err != nil {
		return err
	}
	f, err := os.Open(p)
	if err != nil {
		return err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return err
	}
	if int64(len(b)) > max {
		return errors.New("oversized JSON file")
	}
	return json.Unmarshal(b, dst)
}
func saveUpdateJSON(p string, v any) error {
	if err := physical(p, true); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
		return err
	}
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(p), ".update-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(append(b, '\n')); err == nil {
		err = f.Sync()
	}
	ce := f.Close()
	if err != nil {
		return err
	}
	if ce != nil {
		return ce
	}
	return os.Rename(f.Name(), p)
}
func updateLock(dir, name string) (func(), error) {
	if err := physical(dir, true); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	p := filepath.Join(dir, name)
	if err := physical(p, true); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, errUpdateBusy
		}
		return nil, err
	}
	return func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); _ = f.Close() }, nil
}
func (u updater) settings() (updateSettings, error) {
	s := defaultUpdateSettings()
	err := readJSONFile(filepath.Join(u.state, "settings.json"), &s, 16384)
	if err != nil && !os.IsNotExist(err) {
		return s, err
	}
	return s, s.validate()
}
func (u updater) status() (updateStatus, error) {
	s := updateStatus{Phase: "idle"}
	err := readJSONFile(filepath.Join(u.state, "status.json"), &s, 4<<20)
	if err != nil && !os.IsNotExist(err) {
		return s, err
	}
	s.Settings, err = u.settings()
	if err == nil && (s.Phase == "checking" || s.Phase == "downloading" || s.Phase == "installing") {
		// A killed task must not leave the UI disabled forever. Only the task
		// lock, not an old status file, proves an operation is still active.
		unlock, lockErr := updateLock(u.state, "operation.lock")
		if lockErr == nil {
			unlock()
			s.Phase = "error"
			s.Error = "previous update was interrupted; check again before installing"
			s.Plan = nil
		}
	}
	return s, err
}
func moduleVersion(dir string) string {
	p := filepath.Join(dir, "module.prop")
	if regular(p) != nil {
		return ""
	}
	f, err := os.Open(p)
	if err != nil {
		return ""
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 65537))
	if err != nil || len(b) > 65536 {
		return ""
	}
	id, version := "", ""
	for _, line := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok {
			if k == "id" {
				id = v
			}
			if k == "version" {
				version = v
			}
		}
	}
	if id != "MagicNet" || !releaseVersion.MatchString(version) {
		return ""
	}
	return version
}
func newerVersion(a, b string) bool {
	if b == "" {
		return true
	}
	aa, bb := strings.Split(strings.TrimPrefix(a, "v"), "."), strings.Split(strings.TrimPrefix(b, "v"), ".")
	if len(aa) != 3 || len(bb) != 3 {
		return false
	}
	for i := range aa {
		x, e := strconv.ParseUint(aa[i], 10, 64)
		y, f := strconv.ParseUint(bb[i], 10, 64)
		if e != nil || f != nil {
			return false
		}
		if x != y {
			return x > y
		}
	}
	return false
}
func validateUpdateAsset(a updateAsset, tag string) error {
	p, err := url.Parse(a.URL)
	if err != nil || p.Scheme != "https" || p.Host != "github.com" || p.User != nil || p.RawQuery != "" || p.Fragment != "" || p.Path != "/"+updateRepository+"/releases/download/"+tag+"/"+a.Name {
		return errors.New("untrusted release asset URL")
	}
	if a.Size <= 0 || a.Size > maxPayload || !strings.HasPrefix(a.Digest, "sha256:") || !hexHash.MatchString(strings.TrimPrefix(a.Digest, "sha256:")) {
		return errors.New("missing trusted release digest/size")
	}
	return nil
}
func (u updater) latest() (updateRelease, error) {
	var rel updateRelease
	cached := releaseCache{}
	cachePath := filepath.Join(u.state, "release.json")
	_ = readJSONFile(cachePath, &cached, 5<<20)
	address := u.api
	if address == "" {
		address = "https://api.github.com/repos/" + updateRepository + "/releases/latest"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", address, nil)
	if err != nil {
		return rel, err
	}
	req.Header.Set("User-Agent", "MagicNet-smart-update/1.1")
	req.Header.Set("Accept", "application/vnd.github+json")
	if cached.ETag != "" && len(cached.Body) > 0 {
		req.Header.Set("If-None-Match", cached.ETag)
	}
	resp, err := u.o.client.Do(req)
	if err != nil {
		return rel, errors.New("trusted GitHub release metadata unavailable")
	}
	defer resp.Body.Close()
	var raw []byte
	switch resp.StatusCode {
	case http.StatusNotModified:
		if len(cached.Body) == 0 {
			return rel, errors.New("304 without cached metadata")
		}
		raw = cached.Body
	case http.StatusOK:
		raw, err = io.ReadAll(io.LimitReader(resp.Body, 4<<20+1))
		if err != nil {
			return rel, err
		}
		if len(raw) > 4<<20 {
			return rel, errors.New("release metadata too large")
		}
	default:
		return rel, fmt.Errorf("GitHub metadata HTTP %d", resp.StatusCode)
	}
	if err = json.Unmarshal(raw, &rel); err != nil {
		return rel, err
	}
	if rel.Draft || rel.Prerelease || !releaseVersion.MatchString(rel.Tag) {
		return rel, errors.New("latest release is not a stable MagicNet module")
	}
	if resp.StatusCode == http.StatusOK {
		if err = saveUpdateJSON(cachePath, releaseCache{resp.Header.Get("ETag"), raw}); err != nil {
			return rel, err
		}
	}
	return rel, nil
}
func releaseAsset(rel updateRelease, name string) (updateAsset, error) {
	var found updateAsset
	for _, a := range rel.Assets {
		if a.Name == name {
			if found.Name != "" {
				return found, errors.New("duplicate release asset")
			}
			found = a
		}
	}
	if found.Name == "" {
		return found, fmt.Errorf("release is missing %s", name)
	}
	return found, validateUpdateAsset(found, rel.Tag)
}
func (u updater) blob(a updateAsset, metadata bool) (string, error) {
	if err := physical(u.o.CacheDir, true); err != nil {
		return "", err
	}
	if err := os.MkdirAll(u.o.CacheDir, 0700); err != nil {
		return "", err
	}
	h := strings.TrimPrefix(a.Digest, "sha256:")
	dest := filepath.Join(u.o.CacheDir, h+".zip")
	if validFile(dest, a.Size, h) {
		return dest, nil
	}
	if err := physical(dest, true); err != nil {
		return "", err
	}
	c := component{ID: a.Name, SHA256: h, Size: a.Size}
	if !metadata {
		if err := u.o.download(c, a.URL, dest); err != nil {
			return "", err
		}
		return dest, nil
	}
	// A tiny signed-by-digest manifest does not need several speed-test downloads.
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", a.URL, nil)
	if err != nil {
		return "", err
	}
	resp, err := u.o.client.Do(req)
	if err != nil {
		return "", errors.New("component manifest unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("component manifest HTTP %d", resp.StatusCode)
	}
	temp, err := os.CreateTemp(u.o.CacheDir, ".metadata-")
	if err != nil {
		return "", err
	}
	defer os.Remove(temp.Name())
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(temp, hash), io.LimitReader(resp.Body, a.Size+1))
	ce := temp.Close()
	if err != nil {
		return "", err
	}
	if ce != nil {
		return "", ce
	}
	if n != a.Size || hex.EncodeToString(hash.Sum(nil)) != h {
		return "", errors.New("manifest checksum mismatch")
	}
	if err = os.Rename(temp.Name(), dest); err != nil {
		return "", err
	}
	return dest, nil
}
func localComponent(c component, root string) bool {
	if root == "" {
		return false
	}
	for _, f := range c.Files {
		if !validFile(filepath.Join(root, f.Path), f.Size, f.SHA256) {
			return false
		}
	}
	return true
}
func (u updater) plan() (updatePlan, error) {
	p := updatePlan{Current: moduleVersion(u.o.ModuleDir), Components: []componentPlan{}}
	rel, err := u.latest()
	if err != nil {
		return p, err
	}
	p.Version = rel.Tag
	if staged := moduleVersion(u.pending); staged != "" && staged != rel.Tag {
		return p, errors.New("a different module version is already staged; resolve it before updating")
	}
	if p.Current != "" && newerVersion(p.Current, rel.Tag) {
		return p, errors.New("refusing a module downgrade")
	}
	ma, err := releaseAsset(rel, "components.json")
	if err != nil {
		return p, err
	}
	if ma.Size > 4<<20 {
		return p, errors.New("oversized component manifest")
	}
	filename, err := u.blob(ma, true)
	if err != nil {
		return p, err
	}
	if err = readJSONFile(filename, &p.manifest, 4<<20); err != nil {
		return p, err
	}
	if err = p.manifest.validate(); err != nil {
		return p, err
	}
	if p.manifest.Version != rel.Tag || p.manifest.Repository != updateRepository {
		return p, errors.New("manifest release mismatch")
	}
	core, err := releaseAsset(rel, "MagicNet-core.zip")
	if err != nil {
		return p, err
	}
	full, err := releaseAsset(rel, "MagicNet-full.zip")
	if err != nil {
		return p, err
	}
	p.Pending = moduleVersion(u.pending) == p.Version
	if p.Pending {
		for _, c := range p.manifest.Components {
			if !localComponent(c, u.pending) {
				p.Pending = false
				break
			}
		}
	}
	missing := int64(0)
	changed := false
	for _, c := range p.manifest.Components {
		a, e := releaseAsset(rel, c.Asset)
		if e != nil {
			return p, e
		}
		if a.Size != c.Size || a.Digest != "sha256:"+c.SHA256 {
			return p, errors.New("component differs from trusted release metadata")
		}
		row := componentPlan{ID: c.ID, SHA256: c.SHA256, Source: "download", Bytes: c.Size}
		switch {
		case p.Pending && localComponent(c, u.pending):
			row.Source = "pending"
			row.Bytes = 0
		case localComponent(c, u.o.ModuleDir):
			row.Source = "installed"
			row.Bytes = 0
			p.Pending = false
		case validFile(filepath.Join(u.o.CacheDir, c.SHA256+".zip"), c.Size, c.SHA256):
			row.Source = "cache"
			row.Bytes = 0
			changed = true
			p.Pending = false
		default:
			changed = true
			p.Pending = false
		}
		p.Components = append(p.Components, row)
		missing += row.Bytes
	}
	p.Needed = !p.Pending && (p.Current != p.Version || changed)
	coreBytes := core.Size
	if validFile(filepath.Join(u.o.CacheDir, strings.TrimPrefix(core.Digest, "sha256:")+".zip"), core.Size, strings.TrimPrefix(core.Digest, "sha256:")) {
		coreBytes = 0
	}
	fullBytes := full.Size
	if validFile(filepath.Join(u.o.CacheDir, strings.TrimPrefix(full.Digest, "sha256:")+".zip"), full.Size, strings.TrimPrefix(full.Digest, "sha256:")) {
		fullBytes = 0
	}
	p.asset = core
	p.Package = "core"
	p.DownloadBytes = coreBytes + missing
	if fullBytes < p.DownloadBytes {
		p.asset = full
		p.Package = "full"
		p.DownloadBytes = fullBytes
	}
	if !p.Needed {
		p.DownloadBytes = 0
	}
	p.SavedBytes = full.Size - p.DownloadBytes
	if p.SavedBytes < 0 {
		p.SavedBytes = 0
	}
	return p, nil
}
func verifyUpdateBundle(file string, p updatePlan) error {
	z, err := zip.OpenReader(file)
	if err != nil {
		return err
	}
	defer z.Close()
	entries, err := zipIndex(&z.Reader)
	if err != nil {
		return err
	}
	for name, limit := range map[string]uint64{"module.prop": 65536, "components.json": 4 << 20} {
		f := entries[name]
		if f == nil || !f.Mode().IsRegular() || f.UncompressedSize64 > limit {
			return errors.New("invalid update bundle metadata")
		}
		r, e := f.Open()
		if e != nil {
			return e
		}
		b, e := io.ReadAll(io.LimitReader(r, int64(limit)+1))
		r.Close()
		if e != nil {
			return e
		}
		if name == "components.json" {
			var m manifest
			if e = json.Unmarshal(b, &m); e != nil {
				return e
			}
			a, _ := json.Marshal(m)
			want, _ := json.Marshal(p.manifest)
			if !bytes.Equal(a, want) {
				return errors.New("bundle manifest mismatch")
			}
		}
		if name == "module.prop" {
			id, version := "", ""
			for _, line := range strings.Split(string(b), "\n") {
				k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
				if ok {
					if k == "id" {
						if id != "" {
							return errors.New("duplicate module identity")
						}
						id = v
					}
					if k == "version" {
						if version != "" {
							return errors.New("duplicate module version")
						}
						version = v
					}
				}
			}
			if id != "MagicNet" || version != p.Version {
				return errors.New("bundle version mismatch")
			}
		}
	}
	return nil
}
func (u updater) prepare(p updatePlan) (string, error) {
	file, err := u.blob(p.asset, false)
	if err != nil {
		return "", err
	}
	if err = verifyUpdateBundle(file, p); err != nil {
		return "", err
	}
	// Populate exactly the shared component cache before invoking the manager.
	// The manager's existing bootstrap re-verifies and installs offline from it.
	if p.Package == "core" {
		for _, c := range p.manifest.Components {
			if localComponent(c, u.o.ModuleDir) || validFile(filepath.Join(u.o.CacheDir, c.SHA256+".zip"), c.Size, c.SHA256) {
				continue
			}
			address := "https://github.com/" + updateRepository + "/releases/download/" + p.Version + "/" + c.Asset
			if err = u.o.download(c, address, filepath.Join(u.o.CacheDir, c.SHA256+".zip")); err != nil {
				return "", err
			}
		}
	}
	return file, nil
}
func managerInstall(file string) error {
	// Absolute executable paths only. Never run a manager selected by caller PATH.
	choices := []struct {
		path string
		args []string
	}{
		{"/data/adb/ksu/bin/ksud", []string{"module", "install", file}},
		{"/data/adb/ap/bin/apd", []string{"module", "install", file}},
		{"/data/adb/magisk/magisk", []string{"--install-module", file}},
		{"/sbin/magisk", []string{"--install-module", file}},
		{"/debug_ramdisk/magisk", []string{"--install-module", file}},
	}
	for _, c := range choices {
		if st, e := os.Stat(c.path); e == nil && st.Mode().IsRegular() && st.Mode()&0111 != 0 {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
			defer cancel()
			cmd := exec.CommandContext(ctx, c.path, c.args...)
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
			cmd.WaitDelay = 10 * time.Second
			cmd.Env = []string{"PATH=/system/bin:/system/xbin:/data/adb/magisk", "HOME=/", "TMPDIR=/data/adb"}
			cmd.Stdout = os.Stderr
			cmd.Stderr = os.Stderr
			return cmd.Run()
		}
	}
	return errors.New("supported module manager not found; install the verified core/full ZIP manually")
}
func wifiConnected() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/system/bin/cmd", "wifi", "status").Output()
	return err == nil && strings.Contains(string(out), "Wifi is connected to")
}
func nextUpdate(now int64, s updateSettings, failures int) int64 {
	hours := s.IntervalHours
	if failures > 0 {
		hours = 1
		for i := 1; i < failures && hours < s.IntervalHours; i++ {
			hours *= 2
		}
		if hours > s.IntervalHours {
			hours = s.IntervalHours
		}
	}
	return now + int64(hours)*3600
}
func (u updater) perform(apply bool) error {
	unlock, err := updateLock(u.state, "operation.lock")
	if err != nil {
		return err
	}
	defer unlock()
	s, err := u.status()
	if err != nil {
		return err
	}
	s.Phase = "checking"
	s.Error = ""
	if err = saveUpdateJSON(filepath.Join(u.state, "status.json"), s); err != nil {
		return err
	}
	p, workErr := u.plan()
	s.LastCheck = u.now().Unix()
	s.Plan = nil
	if workErr == nil {
		s.Plan = &p
		switch {
		case p.Pending:
			s.Phase = "pending-reboot"
		case !p.Needed:
			s.Phase = "up-to-date"
		default:
			s.Phase = "available"
		}
		if apply && p.Needed {
			s.Phase = "downloading"
			if err = saveUpdateJSON(filepath.Join(u.state, "status.json"), s); err != nil {
				return err
			}
			var filename string
			filename, workErr = u.prepare(p)
			if workErr == nil {
				s.Phase = "installing"
				if err = saveUpdateJSON(filepath.Join(u.state, "status.json"), s); err != nil {
					return err
				}
				workErr = u.install(filename)
			}
			if workErr == nil {
				if moduleVersion(u.pending) != p.Version {
					workErr = errors.New("manager returned without the expected staged module")
				} else {
					s.Phase = "pending-reboot"
				}
			}
		}
	}
	if workErr != nil {
		s.Phase = "error"
		s.Error = workErr.Error()
		s.Failures++
	} else {
		s.Failures = 0
	}
	s.NextCheck = nextUpdate(s.LastCheck, s.Settings, s.Failures)
	if err = saveUpdateJSON(filepath.Join(u.state, "status.json"), s); err != nil {
		return err
	}
	return workErr
}
func (u updater) daemon() error {
	unlock, err := updateLock(u.state, "daemon.lock")
	if err != nil {
		return err
	}
	defer unlock()
	for {
		s, e := u.status()
		if e != nil {
			return e
		}
		if !s.Settings.Enabled {
			return nil
		}
		for _, name := range []string{"disable", "remove"} {
			if _, e := os.Stat(filepath.Join(u.o.ModuleDir, name)); e == nil {
				return nil
			}
		}
		if u.now().Unix() >= s.NextCheck {
			if s.Settings.WiFiOnly && !wifiConnected() {
				s.Phase = "waiting-wifi"
				s.NextCheck = u.now().Unix() + 3600
				_ = saveUpdateJSON(filepath.Join(u.state, "status.json"), s)
			} else {
				_ = u.perform(s.Settings.AutoInstall)
			}
		}
		time.Sleep(time.Minute)
	}
}
func updateMain(args []string) error {
	if len(args) == 0 {
		return errors.New("update: status|check|apply|configure|daemon|fetch")
	}
	command := args[0]
	fs := flag.NewFlagSet("update", flag.ContinueOnError)
	root := fs.String("module-dir", "/data/adb/modules/MagicNet", "installed module")
	state := fs.String("state-dir", updateStateDir, "private update state")
	cache := fs.String("cache-dir", "/data/adb/magicnet-components", "shared verified component cache")
	pending := fs.String("pending-dir", "/data/adb/modules_update/MagicNet", "manager staging directory")
	enabled := fs.Bool("enabled", false, "scheduled updates")
	interval := fs.Int("interval-hours", 24, "check interval, 1..168 hours")
	wifi := fs.Bool("wifi-only", true, "defer automatic work until Wi-Fi is connected")
	auto := fs.Bool("auto-install", true, "stage updates automatically, never reboot")
	out := fs.String("out", "", "verified installer ZIP output")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected update arguments")
	}
	u := updater{o: options{ModuleDir: *root, CacheDir: *cache, client: networkClient(), mirrors: []string{"https://ghfast.top/", "https://ghproxy.net/", "https://gh-proxy.com/"}, log: os.Stderr}, state: *state, pending: *pending, now: time.Now, install: managerInstall}
	switch command {
	case "status":
		s, e := u.status()
		if e != nil {
			return e
		}
		return json.NewEncoder(os.Stdout).Encode(s)
	case "configure":
		s := updateSettings{*enabled, *interval, *wifi, *auto}
		if err := s.validate(); err != nil {
			return err
		}
		if err := saveUpdateJSON(filepath.Join(u.state, "settings.json"), s); err != nil {
			return err
		}
		// Interval changes take effect without waiting for the old deadline.
		unlock, err := updateLock(u.state, "operation.lock")
		if err == nil {
			status, readErr := u.status()
			if readErr == nil {
				status.NextCheck = 0
				readErr = saveUpdateJSON(filepath.Join(u.state, "status.json"), status)
			}
			unlock()
			if readErr != nil {
				return readErr
			}
		}
		return u.startDaemon()
	case "check", "apply":
		return u.perform(command == "apply")
	case "start-daemon":
		return u.startDaemon()
	case "daemon":
		return u.daemon()
	case "fetch":
		if *out == "" {
			return errors.New("output ZIP required")
		}
		unlock, err := updateLock(u.state, "operation.lock")
		if err != nil {
			return err
		}
		defer unlock()
		p, err := u.plan()
		if err != nil {
			return err
		}
		b, _ := json.Marshal(p)
		fmt.Fprintln(os.Stderr, "[plan]", string(b))
		if !p.Needed {
			return saveUpdateJSON(*out+".current", p)
		}
		file, err := u.prepare(p)
		if err != nil {
			return err
		}
		if err = physical(*out, true); err != nil {
			return err
		}
		in, err := os.Open(file)
		if err != nil {
			return err
		}
		defer in.Close()
		return copyVerified(in, *out, payloadFile{Path: "module.zip", SHA256: strings.TrimPrefix(p.asset.Digest, "sha256:"), Size: p.asset.Size, Mode: 0600})
	default:
		return errors.New("unsupported update command")
	}
}

func (u updater) startDaemon() error {
	s, err := u.settings()
	if err != nil {
		return err
	}
	if !s.Enabled {
		return nil
	}
	unlock, err := updateLock(u.state, "daemon.lock")
	if errors.Is(err, errUpdateBusy) {
		return nil
	}
	if err != nil {
		return err
	}
	unlock()
	logPath := filepath.Join(u.state, "scheduler.log")
	if err = physical(logPath, true); err != nil {
		return err
	}
	if st, e := os.Stat(logPath); e == nil && st.Size() > 128<<10 {
		if err = os.Truncate(logPath, 0); err != nil {
			return err
		}
	}
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := daemonCommand(runtime.GOOS, executable, u)
	cmd.Env = []string{"PATH=/system/bin:/system/xbin", "HOME=/"}
	cmd.Stdin = nil
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err = cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}

// Android may kill an entire app cgroup after WebUI closes. Reuse the module's
// tested cgroup detachment before exec; setsid alone only detaches the terminal.
func daemonCommand(goos, executable string, u updater) *exec.Cmd {
	args := []string{"update", "daemon", "--module-dir", u.o.ModuleDir, "--state-dir", u.state, "--cache-dir", u.o.CacheDir, "--pending-dir", u.pending}
	if goos != "android" {
		return exec.Command(executable, args...)
	}
	script := `. "$1/lib/magicnet/primitives.sh" || exit 1
magicnet_detach_pid_from_app_cgroup "$$" || exit 1
shift
exec "$@"`
	wrapped := []string{"-c", script, "magicnet-update-daemon", u.o.ModuleDir, executable}
	return exec.Command("/system/bin/sh", append(wrapped, args...)...)
}

// Compatibility entrypoint for the existing downloader customize.sh. The
// reusable generic downloader remains available for non-MagicNet templates.
func smartInstallerMain(args []string) error {
	fs := flag.NewFlagSet("module-downloader", flag.ContinueOnError)
	config := fs.String("config", "download.json", "installer target")
	out := fs.String("out", "module.zip", "verified output ZIP")
	if err := fs.Parse(args); err != nil {
		return err
	}
	var cfg struct {
		Repository string `json:"repository"`
		ModuleID   string `json:"module_id"`
		Asset      string `json:"asset"`
	}
	if err := readJSONFile(*config, &cfg, 65536); err != nil {
		return err
	}
	if cfg.Repository != updateRepository || cfg.ModuleID != "MagicNet" || (cfg.Asset != "MagicNet.zip" && cfg.Asset != "MagicNet-core.zip") {
		return errors.New("smart installer requires the MagicNet core channel")
	}
	return updateMain([]string{"fetch", "--out", *out})
}
