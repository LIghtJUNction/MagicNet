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

type config struct {
	Repository   string   `json:"repository"`
	Asset        string   `json:"asset"`
	ModuleID     string   `json:"module_id"`
	Proxies      []string `json:"proxies"`
	DirectMinKiB int64    `json:"direct_min_kib"`
}
type asset struct {
	Name   string
	URL    string `json:"browser_download_url"`
	Digest string
	Size   int64
}
type release struct {
	Tag        string `json:"tag_name"`
	Draft      bool
	Prerelease bool
	Assets     []asset
}
type route struct {
	URL   string
	Speed float64
}

const probeSize = 256 << 10

func client() *http.Client {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.ResponseHeaderTimeout = 10 * time.Second
	tr.TLSHandshakeTimeout = 10 * time.Second
	if runtime.GOOS == "android" {
		// Static Go cannot use Android's libc resolver; DNS answers are still checked by TLS.
		var dnsAttempt atomic.Uint32
		resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			servers := []string{"223.5.5.5:53", "1.1.1.1:53", "8.8.8.8:53"}
			return (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, network, servers[(dnsAttempt.Add(1)-1)%uint32(len(servers))])
		}}
		tr.DialContext = (&net.Dialer{Timeout: 10 * time.Second, Resolver: resolver}).DialContext
		roots, _ := x509.SystemCertPool()
		if roots == nil {
			roots = x509.NewCertPool()
		}
		for _, dir := range []string{"/system/etc/security/cacerts", "/apex/com.android.conscrypt/cacerts"} {
			files, _ := os.ReadDir(dir)
			for _, f := range files {
				b, e := os.ReadFile(filepath.Join(dir, f.Name()))
				if e == nil {
					roots.AppendCertsFromPEM(b)
				}
			}
		}
		tr.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	}
	return &http.Client{Transport: tr, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		if req.URL.Scheme != "https" {
			return errors.New("non-HTTPS redirect refused")
		}
		return nil
	}}
}
func request(ctx context.Context, c *http.Client, u string, partial bool) (*http.Response, error) {
	q, e := http.NewRequestWithContext(ctx, "GET", u, nil)
	if e != nil {
		return nil, e
	}
	q.Header.Set("User-Agent", "kam-module-downloader/1.0")
	if partial {
		q.Header.Set("Range", fmt.Sprintf("bytes=0-%d", probeSize-1))
	}
	r, e := c.Do(q)
	if e != nil {
		return nil, e
	}
	if r.StatusCode != 200 && !(partial && r.StatusCode == 206) {
		r.Body.Close()
		return nil, fmt.Errorf("HTTP %d", r.StatusCode)
	}
	return r, nil
}
func latest(ctx context.Context, c *http.Client, cfg config) (asset, error) {
	ctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	// Never accept checksums supplied by the ZIP mirror.
	r, e := request(ctx, c, "https://api.github.com/repos/"+cfg.Repository+"/releases/latest", false)
	if e != nil {
		return asset{}, fmt.Errorf("cannot securely obtain latest release metadata: %w", e)
	}
	defer r.Body.Close()
	var rel release
	if e = json.NewDecoder(io.LimitReader(r.Body, 4<<20)).Decode(&rel); e != nil {
		return asset{}, e
	}
	if rel.Draft || rel.Prerelease || rel.Tag == "" {
		return asset{}, errors.New("not a stable release")
	}
	for _, a := range rel.Assets {
		if a.Name == cfg.Asset {
			u, e := url.Parse(a.URL)
			if e != nil || u.Scheme != "https" || u.Host != "github.com" || !strings.HasPrefix(u.Path, "/"+cfg.Repository+"/releases/download/") {
				return asset{}, errors.New("unexpected asset URL")
			}
			h, e := hex.DecodeString(strings.TrimPrefix(a.Digest, "sha256:"))
			if !strings.HasPrefix(a.Digest, "sha256:") || e != nil || len(h) != 32 {
				return asset{}, errors.New("release has no trustworthy SHA-256")
			}
			if a.Size <= 0 || a.Size > 512<<20 {
				return asset{}, errors.New("invalid asset size")
			}
			fmt.Println("Latest:", rel.Tag)
			return a, nil
		}
	}
	return asset{}, errors.New("release asset not found")
}
func probe(ctx context.Context, c *http.Client, u string) route {
	ctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	start := time.Now()
	r, e := request(ctx, c, u, true)
	if e != nil {
		return route{URL: u}
	}
	defer r.Body.Close()
	b, e := io.ReadAll(io.LimitReader(r.Body, probeSize))
	if e != nil || len(b) < 4 || string(b[:4]) != "PK\x03\x04" {
		return route{URL: u}
	}
	return route{u, float64(len(b)) / time.Since(start).Seconds()}
}
func mirrors(ctx context.Context, c *http.Client, a asset, cfg config, direct route) []route {
	ch := make(chan route, len(cfg.Proxies))
	for _, p := range cfg.Proxies {
		go func(p string) { ch <- probe(ctx, c, strings.TrimRight(p, "/")+"/"+a.URL) }(p)
	}
	routes := []route{}
	if direct.Speed > 0 {
		routes = append(routes, direct)
	}
	for range cfg.Proxies {
		r := <-ch
		if r.Speed > 0 {
			routes = append(routes, r)
		}
	}
	sort.SliceStable(routes, func(i, j int) bool { return routes[i].Speed > routes[j].Speed })
	return routes
}
func download(ctx context.Context, c *http.Client, a asset, u, out string) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	r, e := request(ctx, c, u, false)
	if e != nil {
		return e
	}
	defer r.Body.Close()
	f, e := os.OpenFile(out, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	h := sha256.New()
	n, e := io.Copy(io.MultiWriter(f, h), io.LimitReader(r.Body, a.Size+1))
	ce := f.Close()
	if e != nil {
		return e
	}
	if ce != nil {
		return ce
	}
	if n != a.Size {
		return errors.New("incomplete or oversized download")
	}
	if "sha256:"+hex.EncodeToString(h.Sum(nil)) != a.Digest {
		return errors.New("SHA-256 mismatch")
	}
	return nil
}
func checkZip(file, id string) error {
	z, e := zip.OpenReader(file)
	if e != nil {
		return e
	}
	defer z.Close()
	seen := map[string]bool{}
	found := false
	var total uint64
	for _, f := range z.File {
		n := f.Name
		if strings.Contains(n, "\\") || strings.HasPrefix(n, "/") || path.Clean(n) != strings.TrimSuffix(n, "/") || n == ".." || strings.HasPrefix(n, "../") || seen[n] {
			return errors.New("unsafe or duplicate ZIP path")
		}
		seen[n] = true
		total += f.UncompressedSize64
		if total > 2<<30 {
			return errors.New("unpacked module exceeds limit")
		}
		r, e := f.Open()
		if e != nil {
			return e
		}
		if n == "module.prop" {
			b, e := io.ReadAll(io.LimitReader(r, 64<<10))
			if e != nil {
				r.Close()
				return e
			}
			count := 0
			for _, line := range strings.Split(string(b), "\n") {
				if strings.HasPrefix(line, "id=") {
					count++
					found = strings.TrimSpace(strings.TrimPrefix(line, "id=")) == id
				}
			}
			if count != 1 {
				r.Close()
				return errors.New("ambiguous module id")
			}
		}
		_, e = io.Copy(io.Discard, r)
		r.Close()
		if e != nil {
			return fmt.Errorf("invalid ZIP entry %s: %w", n, e)
		}
	}
	if !found {
		return errors.New("module id mismatch")
	}
	return nil
}
func validateConfig(c config) error {
	if !regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`).MatchString(c.Repository) || !regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_.-]+$`).MatchString(c.ModuleID) || path.Base(c.Asset) != c.Asset || !strings.HasSuffix(c.Asset, ".zip") {
		return errors.New("invalid target configuration")
	}
	if c.DirectMinKiB <= 0 || c.DirectMinKiB > 1048576 || len(c.Proxies) > 8 {
		return errors.New("invalid probe configuration")
	}
	for _, p := range c.Proxies {
		u, e := url.Parse(p)
		if e != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return errors.New("invalid HTTPS mirror")
		}
	}
	return nil
}
func run(cfg config, out string) error {
	return runWithClient(cfg, out, client())
}

func runWithClient(cfg config, out string, c *http.Client) error {
	if e := validateConfig(cfg); e != nil {
		return e
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	a, e := latest(ctx, c, cfg)
	if e != nil {
		return e
	}
	tmp := out + ".partial"
	defer os.Remove(tmp)
	attempted := map[string]bool{}
	attempt := func(r route) error {
		attempted[r.URL] = true
		u, _ := url.Parse(r.URL)
		fmt.Printf("Download: %s (probe %.0f KiB/s)\n", u.Host, r.Speed/1024)
		if e := download(ctx, c, a, r.URL, tmp); e != nil {
			return e
		}
		if e := checkZip(tmp, cfg.ModuleID); e != nil {
			return e
		}
		return os.Rename(tmp, out)
	}
	direct := probe(ctx, c, a.URL)
	if direct.Speed >= float64(cfg.DirectMinKiB*1024) {
		if e = attempt(direct); e == nil {
			return nil
		}
		fmt.Println("Direct download failed:", e)
		direct.Speed = 0
	}
	routes := mirrors(ctx, c, a, cfg, direct)
	// A slow CDN handshake or rejected Range request is not proof that full GET fails.
	routes = append(routes, route{URL: a.URL})
	for _, p := range cfg.Proxies {
		routes = append(routes, route{URL: strings.TrimRight(p, "/") + "/" + a.URL})
	}
	for _, r := range routes {
		if attempted[r.URL] {
			continue
		}
		if e = attempt(r); e == nil {
			return nil
		}
		fmt.Println("Route failed:", e)
	}
	return errors.New("no verified download succeeded; existing module left unchanged")
}
func main() {
	configPath := flag.String("config", "download.json", "configuration")
	out := flag.String("out", "module.zip", "verified output ZIP")
	flag.Parse()
	b, e := os.ReadFile(*configPath)
	var cfg config
	if e == nil {
		e = json.Unmarshal(b, &cfg)
	}
	if e == nil {
		e = run(cfg, *out)
	}
	if e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
