//go:build !darwin

package command

func platformCommandPath(currentPath, _ string) string {
	return currentPath
}
