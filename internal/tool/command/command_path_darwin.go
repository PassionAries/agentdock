//go:build darwin

package command

import (
	"path/filepath"
	"strings"
)

func platformCommandPath(currentPath, home string) string {
	entries := make([]string, 0, 8)
	if home != "" {
		entries = append(entries, filepath.Join(home, ".local", "bin"))
	}
	entries = append(entries, "/opt/homebrew/bin", "/usr/local/bin")
	entries = append(entries, filepath.SplitList(currentPath)...)

	seen := make(map[string]struct{}, len(entries))
	normalized := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry == "" {
			continue
		}
		if _, exists := seen[entry]; exists {
			continue
		}
		seen[entry] = struct{}{}
		normalized = append(normalized, entry)
	}
	return strings.Join(normalized, ":")
}
