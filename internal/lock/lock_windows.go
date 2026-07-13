//go:build windows

package lock

import (
	"errors"
	"os"
)

type fileHandle struct {
	file *os.File
	path string
}

func tryAcquire(path string) (Handle, bool, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
	if errors.Is(err, os.ErrExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return &fileHandle{file: file, path: path}, true, nil
}

func (h *fileHandle) Release() error {
	closeErr := h.file.Close()
	removeErr := os.Remove(h.path)
	if closeErr != nil {
		return closeErr
	}
	return removeErr
}
