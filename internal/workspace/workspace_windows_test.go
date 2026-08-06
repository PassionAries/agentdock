//go:build windows

package workspace

import "testing"

func TestRelativeReturnsAbsolutePathAcrossWindowsVolumes(t *testing.T) {
	ws := &Workspace{root: `C:\Users\Administrator\AgentDock`}
	target := `E:\PY\example\package.json`

	got, err := ws.Relative(target)
	if err != nil {
		t.Fatalf("Relative() error = %v", err)
	}
	if got != target {
		t.Fatalf("Relative() = %q, want %q", got, target)
	}
}
