package lock

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type Handle interface {
	Release() error
}

func Acquire(ctx context.Context, path string, timeout time.Duration) (Handle, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	deadline := time.Now().Add(timeout)
	for {
		handle, acquired, err := tryAcquire(path)
		if err != nil {
			return nil, err
		}
		if acquired {
			return handle, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("等待操作锁超时：%s", path)
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
}
