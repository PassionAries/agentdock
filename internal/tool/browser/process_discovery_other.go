//go:build !darwin && !linux && !windows

package browser

import "context"

func browserProcessCommandLines(context.Context) ([]string, error) {
	return nil, nil
}
