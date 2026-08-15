//go:build darwin || linux

package browser

import (
	"context"
	"os/exec"
	"strings"
)

func browserProcessCommandLines(ctx context.Context) ([]string, error) {
	output, err := exec.CommandContext(ctx, "ps", "-axo", "command=").Output()
	if err != nil {
		return nil, err
	}
	lines := strings.Split(string(output), "\n")
	result := make([]string, 0, len(lines))
	for _, line := range lines {
		if line = strings.TrimSpace(line); line != "" {
			result = append(result, line)
		}
	}
	return result, nil
}
