package storage

import (
	"path/filepath"
	"testing"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
)

func TestBackupRetentionAndSafeDelete(t *testing.T) {
	root := t.TempDir()
	store := Store{StatePath: filepath.Join(root, "state", "rules.json"), BackupDir: filepath.Join(root, "backups"), MaxBackups: 2}
	set := model.NewRuleSet()
	for index := 0; index < 3; index++ {
		if _, err := store.Backup(set); err != nil {
			t.Fatal(err)
		}
	}
	backups, err := store.ListBackups()
	if err != nil || len(backups) != 2 {
		t.Fatalf("retention not enforced: %v %v", backups, err)
	}
	if err := store.DeleteBackup(filepath.Join(root, "not-owned.json")); err == nil {
		t.Fatal("unsafe backup deletion was accepted")
	}
	if err := store.DeleteBackup(backups[0]); err != nil {
		t.Fatal(err)
	}
}
