package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// One successful route is reused for the remaining components in this batch.
// A failed route is discarded, so a good probe never disables mirror fallback.
type downloadSession struct {
	mu     sync.Mutex
	prefix string
	known  bool
}

func (o options) download(c component, direct, destination string) error {
	if o.ctx == nil {
		o.ctx = context.Background()
	}
	if o.session == nil {
		o.session = &downloadSession{}
	}
	if err := physical(destination, true); err != nil {
		return err
	}
	part := filepath.Join(o.CacheDir, c.SHA256+".part")
	if err := physical(part, true); err != nil {
		return err
	}
	candidates := []route{}
	o.session.mu.Lock()
	known, prefix := o.session.known, o.session.prefix
	o.session.mu.Unlock()
	if known {
		candidates = append(candidates, route{url: prefix + direct, name: routeName(prefix)})
	} else if c.Size < 128<<10 {
		// Probing a tiny manifest/asset can cost more traffic than downloading it.
		candidates = append(candidates, route{url: direct, name: "GitHub"})
	} else {
		candidates = o.routes(direct)
	}
	attempted := map[string]bool{}
	expanded := len(candidates) > 1
	var last error
	for i := 0; i < len(candidates); i++ {
		candidate := candidates[i]
		if attempted[candidate.url] {
			continue
		}
		attempted[candidate.url] = true
		if err := o.ctx.Err(); err != nil {
			return err
		}
		err := o.transfer(c, candidate.url, part, destination)
		if err == nil {
			o.session.mu.Lock()
			o.session.prefix = strings.TrimSuffix(candidate.url, direct)
			o.session.known = true
			o.session.mu.Unlock()
			return nil
		}
		last = err
		o.printf("[download] %s via %s failed: %v", c.ID, candidate.name, err)
		o.session.mu.Lock()
		o.session.known = false
		o.session.mu.Unlock()
		if !expanded {
			expanded = true
			candidates = append(candidates, route{url: direct, name: "GitHub"})
			for _, p := range o.mirrors {
				if c.Size < 128<<10 {
					candidates = append(candidates, route{url: p + direct, name: routeName(p)})
				} else {
					candidates = append(candidates, o.probe(p+direct, routeName(p)))
				}
			}
		}
	}
	return fmt.Errorf("%s: all verified download routes failed: %w", c.ID, last)
}
func routeName(prefix string) string {
	if prefix == "" {
		return "GitHub"
	}
	return strings.Split(strings.TrimPrefix(prefix, "https://"), "/")[0]
}
func (o options) transfer(c component, address, partial, destination string) error {
	var offset int64
	if st, err := os.Lstat(partial); err == nil {
		if !st.Mode().IsRegular() {
			return errors.New("unsafe partial download")
		}
		offset = st.Size()
		if offset == c.Size && validFile(partial, c.Size, c.SHA256) {
			return os.Rename(partial, destination)
		}
		if offset >= c.Size {
			if err = os.Remove(partial); err != nil {
				return err
			}
			offset = 0
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	req, err := http.NewRequestWithContext(o.ctx, http.MethodGet, address, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "MagicNet-components/1.1")
	req.Header.Set("Accept-Encoding", "identity")
	if offset > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", offset))
		o.printf("[resume] %s: %d/%d KiB", c.ID, offset/1024, c.Size/1024)
	}
	r, err := o.client.Do(req)
	if err != nil {
		return err
	}
	defer r.Body.Close()
	switch r.StatusCode {
	case http.StatusOK:
		offset = 0 // Range ignored: replace, never append a full body.
	case http.StatusPartialContent:
		var start, end, total int64
		n, e := fmt.Sscanf(r.Header.Get("Content-Range"), "bytes %d-%d/%d", &start, &end, &total)
		if e != nil || n != 3 || start != offset || total != c.Size || end != c.Size-1 {
			return errors.New("invalid resume Content-Range")
		}
	default:
		return fmt.Errorf("HTTP %d", r.StatusCode)
	}
	if r.ContentLength >= 0 && r.ContentLength != c.Size-offset {
		return errors.New("download size mismatch")
	}
	flags := os.O_CREATE | os.O_WRONLY
	if offset == 0 {
		flags |= os.O_TRUNC
	} else {
		flags |= os.O_APPEND
	}
	f, err := os.OpenFile(partial, flags, 0600)
	if err != nil {
		return err
	}
	p := &progress{current: offset, total: c.Size, o: o, id: c.ID}
	n, err := io.Copy(io.MultiWriter(f, p), io.LimitReader(r.Body, c.Size-offset+1))
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	} // Keep a private partial for the next bounded attempt.
	if n+offset != c.Size {
		if n+offset > c.Size {
			_ = os.Remove(partial)
		}
		return errors.New("incomplete or oversized download")
	}
	if !validFile(partial, c.Size, c.SHA256) {
		_ = os.Remove(partial)
		return errors.New("download checksum mismatch")
	}
	return os.Rename(partial, destination)
}
