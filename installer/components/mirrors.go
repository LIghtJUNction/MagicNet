package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
)

const (
	routeProbeBytes   = int64(1 << 20)
	routeProbeWorkers = 4
	maxMirrorRoutes   = 16
)

// These are candidates, not a speed ranking or a trust root. Probe the actual
// release asset on the device; only the embedded manifest authenticates bytes.
// Sources and the review date are recorded in docs/github-downloads.md.
func defaultMirrors() []string {
	return []string{
		"https://gh-proxy.com/",
		"https://ghfast.top/",
		"https://ghproxy.net/",
		"https://gh.ddlc.top/",
		"https://gh.llkk.cc/",
		"https://gh.jasonzeng.dev/",
		"https://ghproxy.site/",
	}
}

type routeHint struct {
	set          bool
	prefix, name string
	verifiedAt   time.Time
	sampleSize   int64
}

func (r *routeHint) usable(c component) bool {
	if r == nil || !r.set {
		return false
	}
	// Zero fields are used by private host-test fixtures, not persisted state.
	if !r.verifiedAt.IsZero() && time.Since(r.verifiedAt) >= 5*time.Minute {
		return false
	}
	// A tiny fast ZIP says nothing about a later multi-megabyte binary.
	return r.sampleSize == 0 || c.Size <= r.sampleSize || r.sampleSize >= routeProbeBytes
}

type route struct {
	url, name, prefix string
	speed             float64
	bytes             int64
	elapsed           time.Duration
	reason            string
	retryable         bool
}

func routeName(prefix string) string {
	if prefix == "" {
		return "GitHub"
	}
	name := strings.TrimPrefix(prefix, "https://")
	if slash := strings.IndexByte(name, '/'); slash >= 0 {
		name = name[:slash]
	}
	if name == "" {
		return "mirror"
	}
	return name
}

func (o options) probe(c component, rawURL, name, prefix string) (result route) {
	start := time.Now()
	result = route{url: rawURL, name: name, prefix: prefix, reason: "unavailable"}
	defer func() { result.elapsed = time.Since(start) }()
	budget := o.probeTimeout
	if budget <= 0 {
		budget = 5 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), budget)
	defer cancel()
	size := min(c.Size, routeProbeBytes)
	if size < 4 {
		return result
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return result
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=0-%d", size-1))
	req.Header.Set("Accept-Encoding", "identity")
	req.Header.Set("User-Agent", "MagicNet-components/1")
	response, err := o.client.Do(req)
	if err != nil {
		// A short probe budget is not the full transfer/header budget.
		result.retryable = true
		return result
	}
	defer response.Body.Close()
	switch response.StatusCode {
	case http.StatusOK:
		if response.ContentLength >= 0 && response.ContentLength != c.Size {
			result.reason = "size mismatch"
			return result
		}
	case http.StatusPartialContent:
		if response.Header.Get("Content-Range") != fmt.Sprintf("bytes 0-%d/%d", size-1, c.Size) ||
			(response.ContentLength >= 0 && response.ContentLength != size) {
			result.reason = "invalid range"
			return result
		}
	default:
		result.reason = fmt.Sprintf("HTTP %d", response.StatusCode)
		return result
	}
	if encoding := response.Header.Get("Content-Encoding"); encoding != "" && encoding != "identity" {
		result.reason = "unexpected encoding"
		return result
	}
	// A fast HTML landing page/challenge is not a fast component mirror.
	var header [4]byte
	if _, err := io.ReadFull(response.Body, header[:]); err != nil {
		result.reason = "incomplete sample"
		result.retryable = true
		return result
	}
	if string(header[:]) != "PK\x03\x04" {
		result.reason = "not a component ZIP"
		return result
	}
	h := sha256.New()
	_, _ = h.Write(header[:])
	n, err := io.CopyBuffer(h, io.LimitReader(response.Body, size-4), make([]byte, 32<<10))
	n += 4
	if n != size && !(ctx.Err() == context.DeadlineExceeded && n >= min(size, int64(4096))) {
		result.reason = "incomplete sample"
		result.retryable = true
		return result
	}
	if err != nil && ctx.Err() != context.DeadlineExceeded {
		result.reason = "read error"
		result.retryable = true
		return result
	}
	if size == c.Size && n == c.Size && hex.EncodeToString(h.Sum(nil)) != c.SHA256 {
		result.reason = "checksum mismatch"
		return result
	}
	result.bytes = n
	result.speed = float64(n) / time.Since(start).Seconds()
	result.reason = ""
	return result
}

func (o options) reportRoute(r route) {
	if r.reason != "" {
		o.printf("[route] %s: %s", r.name, r.reason)
		return
	}
	o.printf("[route] %s: %.0f KiB/s (%s in %.2fs)", r.name, r.speed/1024, humanBytes(r.bytes), r.elapsed.Seconds())
}

func (o options) routeCandidates(direct string, attempted map[string]bool) []route {
	seen := map[string]bool{}
	var candidates []route
	for _, prefix := range append([]string{""}, o.mirrors...) {
		if prefix != "" {
			prefix = strings.TrimRight(prefix, "/") + "/"
		}
		target := prefix + direct
		if seen[target] {
			continue
		}
		seen[target] = true
		if attempted[target] {
			continue
		}
		candidates = append(candidates, route{url: target, name: routeName(prefix), prefix: prefix})
		if len(candidates) >= maxMirrorRoutes+1 {
			break
		}
	}
	return candidates
}

func (o options) rankRoutes(c component, direct string, attempted map[string]bool) []route {
	candidates := o.routeCandidates(direct, attempted)
	if len(candidates) == 0 {
		return nil
	}
	type indexedRoute struct {
		index int
		route route
	}
	jobs := make(chan int, len(candidates))
	results := make(chan indexedRoute, len(candidates))
	for i := range candidates {
		jobs <- i
	}
	close(jobs)
	for i := 0; i < min(routeProbeWorkers, len(candidates)); i++ {
		go func() {
			for index := range jobs {
				r := candidates[index]
				results <- indexedRoute{index, o.probe(c, r.url, r.name, r.prefix)}
			}
		}()
	}
	ranked := make([]route, len(candidates))
	for range candidates {
		r := <-results
		ranked[r.index] = r.route
		// Only the collecting goroutine writes logs, including bytes.Buffer
		// test writers. A larger pool must not introduce a logger data race.
		o.reportRoute(r.route)
	}
	return rankedDownloadRoutes(ranked)
}

func rankedDownloadRoutes(candidates []route) []route {
	results := make([]route, 0, len(candidates))
	for _, r := range candidates {
		// Unknown throughput stays behind measured routes. A timed-out probe
		// may succeed with the actual transfer budget; never label it fast.
		if r.speed > 0 || r.retryable {
			results = append(results, r)
		}
	}
	sort.SliceStable(results, func(i, j int) bool { return results[i].speed > results[j].speed })
	return results
}

func (o options) routes(c component, direct string) []route {
	first := o.probe(c, direct, "GitHub", "")
	o.reportRoute(first)
	// Keep cheap direct access when a meaningful 1 MiB sample is genuinely
	// fast. The old 64 KiB / 256 KiB/s shortcut hid much faster alternatives.
	if first.bytes >= routeProbeBytes && first.speed >= 4<<20 {
		return []route{first}
	}
	o.printf("[route] comparing GitHub mirrors: at most %d parallel, 1 MiB per path", routeProbeWorkers)
	results := append([]route{first}, o.rankRoutes(c, direct, map[string]bool{direct: true})...)
	return rankedDownloadRoutes(results)
}
