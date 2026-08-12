package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFromEnvLoadsInstructionsFile(t *testing.T) {
	setTestUserHome(t, t.TempDir())
	path := filepath.Join(t.TempDir(), "instructions.md")
	if err := os.WriteFile(path, []byte("\n# Guide\n\nUse absolute paths.\n"), 0o600); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
	t.Setenv("AGENTDOCK_INSTRUCTIONS_FILE", path)

	cfg, err := FromEnv()
	if err != nil {
		t.Fatalf("FromEnv() error = %v", err)
	}
	if err := cfg.Normalize(); err != nil {
		t.Fatalf("Normalize() error = %v", err)
	}
	if cfg.Instructions != "# Guide\n\nUse absolute paths." {
		t.Fatalf("Instructions = %q", cfg.Instructions)
	}
}

func TestNormalizeRejectsRelativeInstructionsFile(t *testing.T) {
	setTestUserHome(t, t.TempDir())
	t.Setenv("AGENTDOCK_INSTRUCTIONS_FILE", "relative/instructions.md")
	cfg, err := FromEnv()
	if err != nil {
		t.Fatalf("FromEnv() error = %v", err)
	}
	err = cfg.Normalize()
	if err == nil || !strings.Contains(err.Error(), "InstructionsFile") {
		t.Fatalf("Normalize() error = %v, want InstructionsFile", err)
	}
}

func TestNormalizeFailsWhenInstructionsFileMissing(t *testing.T) {
	setTestUserHome(t, t.TempDir())
	t.Setenv("AGENTDOCK_INSTRUCTIONS_FILE", filepath.Join(t.TempDir(), "missing.md"))
	cfg, err := FromEnv()
	if err != nil {
		t.Fatalf("FromEnv() error = %v", err)
	}
	if err := cfg.Normalize(); err == nil {
		t.Fatal("Normalize() accepted a missing instructions file")
	}
}
