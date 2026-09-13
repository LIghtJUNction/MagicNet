// MagicNet's small, dependency-free component bootstrap. It never executes
// downloaded code: it verifies and stages the release-pinned payloads first.
package main

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

const maxPayload = int64(512 << 20)

var hexHash = regexp.MustCompile(`^[0-9a-f]{64}$`)
var componentID = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
var repositoryID = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
var releaseVersion = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)

type payloadFile struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Mode   uint32 `json:"mode"`
}
type component struct {
	ID     string        `json:"id"`
	SHA256 string        `json:"sha256"`
	Size   int64         `json:"size"`
	Asset  string        `json:"asset"`
	Files  []payloadFile `json:"files"`
}
type manifest struct {
	Schema       int         `json:"schema"`
	Module       string      `json:"module"`
	Version      string      `json:"version"`
	Architecture string      `json:"architecture"`
	Repository   string      `json:"repository"`
	Components   []component `json:"components"`
}
type options struct {
	Archive, ModuleDir, PreviousDir, CacheDir string
	Offline                                   bool
	// Injected only by Go tests; no arbitrary download-URL override in the CLI.
	client  *http.Client
	mirrors []string
	baseURL string
	log     io.Writer
}

func safeName(name string) bool {
	return name != "" && path.Clean(name) == name && !strings.HasPrefix(name, "/") &&
		name != "." && name != ".." && !strings.HasPrefix(name, "../") &&
		!strings.ContainsAny(name, "\\\x00\r\n\t")
}
func managedName(name string) bool {
	if !safeName(name) {
		return false
	}
	if strings.HasPrefix(name, "bin/") && strings.Count(name, "/") == 1 {
		return name != "bin/magicnet-components"
	}
	for _, prefix := range []string{"webroot/", ".config/sing-box/zashboard/", ".config/sing-box/rules/"} {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}
func (m manifest) validate() error {
	if m.Schema != 1 || m.Module != "MagicNet" || !releaseVersion.MatchString(m.Version) ||
		!repositoryID.MatchString(m.Repository) || m.Architecture != runtime.GOARCH || len(m.Components) == 0 || len(m.Components) > 128 {
		return errors.New("incompatible component manifest or architecture")
	}
	ids, names := map[string]bool{}, map[string]bool{}
	var total int64
	for _, c := range m.Components {
		if !componentID.MatchString(c.ID) || ids[c.ID] || !hexHash.MatchString(c.SHA256) ||
			c.Size <= 0 || c.Size > maxPayload || len(c.Files) == 0 || len(c.Files) > 20000 ||
			c.Asset != "MagicNet-component-"+c.ID+"-"+c.SHA256+".zip" {
			return fmt.Errorf("invalid component: %q", c.ID)
		}
		ids[c.ID] = true
		for _, f := range c.Files {
			if !managedName(f.Path) || names[f.Path] || !hexHash.MatchString(f.SHA256) ||
				f.Size < 0 || f.Size > maxPayload || (f.Mode != 0o644 && f.Mode != 0o755 && f.Mode != 0o600 && f.Mode != 0o700) {
				return fmt.Errorf("invalid component file: %q", f.Path)
			}
			names[f.Path] = true
			total += f.Size
			if total > 2<<30 {
				return errors.New("component size limit exceeded")
			}
		}
	}
	// A file may not be the parent of another file, even across components.
	for name := range names {
		for parent := path.Dir(name); parent != "."; parent = path.Dir(parent) {
			if names[parent] {
				return fmt.Errorf("overlapping component path: %s", name)
			}
		}
	}
	return nil
}

// Validate every existing path component. No extraction/copy/removal follows a
// symlink supplied by a previous installation or an app-owned caller directory.
func physical(name string, allowMissing bool) error {
	absolute, err := filepath.Abs(name)
	if err != nil {
		return err
	}
	current := string(filepath.Separator)
	for _, part := range strings.Split(strings.TrimPrefix(absolute, current), string(filepath.Separator)) {
		current = filepath.Join(current, part)
		st, err := os.Lstat(current)
		if os.IsNotExist(err) && allowMissing {
			continue
		}
		if err != nil {
			return err
		}
		if st.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("refusing symlink: %s", current)
		}
	}
	return nil
}
func regular(name string) error {
	if err := physical(name, false); err != nil {
		return err
	}
	st, err := os.Lstat(name)
	if err != nil {
		return err
	}
	if !st.Mode().IsRegular() {
		return fmt.Errorf("not a regular file: %s", name)
	}
	return nil
}
func validFile(name string, size int64, digest string) bool {
	if regular(name) != nil {
		return false
	}
	f, err := os.Open(name)
	if err != nil {
		return false
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.Size() != size {
		return false
	}
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(f, size+1))
	return err == nil && n == size && hex.EncodeToString(h.Sum(nil)) == digest
}
func copyVerified(reader io.Reader, target string, f payloadFile) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	h := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(out, h), io.LimitReader(reader, f.Size+1))
	if copyErr == nil {
		copyErr = out.Sync()
	}
	closeErr := out.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if n != f.Size || hex.EncodeToString(h.Sum(nil)) != f.SHA256 {
		return fmt.Errorf("checksum mismatch: %s", f.Path)
	}
	return os.Chmod(target, os.FileMode(f.Mode))
}
func zipIndex(z *zip.Reader) (map[string]*zip.File, error) {
	entries := map[string]*zip.File{}
	for _, f := range z.File {
		if f.FileInfo().IsDir() {
			if !safeName(strings.TrimSuffix(f.Name, "/")) {
				return nil, fmt.Errorf("unsafe ZIP directory: %q", f.Name)
			}
			continue
		}
		if !safeName(f.Name) || entries[f.Name] != nil {
			return nil, fmt.Errorf("unsafe/duplicate ZIP entry: %q", f.Name)
		}
		entries[f.Name] = f
	}
	return entries, nil
}
func stageZip(c component, entries map[string]*zip.File, stage string, exact bool) error {
	if exact && len(entries) != len(c.Files) {
		return errors.New("component ZIP contains unexpected files")
	}
	for _, f := range c.Files {
		entry := entries[f.Path]
		if entry == nil || !entry.Mode().IsRegular() || entry.UncompressedSize64 != uint64(f.Size) {
			return fmt.Errorf("missing/unsafe component entry: %s", f.Path)
		}
		r, err := entry.Open()
		if err != nil {
			return err
		}
		err = copyVerified(r, filepath.Join(stage, f.Path), f)
		closeErr := r.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}
func hasFiles(c component, entries map[string]*zip.File) bool {
	for _, f := range c.Files {
		if entries[f.Path] == nil {
			return false
		}
	}
	return true
}
func stageLocal(c component, root, stage string) (bool, error) {
	if root == "" {
		return false, nil
	}
	for _, f := range c.Files {
		if !validFile(filepath.Join(root, f.Path), f.Size, f.SHA256) {
			return false, nil
		}
	}
	for _, f := range c.Files {
		name := filepath.Join(root, f.Path)
		if err := regular(name); err != nil {
			return false, err
		}
		r, err := os.Open(name)
		if err != nil {
			return false, err
		}
		err = copyVerified(r, filepath.Join(stage, f.Path), f)
		closeErr := r.Close()
		if err != nil {
			return false, err
		}
		if closeErr != nil {
			return false, closeErr
		}
	}
	return true, nil
}

// Pure-Go Android builds cannot use libc/netd resolution. Keep bootstrap DNS
// independent of the not-yet-installed proxy, matching the existing downloader.
// These answers are never trusted for authenticity: HTTPS and payload hashes
// remain mandatory. Non-Android host tests keep their native resolver.
func bootstrapResolver(goos string) *net.Resolver {
	if goos != "android" {
		return nil
	}
	var attempt atomic.Uint32
	servers := []string{"223.5.5.5:53", "1.1.1.1:53", "8.8.8.8:53"}
	return &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
		server := servers[(attempt.Add(1)-1)%uint32(len(servers))]
		return (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, network, server)
	}}
}

func networkClient() *http.Client {
	roots, err := x509.SystemCertPool()
	if err != nil || roots == nil {
		roots = x509.NewCertPool()
	}
	for _, dir := range []string{"/apex/com.android.conscrypt/cacerts", "/system/etc/security/cacerts"} {
		files, _ := os.ReadDir(dir)
		for _, f := range files {
			if pem, err := os.ReadFile(filepath.Join(dir, f.Name())); err == nil {
				roots.AppendCertsFromPEM(pem)
			}
		}
	}
	return &http.Client{Timeout: 10 * time.Minute,
		Transport: &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: 8 * time.Second, Resolver: bootstrapResolver(runtime.GOOS)}).DialContext,
			TLSClientConfig:     &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12},
			TLSHandshakeTimeout: 8 * time.Second, ResponseHeaderTimeout: 15 * time.Second},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 || req.URL.Scheme != "https" || req.URL.User != nil {
				return errors.New("unsafe download redirect")
			}
			return nil
		}}
}
func (o options) printf(format string, args ...any) {
	if o.log != nil {
		fmt.Fprintf(o.log, format+"\n", args...)
	}
}

type route struct {
	url, name string
	speed     float64
}

func (o options) probe(rawURL, name string) route {
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", rawURL, nil)
	if err != nil {
		return route{url: rawURL, name: name}
	}
	req.Header.Set("Range", "bytes=0-65535")
	req.Header.Set("User-Agent", "MagicNet-components/1")
	response, err := o.client.Do(req)
	if err != nil {
		o.printf("[route] %s: unavailable", name)
		return route{url: rawURL, name: name}
	}
	defer response.Body.Close()
	if response.StatusCode != 200 && response.StatusCode != 206 {
		o.printf("[route] %s: HTTP %d", name, response.StatusCode)
		return route{url: rawURL, name: name}
	}
	n, err := io.Copy(io.Discard, io.LimitReader(response.Body, 65536))
	speed := float64(n) / time.Since(start).Seconds()
	if err != nil || n == 0 {
		speed = 0
	}
	o.printf("[route] %s: %.0f KiB/s", name, speed/1024)
	return route{url: rawURL, name: name, speed: speed}
}
func (o options) routes(direct string) []route {
	first := o.probe(direct, "GitHub")
	// A healthy direct path avoids all mirror probes and their extra traffic.
	if first.speed >= 256*1024 {
		return []route{first}
	}
	results := []route{first}
	ch := make(chan route, len(o.mirrors))
	for _, prefix := range o.mirrors {
		go func(prefix string) {
			ch <- o.probe(prefix+direct, strings.Split(strings.TrimPrefix(prefix, "https://"), "/")[0])
		}(prefix)
	}
	for range o.mirrors {
		results = append(results, <-ch)
	}
	sort.SliceStable(results, func(i, j int) bool { return results[i].speed > results[j].speed })
	return results
}

type progress struct {
	current, total int64
	last           time.Time
	o              options
	id             string
}

func (p *progress) Write(b []byte) (int, error) {
	p.current += int64(len(b))
	if time.Since(p.last) > time.Second || p.current == p.total {
		p.o.printf("[download] %s: %d%% (%d/%d KiB)", p.id, p.current*100/p.total, p.current/1024, p.total/1024)
		p.last = time.Now()
	}
	return len(b), nil
}
func (o options) download(c component, direct, destination string) error {
	candidates := o.routes(direct)
	// Direct may pass a tiny probe but stall during the actual download. In that
	// case, discover mirrors too rather than failing with no fallback.
	attempted := map[string]bool{}
	var last error
	for i := 0; i < len(candidates); i++ {
		candidate := candidates[i]
		if attempted[candidate.url] {
			continue
		}
		attempted[candidate.url] = true
		req, err := http.NewRequest("GET", candidate.url, nil)
		if err != nil {
			return err
		}
		req.Header.Set("User-Agent", "MagicNet-components/1")
		response, err := o.client.Do(req)
		if err == nil {
			if response.StatusCode != 200 {
				err = fmt.Errorf("HTTP %d", response.StatusCode)
			} else if response.ContentLength >= 0 && response.ContentLength != c.Size {
				err = errors.New("download size mismatch")
			} else {
				tmp, createErr := os.CreateTemp(o.CacheDir, ".download-")
				if createErr != nil {
					response.Body.Close()
					return createErr
				}
				h := sha256.New()
				p := &progress{total: c.Size, o: o, id: c.ID}
				n, copyErr := io.Copy(io.MultiWriter(tmp, h, p), io.LimitReader(response.Body, c.Size+1))
				if copyErr == nil {
					copyErr = tmp.Sync()
				}
				closeErr := tmp.Close()
				if copyErr != nil {
					err = copyErr
				} else if closeErr != nil {
					err = closeErr
				} else if n != c.Size || hex.EncodeToString(h.Sum(nil)) != c.SHA256 {
					err = errors.New("download checksum mismatch")
				} else {
					err = os.Rename(tmp.Name(), destination)
				}
				os.Remove(tmp.Name())
			}
			response.Body.Close()
		}
		if err == nil {
			return nil
		}
		last = err
		o.printf("[download] %s via %s failed: %v", c.ID, candidate.name, err)
		if len(candidates) == 1 {
			for _, prefix := range o.mirrors {
				candidates = append(candidates, o.probe(prefix+direct, prefix))
			}
		}
	}
	return fmt.Errorf("%s: all download routes failed: %w", c.ID, last)
}

// All components are validated in a private staging directory before this
// transaction starts. Rename existing files to rollback storage, then promote.
// An ordinary I/O error rolls back all earlier promotions, including removals.
func promote(stage, root string, files []payloadFile, obsolete []string) (err error) {
	backup := filepath.Join(stage, ".rollback")
	if err = os.Mkdir(backup, 0o700); err != nil {
		return err
	}
	type change struct {
		name               string
		existed, installed bool
	}
	changes := []change{}
	defer func() {
		if err == nil {
			return
		}
		var rollbackErrors []error
		for i := len(changes) - 1; i >= 0; i-- {
			c := changes[i]
			dst := filepath.Join(root, c.name)
			if c.installed {
				if e := os.Remove(dst); e != nil && !os.IsNotExist(e) {
					rollbackErrors = append(rollbackErrors, e)
				}
			}
			if c.existed {
				if e := os.Rename(filepath.Join(backup, c.name), dst); e != nil {
					rollbackErrors = append(rollbackErrors, e)
				}
			}
		}
		if len(rollbackErrors) > 0 {
			err = fmt.Errorf("%w; rollback errors: %v; recovery files: %s", err, rollbackErrors, backup)
		}
	}()
	items := append([]payloadFile{}, files...)
	for _, name := range obsolete {
		items = append(items, payloadFile{Path: name})
	}
	for i, f := range items {
		dst := filepath.Join(root, f.Path)
		if err = physical(dst, true); err != nil {
			return err
		}
		if err = os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		c := change{name: f.Path}
		if st, e := os.Lstat(dst); e == nil {
			if !st.Mode().IsRegular() {
				return fmt.Errorf("unsafe destination: %s", dst)
			}
			old := filepath.Join(backup, f.Path)
			if err = os.MkdirAll(filepath.Dir(old), 0o700); err != nil {
				return err
			}
			if err = os.Rename(dst, old); err != nil {
				return err
			}
			c.existed = true
		} else if !os.IsNotExist(e) {
			return e
		}
		changes = append(changes, c)
		if i < len(files) {
			if err = os.Rename(filepath.Join(stage, f.Path), dst); err != nil {
				return err
			}
			changes[len(changes)-1].installed = true
		}
	}
	return nil
}

func run(o options) error {
	if o.log == nil {
		o.log = io.Discard
	}
	if o.client == nil {
		o.client = networkClient()
	}
	if o.mirrors == nil {
		o.mirrors = []string{"https://gh-proxy.com/", "https://ghfast.top/", "https://ghproxy.net/"}
	}
	if o.Archive == "" || o.ModuleDir == "" || o.CacheDir == "" {
		return errors.New("archive, module directory and cache directory are required")
	}
	for _, dir := range []string{o.ModuleDir, o.CacheDir} {
		if err := physical(dir, true); err != nil {
			return err
		}
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
	}
	if err := physical(filepath.Join(o.CacheDir, "install.lock"), true); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(o.CacheDir, "install.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("another component installation is running")
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	archive, err := zip.OpenReader(o.Archive)
	if err != nil {
		return err
	}
	defer archive.Close()
	entries, err := zipIndex(&archive.Reader)
	if err != nil {
		return err
	}
	entry := entries["components.json"]
	if entry == nil || entry.UncompressedSize64 > 4<<20 {
		return errors.New("missing/oversized embedded component manifest")
	}
	reader, err := entry.Open()
	if err != nil {
		return err
	}
	raw, err := io.ReadAll(io.LimitReader(reader, 4<<20+1))
	reader.Close()
	if err != nil {
		return err
	}
	var m manifest
	if err = json.Unmarshal(raw, &m); err != nil {
		return err
	}
	if err = m.validate(); err != nil {
		return err
	}
	// Persist separately: module managers may overwrite components.json before
	// customize runs, while this file records the last successfully installed set.
	old := manifest{}
	if regular(filepath.Join(o.ModuleDir, "components.installed.json")) == nil {
		data, _ := os.ReadFile(filepath.Join(o.ModuleDir, "components.installed.json"))
		_ = json.Unmarshal(data, &old)
	}
	stage, err := os.MkdirTemp(filepath.Dir(o.ModuleDir), ".magicnet-components-")
	if err != nil {
		return err
	}
	keepRecovery := false
	defer func() {
		if !keepRecovery {
			os.RemoveAll(stage)
		}
	}()
	var files []payloadFile
	wanted := map[string]bool{}
	for _, c := range m.Components {
		for _, f := range c.Files {
			files = append(files, f)
			wanted[f.Path] = true
		}
		reused := false
		for _, root := range []string{o.ModuleDir, o.PreviousDir} {
			ok, e := stageLocal(c, root, stage)
			if e != nil {
				return e
			}
			if ok {
				o.printf("[reuse] %s: verified installed component", c.ID)
				reused = true
				break
			}
		}
		if reused {
			continue
		}
		if hasFiles(c, entries) {
			o.printf("[bundled] %s: verifying offline payload", c.ID)
			if err = stageZip(c, entries, stage, false); err != nil {
				return err
			}
			continue
		}
		cached := filepath.Join(o.CacheDir, c.SHA256+".zip")
		if !validFile(cached, c.Size, c.SHA256) {
			if err = physical(cached, true); err != nil {
				return err
			}
			if o.Offline {
				return fmt.Errorf("%s: required component is unavailable offline", c.ID)
			}
			base := o.baseURL
			if base == "" {
				base = "https://github.com/" + m.Repository + "/releases/download/" + url.PathEscape(m.Version) + "/"
			}
			if err = o.download(c, base+c.Asset, cached); err != nil {
				return err
			}
		} else {
			o.printf("[cache] %s: verified cached component", c.ID)
		}
		payload, e := zip.OpenReader(cached)
		if e != nil {
			return e
		}
		index, e := zipIndex(&payload.Reader)
		if e == nil {
			e = stageZip(c, index, stage, true)
		}
		payload.Close()
		if e != nil {
			return e
		}
	}
	obsolete := []string{}
	for _, c := range old.Components {
		for _, f := range c.Files {
			if managedName(f.Path) && !wanted[f.Path] {
				obsolete = append(obsolete, f.Path)
				wanted[f.Path] = true
			}
		}
	}
	stateFile := payloadFile{Path: "components.installed.json", SHA256: fmt.Sprintf("%x", sha256.Sum256(raw)), Size: int64(len(raw)), Mode: 0o600}
	if err = copyVerified(strings.NewReader(string(raw)), filepath.Join(stage, stateFile.Path), stateFile); err != nil {
		return err
	}
	files = append(files, stateFile)
	if err = promote(stage, o.ModuleDir, files, obsolete); err != nil {
		// Keep rollback files on any failed promotion for manual recovery. Network or
		// validation errors, which happen before promotion, never modify old files.
		keepRecovery = true
		return fmt.Errorf("%w (staging: %s)", err, stage)
	}
	o.printf("[done] %d components verified; %s is ready", len(m.Components), m.Version)
	return nil
}
func main() {
	o := options{log: os.Stdout}
	flag.StringVar(&o.Archive, "archive", "", "trusted core/full module ZIP")
	flag.StringVar(&o.ModuleDir, "module-dir", "", "module manager installation directory")
	flag.StringVar(&o.PreviousDir, "previous-dir", "/data/adb/modules/MagicNet", "previous installed module")
	flag.StringVar(&o.CacheDir, "cache-dir", "", "private component cache")
	flag.BoolVar(&o.Offline, "offline", false, "never access the network")
	flag.Parse()
	if o.CacheDir == "" {
		if runtime.GOOS == "android" {
			o.CacheDir = "/data/adb/magicnet-components"
		} else {
			o.CacheDir = filepath.Join(filepath.Dir(o.ModuleDir), ".magicnet-components-cache")
		}
	}
	if err := run(o); err != nil {
		fmt.Fprintln(os.Stderr, "[error]", err)
		os.Exit(1)
	}
}
