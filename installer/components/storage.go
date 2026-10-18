package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"syscall"
)

const (
	workspaceName  = ".components-install"
	workspaceOwner = ".magicnet-components-v1"
	promotionFile  = ".promotion.json"
)

// Lock the directory inode, which remains stable while a manager installs this
// module. Removing a separate lock file could let two processes lock different
// inodes. Closing this descriptor (including on process death) releases it.
func lockModule(root string) (*os.File, error) {
	if err := physical(root, true); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	lock, err := os.Open(root)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, fmt.Errorf("another component installation is running: %w", err)
	}
	return lock, nil
}

func readBounded(name string, limit int64) ([]byte, error) {
	if err := regular(name); err != nil {
		return nil, err
	}
	f, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, limit+1))
	if int64(len(raw)) > limit {
		return nil, fmt.Errorf("oversized installer state: %s", name)
	}
	return raw, err
}

// A single owned workspace bounds leftovers even if the process is killed.
// Unknown files/directories are never adopted merely because their name matches.
func prepareWorkspace(root string) (string, error) {
	stage := filepath.Join(root, workspaceName)
	if err := physical(stage, true); err != nil {
		return "", err
	}
	entries, err := os.ReadDir(stage)
	if err == nil {
		if len(entries) > 0 {
			if _, err := readBounded(filepath.Join(stage, workspaceOwner), 0); err != nil {
				return "", fmt.Errorf("unrecognized component workspace left untouched: %s", stage)
			}
			if err := recoverPromotion(stage, root); err != nil {
				return "", fmt.Errorf("component recovery retained at %s: %w", stage, err)
			}
		}
		if err := cleanupWorkspace(stage); err != nil {
			return "", err
		}
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if err := os.Mkdir(stage, 0o700); err != nil {
		return "", err
	}
	// Creating an empty marker is one filesystem operation; termination cannot
	// leave half-written ownership data that blocks the next installation.
	if err := os.WriteFile(filepath.Join(stage, workspaceOwner), nil, 0o600); err != nil {
		os.RemoveAll(stage)
		return "", err
	}
	return stage, nil
}

// Remove the ownership marker last. A killed cleanup therefore leaves either
// an identifiable workspace or an empty directory that is safe to remove.
func cleanupWorkspace(stage string) error {
	entries, err := os.ReadDir(stage)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.Name() != workspaceOwner {
			if err := os.RemoveAll(filepath.Join(stage, entry.Name())); err != nil {
				return err
			}
		}
	}
	if err := os.Remove(filepath.Join(stage, workspaceOwner)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return os.Remove(stage)
}

type promotionChange struct {
	Path    string `json:"path"`
	Existed bool   `json:"existed"`
	Install bool   `json:"install"`
}

type promotionJournal struct {
	Schema  int               `json:"schema"`
	Changes []promotionChange `json:"changes"`
}

func (j promotionJournal) validate() error {
	if j.Schema != 1 || len(j.Changes) == 0 || len(j.Changes) > 200000 {
		return errors.New("invalid component promotion journal")
	}
	names := map[string]bool{}
	for _, c := range j.Changes {
		if (!managedName(c.Path) && c.Path != "components.installed.json") || names[c.Path] {
			return errors.New("unsafe component promotion journal")
		}
		names[c.Path] = true
	}
	for name := range names {
		for parent := path.Dir(name); parent != "."; parent = path.Dir(parent) {
			if names[parent] {
				return errors.New("overlapping component promotion journal")
			}
		}
	}
	return nil
}

// Finish every validation before moving old files. Write the complete plan
// first so a later process can undo an interrupted rename, including deletion
// of an obsolete file or introduction of a previously absent file.
func preparePromotion(stage, root string, files []payloadFile, obsolete []string) (promotionJournal, error) {
	j := promotionJournal{Schema: 1}
	for _, f := range files {
		j.Changes = append(j.Changes, promotionChange{Path: f.Path, Install: true})
	}
	for _, name := range obsolete {
		j.Changes = append(j.Changes, promotionChange{Path: name})
	}
	if err := j.validate(); err != nil {
		return j, err
	}
	for i, c := range j.Changes {
		dst := filepath.Join(root, c.Path)
		if err := physical(dst, true); err != nil {
			return j, err
		}
		if st, err := os.Lstat(dst); err == nil {
			if !st.Mode().IsRegular() {
				return j, fmt.Errorf("unsafe component destination: %s", dst)
			}
			j.Changes[i].Existed = true
		} else if !os.IsNotExist(err) {
			return j, err
		}
		if c.Install {
			if err := regular(filepath.Join(stage, c.Path)); err != nil {
				return j, err
			}
		}
		for _, dir := range []string{filepath.Dir(dst), filepath.Dir(filepath.Join(stage, ".rollback", c.Path))} {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return j, err
			}
		}
	}
	raw, err := json.Marshal(j)
	if err != nil {
		return j, err
	}
	f, err := os.OpenFile(filepath.Join(stage, promotionFile+".tmp"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return j, err
	}
	_, err = f.Write(raw)
	if err == nil {
		err = f.Sync()
	}
	err = errors.Join(err, f.Close())
	if err == nil {
		err = os.Rename(f.Name(), filepath.Join(stage, promotionFile))
	}
	return j, err
}

func promote(stage, root string, files []payloadFile, obsolete []string) error {
	j, err := preparePromotion(stage, root, files, obsolete)
	if err != nil {
		return err
	}
	for _, c := range j.Changes {
		dst := filepath.Join(root, c.Path)
		if c.Existed {
			if err := os.Rename(dst, filepath.Join(stage, ".rollback", c.Path)); err != nil {
				return err
			}
		}
		if c.Install {
			if err := os.Rename(filepath.Join(stage, c.Path), dst); err != nil {
				return err
			}
		}
	}
	// Atomic completion marker: after this rename a retry can discard backups.
	// Before it, recovery rolls back the whole transaction, even if every file
	// had already been promoted. Do not unlink backups before marking success.
	return os.Rename(filepath.Join(stage, promotionFile), filepath.Join(stage, ".committed"))
}

// Recovery is repeatable if interrupted itself. A backup is consumed only by
// an atomic rename back to its destination. A newly introduced file is moved
// back to staging, so a second recovery will not remove an unrelated new file.
func recoverPromotion(stage, root string) error {
	raw, err := readBounded(filepath.Join(stage, promotionFile), 8<<20)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var j promotionJournal
	if err := json.Unmarshal(raw, &j); err != nil {
		return err
	}
	if err := j.validate(); err != nil {
		return err
	}
	for i := len(j.Changes) - 1; i >= 0; i-- {
		c := j.Changes[i]
		dst := filepath.Join(root, c.Path)
		if err := physical(dst, true); err != nil {
			return err
		}
		st, err := os.Lstat(dst)
		if err == nil && !st.Mode().IsRegular() {
			return fmt.Errorf("unsafe component recovery destination: %s", dst)
		} else if err != nil && !os.IsNotExist(err) {
			return err
		}
		if c.Existed {
			backup := filepath.Join(stage, ".rollback", c.Path)
			if err := regular(backup); os.IsNotExist(err) {
				if st == nil {
					return fmt.Errorf("component and recovery copy are both missing: %s", c.Path)
				}
				continue // Not moved yet, or already restored by an earlier recovery.
			} else if err != nil {
				return err
			}
			if err := os.Rename(backup, dst); err != nil {
				return err
			}
		} else if c.Install {
			staged := filepath.Join(stage, c.Path)
			if err := regular(staged); err == nil {
				continue // Not installed yet, or already restored to staging.
			} else if !os.IsNotExist(err) {
				return err
			}
			if st == nil {
				continue
			}
			if err := os.Rename(dst, staged); err != nil {
				return err
			}
		}
	}
	return os.Remove(filepath.Join(stage, promotionFile))
}

func pruneEmptyParents(root string, obsolete []string) {
	for _, name := range obsolete {
		for parent := path.Dir(name); managedName(parent); parent = path.Dir(parent) {
			if os.Remove(filepath.Join(root, parent)) != nil {
				break // A nonempty directory may contain user files or current assets.
			}
		}
	}
}
