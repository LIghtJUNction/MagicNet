// magicnet-components resolves only the immutable manifest shipped in a module.
// It never replaces that manifest with a mutable "latest" response.
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
	"time"
)

const maxPayload = int64(1 << 30)

type File struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Mode   uint32 `json:"mode"`
}
type Component struct {
	ID      string `json:"id"`
	Version string `json:"version"`
	Asset   string `json:"asset"`
	SHA256  string `json:"sha256"`
	Size    int64  `json:"size"`
	Files   []File `json:"files"`
}
type Manifest struct {
	Schema     int         `json:"schema"`
	Module     string      `json:"module"`
	Version    string      `json:"version"`
	Arch       string      `json:"arch"`
	BaseURL    string      `json:"base_url"`
	Mirrors    []string    `json:"mirrors"`
	Components []Component `json:"components"`
}

var hashPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var idPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
var versionPattern = regexp.MustCompile(`^v?[0-9][A-Za-z0-9._-]*$`)

func safePath(p string) bool {
	return p != "" && p != "." && p != ".." && !strings.HasPrefix(p, "../") &&
		!strings.ContainsAny(p, "\\\x00\r\n\t") && !path.IsAbs(p) && path.Clean(p) == p
}
func belongs(id, p string) bool {
	switch id {
	case "webui":
		return strings.HasPrefix(p, "webroot/")
	case "dashboard":
		return strings.HasPrefix(p, ".config/sing-box/zashboard/")
	case "rules":
		return strings.HasPrefix(p, ".config/sing-box/") && strings.HasSuffix(p, ".srs")
	default:
		return p == "bin/"+id && id != "magicnet-components" && id != "magicnet-cli" && id != "magicnet-mcp-server"
	}
}
func secureURL(raw string) bool {
	u, e := url.Parse(raw)
	return e == nil && u.Scheme == "https" && u.Host != "" && u.User == nil && u.RawQuery == "" && u.Fragment == ""
}
func (m Manifest) validate() error {
	if m.Schema != 1 || m.Module != "MagicNet" || m.Arch != "arm64" || !versionPattern.MatchString(m.Version) ||
		!secureURL(m.BaseURL) || !strings.HasSuffix(m.BaseURL, "/releases/download/"+m.Version+"/") ||
		len(m.Components) == 0 || len(m.Components) > 64 || len(m.Mirrors) > 8 {
		return errors.New("unsupported component manifest")
	}
	for _, mirror := range m.Mirrors {
		if !secureURL(mirror) || !strings.HasSuffix(mirror, "/") {
			return errors.New("unsafe mirror URL")
		}
	}
	ids := map[string]bool{}
	paths := map[string]bool{}
	total := int64(0)
	for _, c := range m.Components {
		if !idPattern.MatchString(c.ID) || ids[c.ID] || !hashPattern.MatchString(c.Version) ||
			!hashPattern.MatchString(c.SHA256) || !safePath(c.Asset) || strings.Contains(c.Asset, "/") ||
			!strings.HasPrefix(c.Asset, "MagicNet-component-"+c.ID+"-arm64-") || !strings.HasSuffix(c.Asset, ".zip") ||
			c.Size <= 0 || c.Size > maxPayload || len(c.Files) == 0 {
			return fmt.Errorf("invalid component: %s", c.ID)
		}
		ids[c.ID] = true
		for _, f := range c.Files {
			if !safePath(f.Path) || !belongs(c.ID, f.Path) || paths[f.Path] || !hashPattern.MatchString(f.SHA256) ||
				f.Size < 0 || f.Size > maxPayload || (f.Mode != 0644 && f.Mode != 0755) {
				return fmt.Errorf("invalid component path: %s", f.Path)
			}
			paths[f.Path] = true
			total += f.Size
			if total > maxPayload {
				return errors.New("component payload limit exceeded")
			}
		}
	}
	if !ids["sing-box"] {
		return errors.New("manifest has no sing-box component")
	}
	for p := range paths {
		for parent := path.Dir(p); parent != "."; parent = path.Dir(parent) {
			if paths[parent] {
				return errors.New("overlapping component paths")
			}
		}
	}
	return nil
}

// Refuse symlinks at every level, not just at the final filename. User state
// outside the listed immutable files is never read, overwritten or deleted.
func noLinks(p string) error {
	p, e := filepath.Abs(p)
	if e != nil {
		return e
	}
	for {
		st, e := os.Lstat(p)
		if e != nil && !os.IsNotExist(e) {
			return e
		}
		if e == nil && st.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("symlink is not allowed: %s", p)
		}
		parent := filepath.Dir(p)
		if parent == p {
			return nil
		}
		p = parent
	}
}
func fileOK(root string, f File) bool {
	p := filepath.Join(root, filepath.FromSlash(f.Path))
	if noLinks(p) != nil {
		return false
	}
	st, e := os.Lstat(p)
	if e != nil || !st.Mode().IsRegular() || st.Size() != f.Size {
		return false
	}
	in, e := os.Open(p)
	if e != nil {
		return false
	}
	defer in.Close()
	h := sha256.New()
	n, e := io.Copy(h, io.LimitReader(in, f.Size+1))
	return e == nil && n == f.Size && hex.EncodeToString(h.Sum(nil)) == f.SHA256
}
func filesOK(root string, c Component) bool {
	for _, f := range c.Files {
		if !fileOK(root, f) {
			return false
		}
	}
	return true
}
func copyFile(in io.Reader, dest string, f File) error {
	if err := noLinks(dest); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0700); err != nil {
		return err
	}
	out, e := os.OpenFile(dest, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(out, h), io.LimitReader(in, f.Size+1))
	closeErr := out.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if n != f.Size || hex.EncodeToString(h.Sum(nil)) != f.SHA256 {
		return fmt.Errorf("checksum mismatch: %s", f.Path)
	}
	return os.Chmod(dest, os.FileMode(f.Mode))
}
func copyInstalled(root, stage string, c Component) error {
	for _, f := range c.Files {
		source := filepath.Join(root, filepath.FromSlash(f.Path))
		if err := noLinks(source); err != nil {
			return err
		}
		in, e := os.Open(source)
		if e != nil {
			return e
		}
		e = copyFile(in, filepath.Join(stage, filepath.FromSlash(f.Path)), f)
		in.Close()
		if e != nil {
			return e
		}
	}
	return nil
}
func zipIndex(z *zip.ReadCloser, strict bool) (map[string]*zip.File, error) {
	entries := map[string]*zip.File{}
	seen := map[string]bool{}
	for _, f := range z.File {
		p := strings.TrimSuffix(f.Name, "/")
		if !safePath(p) || seen[p] {
			return nil, fmt.Errorf("unsafe/duplicate archive path: %s", f.Name)
		}
		seen[p] = true
		if f.FileInfo().IsDir() {
			continue
		}
		if strict && !f.Mode().IsRegular() {
			return nil, fmt.Errorf("component archive has non-regular file: %s", p)
		}
		entries[p] = f
	}
	return entries, nil
}
func extract(z *zip.ReadCloser, stage string, c Component, strict bool) error {
	entries, e := zipIndex(z, strict)
	if e != nil {
		return e
	}
	if strict && len(entries) != len(c.Files) {
		return errors.New("unexpected files in component archive")
	}
	for _, f := range c.Files {
		entry, ok := entries[f.Path]
		if !ok || !entry.Mode().IsRegular() || entry.UncompressedSize64 != uint64(f.Size) {
			return fmt.Errorf("missing/invalid archive file: %s", f.Path)
		}
		in, e := entry.Open()
		if e != nil {
			return e
		}
		e = copyFile(in, filepath.Join(stage, filepath.FromSlash(f.Path)), f)
		in.Close()
		if e != nil {
			return e
		}
	}
	return nil
}
func hasBundle(z *zip.ReadCloser, c Component) bool {
	entries, e := zipIndex(z, false)
	if e != nil {
		return false
	}
	for _, f := range c.Files {
		if _, ok := entries[f.Path]; !ok {
			return false
		}
	}
	return true
}

type fetchFunc func(context.Context, Manifest, Component, string) error

type manager struct {
	fetch fetchFunc
	log   io.Writer
}

func (x manager) install(ctx context.Context, m Manifest, root, previous, bundle, cache string) error {
	if err := m.validate(); err != nil {
		return err
	}
	for _, p := range []string{root} {
		if e := noLinks(p); e != nil {
			return e
		}
	}
	if err := os.MkdirAll(root, 0755); err != nil {
		return err
	}
	// Stage alongside MODPATH to make final renames same-filesystem and reversible.
	stage, e := os.MkdirTemp(filepath.Dir(root), ".magicnet-components-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(stage)
	z, e := zip.OpenReader(bundle)
	if e != nil {
		return e
	}
	defer z.Close()
	if _, e = zipIndex(z, false); e != nil {
		return e
	}
	props, e := z.Open("module.prop")
	if e != nil {
		return e
	}
	raw, e := io.ReadAll(io.LimitReader(props, 65537))
	props.Close()
	if e != nil || len(raw) > 65536 {
		return errors.New("invalid module metadata")
	}
	values := map[string]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok {
			values[key] = value
		}
	}
	if values["id"] != m.Module || values["version"] != m.Version {
		return errors.New("manifest does not match module version")
	}
	for _, c := range m.Components {
		fmt.Fprintf(x.log, "[components] Checking %s (%s)\n", c.ID, c.Version[:12])
		switch {
		case hasBundle(z, c):
			fmt.Fprintf(x.log, "[components] %s: bundled, no download\n", c.ID)
			if e = extract(z, stage, c, false); e != nil {
				return e
			}
		case filesOK(root, c):
			fmt.Fprintf(x.log, "[components] %s: verified installed files, no download\n", c.ID)
			if e = copyInstalled(root, stage, c); e != nil {
				return e
			}
		case previous != "" && filesOK(previous, c):
			fmt.Fprintf(x.log, "[components] %s: reuse previous installation, no download\n", c.ID)
			if e = copyInstalled(previous, stage, c); e != nil {
				return e
			}
		default:
			if e = noLinks(cache); e != nil {
				return e
			}
			if e = os.MkdirAll(cache, 0700); e != nil {
				return e
			}
			if e = os.Chmod(cache, 0700); e != nil {
				return e
			}
			cached := filepath.Join(cache, c.SHA256+".zip")
			cf := File{Path: c.SHA256 + ".zip", SHA256: c.SHA256, Size: c.Size}
			if !fileOK(cache, cf) {
				if e = noLinks(cached); e != nil {
					return e
				}
				temp, e := os.CreateTemp(cache, ".download-*")
				if e != nil {
					return e
				}
				name := temp.Name()
				temp.Close()
				e = x.fetch(ctx, m, c, name)
				if e == nil && !fileOK(cache, File{Path: filepath.Base(name), SHA256: c.SHA256, Size: c.Size}) {
					e = errors.New("download checksum mismatch")
				}
				if e == nil {
					e = os.Rename(name, cached)
				}
				os.Remove(name)
				if e != nil {
					return fmt.Errorf("%s: %w", c.ID, e)
				}
			} else {
				fmt.Fprintf(x.log, "[components] %s: verified download cache, no download\n", c.ID)
			}
			archive, e := zip.OpenReader(cached)
			if e != nil {
				return e
			}
			e = extract(archive, stage, c, true)
			archive.Close()
			if e != nil {
				return e
			}
		}
	}
	// Nothing touches the destination until every component has been verified.
	if e = promote(root, stage, m.Components); e != nil {
		return e
	}
	pruneCache(cache, m, x.log)
	fmt.Fprintln(x.log, "[components] All components verified and installed")
	return nil
}

func promote(root, stage string, components []Component) (err error) {
	backup, e := os.MkdirTemp(filepath.Dir(root), ".magicnet-component-rollback-")
	if e != nil {
		return e
	}
	preserveBackup := false
	defer func() {
		if !preserveBackup {
			_ = os.RemoveAll(backup)
		}
	}()
	type change struct {
		dest, old string
		existed   bool
	}
	var changes []change
	defer func() {
		if err != nil {
			for i := len(changes) - 1; i >= 0; i-- {
				c := changes[i]
				if e := os.Remove(c.dest); e != nil && !os.IsNotExist(e) {
					err = errors.Join(err, e)
					preserveBackup = true
				}
				if c.existed {
					if e := os.Rename(c.old, c.dest); e != nil {
						err = errors.Join(err, e)
						preserveBackup = true
					}
				}
			}
			if preserveBackup {
				err = errors.Join(err, fmt.Errorf("rollback data retained at %s", backup))
			}
		}
	}()
	// Preflight the complete destination tree before replacing a single file.
	for _, c := range components {
		for _, f := range c.Files {
			dest := filepath.Join(root, filepath.FromSlash(f.Path))
			if e = noLinks(dest); e != nil {
				return e
			}
			st, e := os.Lstat(dest)
			if e != nil && !os.IsNotExist(e) {
				return e
			}
			if e == nil && !st.Mode().IsRegular() {
				return fmt.Errorf("non-regular destination: %s", dest)
			}
		}
	}
	for _, c := range components {
		for _, f := range c.Files {
			dest := filepath.Join(root, filepath.FromSlash(f.Path))
			old := filepath.Join(backup, filepath.FromSlash(f.Path))
			if e = os.MkdirAll(filepath.Dir(dest), 0755); e != nil {
				return e
			}
			existed := false
			if _, e = os.Lstat(dest); e == nil {
				if e = os.MkdirAll(filepath.Dir(old), 0700); e != nil {
					return e
				}
				if e = os.Rename(dest, old); e != nil {
					return e
				}
				existed = true
			} else if !os.IsNotExist(e) {
				return e
			}
			changes = append(changes, change{dest, old, existed})
			if e = os.Rename(filepath.Join(stage, filepath.FromSlash(f.Path)), dest); e != nil {
				return e
			}
		}
	}
	return nil
}
func pruneCache(cache string, m Manifest, log io.Writer) {
	if noLinks(cache) != nil {
		return
	}
	keep := map[string]bool{}
	for _, c := range m.Components {
		keep[c.SHA256+".zip"] = true
	}
	entries, e := os.ReadDir(cache)
	if e != nil {
		return
	}
	for _, f := range entries {
		name := f.Name()
		// Only own content-addressed ZIPs, never arbitrary files or directories.
		if keep[name] || !strings.HasSuffix(name, ".zip") || !hashPattern.MatchString(strings.TrimSuffix(name, ".zip")) {
			continue
		}
		if f.Type().IsRegular() {
			if e := os.Remove(filepath.Join(cache, name)); e != nil {
				fmt.Fprintf(log, "[components] Cache cleanup: %v\n", e)
			}
		}
	}
}

func httpClient() *http.Client {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.ResponseHeaderTimeout = 10 * time.Second
	tr.TLSHandshakeTimeout = 10 * time.Second
	if runtime.GOOS == "android" {
		// Match the standalone installer: a CGO-free Android executable has no
		// libc resolver and must explicitly load Android's certificate stores.
		var attempt atomic.Uint32
		resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			servers := []string{"223.5.5.5:53", "1.1.1.1:53", "8.8.8.8:53"}
			server := servers[(attempt.Add(1)-1)%uint32(len(servers))]
			return (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, network, server)
		}}
		tr.DialContext = (&net.Dialer{Timeout: 10 * time.Second, Resolver: resolver}).DialContext
		roots, _ := x509.SystemCertPool()
		if roots == nil {
			roots = x509.NewCertPool()
		}
		for _, dir := range []string{"/system/etc/security/cacerts", "/apex/com.android.conscrypt/cacerts"} {
			files, _ := os.ReadDir(dir)
			for _, f := range files {
				if b, e := os.ReadFile(filepath.Join(dir, f.Name())); e == nil {
					roots.AppendCertsFromPEM(b)
				}
			}
		}
		tr.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	}
	return &http.Client{Transport: tr, Timeout: 10 * time.Minute, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return errors.New("too many redirects")
		}
		if req.URL.Scheme != "https" {
			return errors.New("non-HTTPS redirect")
		}
		return nil
	}}
}

type probeResult struct {
	url   string
	speed float64
	err   error
}

func probe(ctx context.Context, client *http.Client, address string) probeResult {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if e != nil {
		return probeResult{url: address, err: e}
	}
	req.Header.Set("Range", "bytes=0-65535")
	start := time.Now()
	resp, e := client.Do(req)
	if e != nil {
		return probeResult{url: address, err: e}
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 && resp.StatusCode != 206 {
		return probeResult{url: address, err: fmt.Errorf("HTTP %d", resp.StatusCode)}
	}
	n, e := io.Copy(io.Discard, io.LimitReader(resp.Body, 65536))
	if e != nil || n == 0 {
		return probeResult{url: address, err: errors.New("empty/failed speed probe")}
	}
	return probeResult{url: address, speed: float64(n) / time.Since(start).Seconds() / 1024}
}

type progress struct {
	name     string
	log      io.Writer
	n, total int64
	last     time.Time
}

func (p *progress) Write(b []byte) (int, error) {
	p.n += int64(len(b))
	if time.Since(p.last) >= time.Second || p.n == p.total {
		fmt.Fprintf(p.log, "[components] %s: %d%% (%d/%d KiB)\n", p.name, p.n*100/p.total, p.n/1024, p.total/1024)
		p.last = time.Now()
	}
	return len(b), nil
}
func download(ctx context.Context, client *http.Client, address, dest string, c Component, log io.Writer) error {
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if e != nil {
		return e
	}
	resp, e := client.Do(req)
	if e != nil {
		return e
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	if resp.ContentLength >= 0 && resp.ContentLength != c.Size {
		return errors.New("download size mismatch")
	}
	out, e := os.OpenFile(dest, os.O_WRONLY|os.O_TRUNC, 0600)
	if e != nil {
		return e
	}
	h := sha256.New()
	p := &progress{name: c.ID, log: log, total: c.Size}
	n, err := io.Copy(io.MultiWriter(out, h, p), io.LimitReader(resp.Body, c.Size+1))
	closeErr := out.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if n != c.Size || hex.EncodeToString(h.Sum(nil)) != c.SHA256 {
		return errors.New("download checksum mismatch")
	}
	return nil
}
func fetchNetwork(log io.Writer) fetchFunc {
	return fetchWithClient(httpClient(), log)
}
func fetchWithClient(client *http.Client, log io.Writer) fetchFunc {
	return func(ctx context.Context, m Manifest, c Component, dest string) error {
		direct := m.BaseURL + c.Asset
		result := probe(ctx, client, direct)
		fmt.Fprintf(log, "[components] Direct GitHub: %.0f KiB/s (%v)\n", result.speed, result.err)
		var failures []error
		if result.err == nil && result.speed >= 256 {
			if e := download(ctx, client, direct, dest, c, log); e == nil {
				return nil
			} else {
				failures = append(failures, e)
			}
		}
		results := make(chan probeResult, len(m.Mirrors))
		for _, mirror := range m.Mirrors {
			go func(prefix string) { results <- probe(ctx, client, prefix+direct) }(mirror)
		}
		var candidates []probeResult
		for range m.Mirrors {
			r := <-results
			host, _ := url.Parse(r.url)
			fmt.Fprintf(log, "[components] Mirror %s: %.0f KiB/s (%v)\n", host.Host, r.speed, r.err)
			// A mirror may reject Range while accepting a normal GET. Retain it
			// after measured routes; content hashes remain mandatory either way.
			candidates = append(candidates, r)
		}
		sort.Slice(candidates, func(i, j int) bool { return candidates[i].speed > candidates[j].speed })
		// Even failed/unsupported probes get a bounded normal-GET attempt.
		candidates = append(candidates, result)
		for _, r := range candidates {
			if e := download(ctx, client, r.url, dest, c, log); e == nil {
				return nil
			} else {
				failures = append(failures, e)
			}
		}
		return fmt.Errorf("no verified download; use the full offline package: %w", errors.Join(append(failures, errors.New("all routes failed"))...))
	}
}
func main() {
	manifest := flag.String("manifest", "", "release-locked JSON manifest")
	root := flag.String("module", "", "module staging directory")
	previous := flag.String("previous", "/data/adb/modules/MagicNet", "previous module directory")
	bundle := flag.String("bundle", "", "installing module ZIP")
	cache := flag.String("cache", "/data/adb/magicnet/components", "private verified component cache")
	flag.Parse()
	if *manifest == "" || *root == "" || *bundle == "" {
		fmt.Fprintln(os.Stderr, "manifest, module and bundle are required")
		os.Exit(2)
	}
	in, e := os.Open(*manifest)
	if e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
	var m Manifest
	dec := json.NewDecoder(io.LimitReader(in, 8<<20))
	dec.DisallowUnknownFields()
	e = dec.Decode(&m)
	in.Close()
	if e == nil {
		e = (manager{fetch: fetchNetwork(os.Stderr), log: os.Stderr}).install(context.Background(), m, *root, *previous, *bundle, *cache)
	}
	if e != nil {
		fmt.Fprintf(os.Stderr, "[components] ERROR: %v\n", e)
		os.Exit(1)
	}
}
