//go:build !windows

package selfupdate

import (
	"context"
	"io"
)

func RepairDesktopRuntimeIfNeeded(context.Context, io.Writer) error {
	return nil
}
