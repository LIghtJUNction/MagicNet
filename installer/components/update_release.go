package main

// The updater only accepts stable MagicNet releases discovered over GitHub's
// authenticated HTTPS API. Mirrors transport bytes; they never supply trust.
import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const updateRepository = "LIghtJUNction/MagicNet"

type releaseAsset struct {
	Name   string `json:"name"`
	URL    string `json:"browser_download_url"`
	Digest string `json:"digest"`
	Size   int64  `json:"size"`
}
type moduleRelease struct {
	Tag        string         `json:"tag_name"`
	Draft      bool           `json:"draft"`
	Prerelease bool           `json:"prerelease"`
	Assets     []releaseAsset `json:"assets"`
}
type releaseCache struct {
	ETag    string        `json:"etag"`
	Release moduleRelease `json:"release"`
}
type componentPlan struct {
	ID     string `json:"id"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Source string `json:"source"`
}
type updatePlan struct {
	Version       string          `json:"version"`
	CoreSource    string          `json:"core_source"`
	CoreBytes     int64           `json:"core_bytes"`
	DownloadBytes int64           `json:"download_bytes"`
	ReuseBytes    int64           `json:"reuse_bytes"`
	Components    []componentPlan `json:"components"`
	// Never deserialize these private execution inputs from a persisted UI plan.
	manifest manifest
	core     releaseAsset
}

type countedBody struct {
	io.ReadCloser
	bytes *atomic.Int64
}

func (b countedBody) Read(p []byte) (int, error) {
	n, e := b.ReadCloser.Read(p)
	b.bytes.Add(int64(n))
	return n, e
}

type meteredTransport struct {
	base  http.RoundTripper
	bytes *atomic.Int64
}

func (t meteredTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	response, e := t.base.RoundTrip(r)
	if e == nil {
		response.Body = countedBody{response.Body, t.bytes}
	}
	return response, e
}

func readBoundedJSON(name string, target any, limit int64) error {
	if err := regular(name); err != nil {
		return err
	}
	f, err := os.Open(name)
	if err != nil {
		return err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return err
	}
	if int64(len(data)) > limit {
		return errors.New("JSON size limit exceeded")
	}
	return json.Unmarshal(data, target)
}
func privateDirectory(name string) error {
	if err := physical(name, true); err != nil {
		return err
	}
	if err := os.MkdirAll(name, 0700); err != nil {
		return err
	}
	return os.Chmod(name, 0700)
}
func atomicJSON(name string, value any) error {
	if err := physical(name, true); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(name), ".json-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(append(data, '\n')); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), name)
}
func moduleVersion(root string) (string, error) {
	name := filepath.Join(root, "module.prop")
	if err := regular(name); err != nil {
		return "", err
	}
	f, err := os.Open(name)
	if err != nil {
		return "", err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 65537))
	if err != nil {
		return "", err
	}
	if len(b) > 65536 {
		return "", errors.New("oversized module metadata")
	}
	return versionFromProp(b)
}
func versionFromProp(b []byte) (string, error) {
	values := map[string]string{}
	for _, line := range strings.Split(string(b), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok && (key == "id" || key == "version") {
			if _, exists := values[key]; exists {
				return "", errors.New("duplicate module metadata")
			}
			values[key] = value
		}
	}
	if values["id"] != "MagicNet" || !releaseVersion.MatchString(values["version"]) {
		return "", errors.New("invalid module identity/version")
	}
	return values["version"], nil
}
func versionNumbers(v string) ([3]uint64, error) {
	var out [3]uint64
	if !releaseVersion.MatchString(v) {
		return out, errors.New("invalid release version")
	}
	for i, s := range strings.Split(v[1:], ".") {
		n, e := strconv.ParseUint(s, 10, 32)
		if e != nil {
			return out, e
		}
		out[i] = n
	}
	return out, nil
}
func compareVersions(a, b string) (int, error) {
	x, e := versionNumbers(a)
	if e != nil {
		return 0, e
	}
	y, e := versionNumbers(b)
	if e != nil {
		return 0, e
	}
	for i := range x {
		if x[i] > y[i] {
			return 1, nil
		}
		if x[i] < y[i] {
			return -1, nil
		}
	}
	return 0, nil
}
func findReleaseAsset(rel moduleRelease, name string, limit int64) (releaseAsset, error) {
	var found releaseAsset
	count := 0
	for _, a := range rel.Assets {
		if a.Name == name {
			found = a
			count++
		}
	}
	if count != 1 {
		return found, fmt.Errorf("release must contain exactly one %s", name)
	}
	expected := "https://github.com/" + updateRepository + "/releases/download/" + rel.Tag + "/" + name
	if found.URL != expected || !strings.HasPrefix(found.Digest, "sha256:") || !hexHash.MatchString(strings.TrimPrefix(found.Digest, "sha256:")) || found.Size <= 0 || found.Size > limit {
		return found, fmt.Errorf("untrusted release asset metadata: %s", name)
	}
	return found, nil
}
func (e *updateEngine) latest(ctx context.Context) (moduleRelease, error) {
	// Cache body and validator together so a 304 can never use a different body.
	cacheName := filepath.Join(e.stateDir, "release.json")
	cached := releaseCache{}
	cacheOK := readBoundedJSON(cacheName, &cached, 4<<20) == nil
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, e.apiURL, nil)
	if err != nil {
		return moduleRelease{}, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "MagicNet-smart-updater/1.1")
	if cacheOK && cached.ETag != "" {
		req.Header.Set("If-None-Match", cached.ETag)
	}
	r, err := e.client.Do(req)
	if err != nil {
		return moduleRelease{}, fmt.Errorf("trusted GitHub metadata unavailable: %w", err)
	}
	defer r.Body.Close()
	rel := moduleRelease{}
	switch r.StatusCode {
	case http.StatusNotModified:
		if !cacheOK {
			return rel, errors.New("304 without trusted cached release")
		}
		rel = cached.Release
	case http.StatusOK:
		data, err := io.ReadAll(io.LimitReader(r.Body, 4<<20+1))
		if err != nil {
			return rel, err
		}
		if len(data) > 4<<20 {
			return rel, errors.New("oversized release response")
		}
		if err = json.Unmarshal(data, &rel); err != nil {
			return rel, err
		}
	default:
		return rel, fmt.Errorf("GitHub metadata HTTP %d", r.StatusCode)
	}
	if rel.Draft || rel.Prerelease || !releaseVersion.MatchString(rel.Tag) {
		return rel, errors.New("latest release is not a stable MagicNet module")
	}
	if _, err = findReleaseAsset(rel, "MagicNet-core.zip", 12<<20); err != nil {
		return rel, err
	}
	if _, err = findReleaseAsset(rel, "components.json", 4<<20); err != nil {
		return rel, err
	}
	if r.StatusCode == http.StatusOK {
		if err = atomicJSON(cacheName, releaseCache{ETag: r.Header.Get("ETag"), Release: rel}); err != nil {
			return rel, err
		}
	}
	return rel, nil
}
func (e *updateEngine) fetchAsset(ctx context.Context, a releaseAsset) (string, error) {
	hash := strings.TrimPrefix(a.Digest, "sha256:")
	name := filepath.Join(e.cacheDir, hash+".zip") // Same content-addressed cache as installation.
	if validFile(name, a.Size, hash) {
		e.logf("[cache] %s: verified", a.Name)
		return name, nil
	}
	if err := physical(name, true); err != nil {
		return "", err
	}
	c := component{ID: a.Name, Asset: a.Name, SHA256: hash, Size: a.Size}
	if err := e.downloadOptions(ctx).download(c, a.URL, name); err != nil {
		return "", err
	}
	return name, nil
}
func (e *updateEngine) plan(ctx context.Context) (updatePlan, error) {
	p := updatePlan{Components: []componentPlan{}}
	rel, err := e.latest(ctx)
	if err != nil {
		return p, err
	}
	current, err := moduleVersion(e.moduleDir)
	if err != nil && !os.IsNotExist(err) {
		return p, err
	}
	if current != "" {
		cmp, err := compareVersions(rel.Tag, current)
		if err != nil {
			return p, err
		}
		if cmp < 0 {
			return p, errors.New("refusing a module downgrade")
		}
	}
	ma, err := findReleaseAsset(rel, "components.json", 4<<20)
	if err != nil {
		return p, err
	}
	name, err := e.fetchAsset(ctx, ma)
	if err != nil {
		return p, err
	}
	if err = readBoundedJSON(name, &p.manifest, 4<<20); err != nil {
		return p, err
	}
	if err = p.manifest.validate(); err != nil {
		return p, err
	}
	if p.manifest.Repository != updateRepository || p.manifest.Version != rel.Tag {
		return p, errors.New("manifest/release identity mismatch")
	}
	for _, required := range []string{"bin/sing-box", "bin/magicnet-cli", "bin/magicnet-mcp-server"} {
		found := false
		for _, c := range p.manifest.Components {
			for _, f := range c.Files {
				if f.Path == required {
					found = true
				}
			}
		}
		if !found {
			return p, fmt.Errorf("required component missing: %s", required)
		}
	}
	p.Version = rel.Tag
	p.core, err = findReleaseAsset(rel, "MagicNet-core.zip", 12<<20)
	if err != nil {
		return p, err
	}
	p.CoreBytes = p.core.Size
	p.CoreSource = "download"
	if validFile(filepath.Join(e.cacheDir, strings.TrimPrefix(p.core.Digest, "sha256:")+".zip"), p.core.Size, strings.TrimPrefix(p.core.Digest, "sha256:")) {
		p.CoreSource = "cache"
	}
	if p.CoreSource == "download" {
		p.DownloadBytes += p.CoreBytes
	} else {
		p.ReuseBytes += p.CoreBytes
	}
	for _, c := range p.manifest.Components {
		source := "installed"
		for _, f := range c.Files {
			if !validFile(filepath.Join(e.moduleDir, f.Path), f.Size, f.SHA256) {
				source = "download"
				break
			}
		}
		if source == "download" && validFile(filepath.Join(e.cacheDir, c.SHA256+".zip"), c.Size, c.SHA256) {
			source = "cache"
		}
		p.Components = append(p.Components, componentPlan{c.ID, c.SHA256, c.Size, source})
		if source == "download" {
			p.DownloadBytes += c.Size
		} else {
			p.ReuseBytes += c.Size
		}
	}
	return p, nil
}
func (p updatePlan) unchanged(current string) bool {
	if p.Version != current {
		return false
	}
	for _, c := range p.Components {
		if c.Source != "installed" {
			return false
		}
	}
	return true
}

func validateUpdateCore(z *zip.ReadCloser, m manifest) error {
	entries, err := zipIndex(&z.Reader)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	links := map[string]bool{}
	var total uint64
	for _, f := range z.File {
		name := strings.TrimSuffix(f.Name, "/")
		if !safeName(name) || seen[name] {
			return errors.New("unsafe/duplicate core ZIP entry")
		}
		seen[name] = true
		if f.UncompressedSize64 > 1<<30-total {
			return errors.New("core ZIP unpacked size limit")
		}
		total += f.UncompressedSize64
		if f.Mode()&os.ModeSymlink != 0 {
			if f.UncompressedSize64 > 4096 {
				return errors.New("oversized core symlink")
			}
			r, err := f.Open()
			if err != nil {
				return err
			}
			b, err := io.ReadAll(io.LimitReader(r, 4097))
			r.Close()
			if err != nil {
				return err
			}
			target := string(b)
			resolved := path.Clean(path.Join(path.Dir(name), target))
			if target == "" || strings.HasPrefix(target, "/") || strings.ContainsAny(target, "\\\x00\r\n\t") || !safeName(resolved) {
				return errors.New("unsafe core symlink target")
			}
			links[name] = true
		} else if !f.Mode().IsRegular() && !f.FileInfo().IsDir() {
			return errors.New("unsupported core ZIP entry")
		}
	}
	for name := range seen {
		for parent := path.Dir(name); parent != "."; parent = path.Dir(parent) {
			if links[parent] {
				return errors.New("core ZIP traverses directory symlink")
			}
		}
	}
	read := func(name string, limit int64) ([]byte, error) {
		f := entries[name]
		if f == nil || !f.Mode().IsRegular() || f.UncompressedSize64 > uint64(limit) {
			return nil, fmt.Errorf("missing/unsafe core file: %s", name)
		}
		r, err := f.Open()
		if err != nil {
			return nil, err
		}
		defer r.Close()
		return io.ReadAll(io.LimitReader(r, limit+1))
	}
	prop, err := read("module.prop", 65536)
	if err != nil {
		return err
	}
	version, err := versionFromProp(prop)
	if err != nil || version != m.Version {
		return errors.New("core/release version mismatch")
	}
	data, err := read("components.json", 4<<20)
	if err != nil {
		return err
	}
	var embedded manifest
	if err = json.Unmarshal(data, &embedded); err != nil {
		return err
	}
	if !reflect.DeepEqual(m, embedded) {
		return errors.New("embedded component manifest differs from verified release")
	}
	for _, name := range []string{"customize.sh", "bin/magicnet-components"} {
		if entries[name] == nil || !entries[name].Mode().IsRegular() {
			return fmt.Errorf("missing core bootstrap: %s", name)
		}
	}
	return nil
}

// Rebuild an offline installation input from the verified core plus verified
// local/cache payloads. This is local staging, not a new signed release asset.
// The running module is not modified, and the manager never needs the network.
func (e *updateEngine) prepare(ctx context.Context, p updatePlan, out string) error {
	core, err := e.fetchAsset(ctx, p.core)
	if err != nil {
		return err
	}
	z, err := zip.OpenReader(core)
	if err != nil {
		return err
	}
	defer z.Close()
	if err = validateUpdateCore(z, p.manifest); err != nil {
		return err
	}
	work, err := os.MkdirTemp(e.stateDir, "prepare-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	payloadRoot := filepath.Join(work, "payload")
	o := e.downloadOptions(ctx)
	o.Archive = core
	o.ModuleDir = payloadRoot
	o.PreviousDir = e.moduleDir
	if err = run(o); err != nil {
		return err
	}
	if err = physical(out, true); err != nil {
		return err
	}
	target, err := os.CreateTemp(filepath.Dir(out), ".prepared-")
	if err != nil {
		return err
	}
	defer os.Remove(target.Name())
	writer := zip.NewWriter(target)
	wanted := map[string]bool{}
	for _, c := range p.manifest.Components {
		for _, f := range c.Files {
			wanted[f.Path] = true
		}
	}
	err = func() error {
		for _, f := range z.File {
			if !wanted[f.Name] {
				if err := writer.Copy(f); err != nil {
					return err
				}
			}
		}
		for _, c := range p.manifest.Components {
			for _, f := range c.Files {
				name := filepath.Join(payloadRoot, f.Path)
				if !validFile(name, f.Size, f.SHA256) {
					return fmt.Errorf("staged file changed: %s", f.Path)
				}
				h := &zip.FileHeader{Name: f.Path, Method: zip.Deflate}
				h.SetMode(os.FileMode(f.Mode))
				h.Modified = time.Unix(315532800, 0)
				w, err := writer.CreateHeader(h)
				if err != nil {
					return err
				}
				r, err := os.Open(name)
				if err != nil {
					return err
				}
				_, err = io.Copy(w, r)
				r.Close()
				if err != nil {
					return err
				}
			}
		}
		return nil
	}()
	closeErr := writer.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = target.Sync()
	}
	closeErr = target.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	// Re-read the complete rebuilt archive before any privileged installer runs.
	test, err := zip.OpenReader(target.Name())
	if err != nil {
		return err
	}
	err = validateUpdateCore(test, p.manifest)
	if err == nil {
		entries, _ := zipIndex(&test.Reader)
		for _, c := range p.manifest.Components {
			for _, f := range c.Files {
				entry := entries[f.Path]
				if entry == nil {
					err = errors.New("prepared component absent")
					break
				}
				r, openErr := entry.Open()
				if openErr != nil {
					err = openErr
					break
				}
				h := sha256.New()
				n, copyErr := io.Copy(h, io.LimitReader(r, f.Size+1))
				r.Close()
				if copyErr != nil || n != f.Size || fmt.Sprintf("%x", h.Sum(nil)) != f.SHA256 {
					err = fmt.Errorf("prepared component integrity: %s", f.Path)
					break
				}
			}
			if err != nil {
				break
			}
		}
	}
	test.Close()
	if err != nil {
		return err
	}
	return os.Rename(target.Name(), out)
}
