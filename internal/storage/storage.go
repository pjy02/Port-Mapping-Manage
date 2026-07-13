package storage

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
)

type Store struct {
	StatePath string
	BackupDir string
	// MaxBackups is enforced after each successful backup. A value below one
	// keeps the default of 20 so callers cannot accidentally disable retention.
	MaxBackups int
}

func (s Store) Load() (model.RuleSet, error) {
	file, err := os.Open(s.StatePath)
	if errors.Is(err, os.ErrNotExist) {
		return model.NewRuleSet(), nil
	}
	if err != nil {
		return model.RuleSet{}, err
	}
	defer file.Close()
	set, err := model.Decode(file)
	if err != nil {
		return model.RuleSet{}, fmt.Errorf("load rule database: %w", err)
	}
	return set, nil
}

func (s Store) Save(set model.RuleSet) error {
	if err := set.Normalize(time.Now()); err != nil {
		return err
	}
	set.Generation++
	return WriteJSONAtomic(s.StatePath, set, 0o600)
}

func (s Store) Backup(set model.RuleSet) (string, error) {
	if err := set.Normalize(time.Now()); err != nil {
		return "", err
	}
	if err := os.MkdirAll(s.BackupDir, 0o700); err != nil {
		return "", err
	}
	name := fmt.Sprintf("rules-%s-%d.json", time.Now().UTC().Format("20060102T150405.000000000Z"), os.Getpid())
	path := filepath.Join(s.BackupDir, name)
	if err := WriteJSONAtomic(path, set, 0o600); err != nil {
		return "", err
	}
	if err := s.PruneBackups(); err != nil {
		return path, fmt.Errorf("backup created but retention cleanup failed: %w", err)
	}
	return path, nil
}

func (s Store) PruneBackups() error {
	backups, err := s.ListBackups()
	if err != nil {
		return err
	}
	limit := s.MaxBackups
	if limit < 1 {
		limit = 20
	}
	for _, path := range backups[minimum(limit, len(backups)):] {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

// DeleteBackup removes only a file returned by ListBackups from this store.
func (s Store) DeleteBackup(path string) error {
	cleanDir, err := filepath.Abs(filepath.Clean(s.BackupDir))
	if err != nil {
		return err
	}
	cleanPath, err := filepath.Abs(filepath.Clean(path))
	if err != nil {
		return err
	}
	name := filepath.Base(cleanPath)
	if filepath.Dir(cleanPath) != cleanDir || !strings.HasPrefix(name, "rules-") || !strings.HasSuffix(name, ".json") {
		return fmt.Errorf("refusing to remove non-PMM backup %s", path)
	}
	info, err := os.Lstat(cleanPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing to remove non-regular backup %s", path)
	}
	return os.Remove(cleanPath)
}

func (s Store) ListBackups() ([]string, error) {
	entries, err := os.ReadDir(s.BackupDir)
	if errors.Is(err, os.ErrNotExist) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	var result []string
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), "rules-") || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		info, infoErr := entry.Info()
		if infoErr != nil {
			return nil, infoErr
		}
		if info.Mode().IsRegular() && info.Mode()&os.ModeSymlink == 0 {
			result = append(result, filepath.Join(s.BackupDir, entry.Name()))
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(result)))
	return result, nil
}

func WriteJSONAtomic(path string, value any, mode os.FileMode) error {
	return writeAtomic(path, mode, func(file *os.File) error {
		encoder := json.NewEncoder(file)
		encoder.SetIndent("", "  ")
		return encoder.Encode(value)
	})
}

func WriteFileAtomic(path string, data []byte, mode os.FileMode) error {
	return writeAtomic(path, mode, func(file *os.File) error {
		_, err := file.Write(data)
		return err
	})
}

func writeAtomic(path string, mode os.FileMode, write func(*os.File) error) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(dir, ".pmm-*.tmp")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	committed := false
	defer func() {
		_ = temp.Close()
		if !committed {
			_ = os.Remove(tempName)
		}
	}()
	if err := temp.Chmod(mode); err != nil {
		return err
	}
	if err := write(temp); err != nil {
		return err
	}
	if err := temp.Sync(); err != nil {
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempName, path); err != nil {
		return err
	}
	// The rename is the logical commit point. Directory fsync is best-effort:
	// returning an error after rename would make callers roll the kernel back
	// even though the database already contains the new state.
	_ = syncDirectory(dir)
	committed = true
	return nil
}

func minimum(left, right int) int {
	if left < right {
		return left
	}
	return right
}
