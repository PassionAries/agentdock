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

func TestNormalizeAcceptsInstructionsFileAtSizeLimit(t *testing.T) {
	setTestUserHome(t, t.TempDir())
	path := filepath.Join(t.TempDir(), "instructions.md")
	content := strings.Repeat("a", maxInstructionsFileBytes)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
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
	if cfg.Instructions != content {
		t.Fatalf("Instructions length = %d, want %d", len(cfg.Instructions), len(content))
	}
}

func TestNormalizeRejectsInstructionsFileOverSizeLimit(t *testing.T) {
	setTestUserHome(t, t.TempDir())
	path := filepath.Join(t.TempDir(), "instructions.md")
	if err := os.WriteFile(path, []byte(strings.Repeat("a", maxInstructionsFileBytes+1)), 0o600); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
	t.Setenv("AGENTDOCK_INSTRUCTIONS_FILE", path)

	cfg, err := FromEnv()
	if err != nil {
		t.Fatalf("FromEnv() error = %v", err)
	}
	if err := cfg.Normalize(); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("Normalize() error = %v, want size limit error", err)
	}
}

func TestNormalizeRejectsEmptyInstructionsFile(t *testing.T) {
	for _, test := range []struct {
		name    string
		content string
	}{
		{name: "empty", content: ""},
		{name: "whitespace only", content: " \n\t "},
	} {
		t.Run(test.name, func(t *testing.T) {
			setTestUserHome(t, t.TempDir())
			path := filepath.Join(t.TempDir(), "instructions.md")
			if err := os.WriteFile(path, []byte(test.content), 0o600); err != nil {
				t.Fatalf("WriteFile() error = %v", err)
			}
			t.Setenv("AGENTDOCK_INSTRUCTIONS_FILE", path)

			cfg, err := FromEnv()
			if err != nil {
				t.Fatalf("FromEnv() error = %v", err)
			}
			if err := cfg.Normalize(); err == nil || !strings.Contains(err.Error(), "non-empty") {
				t.Fatalf("Normalize() error = %v, want non-empty instructions error", err)
			}
		})
	}
}

func TestNormalizeRejectsInvalidUTF8InstructionsFile(t *testing.T) {
	setTestUserHome(t, t.TempDir())
	path := filepath.Join(t.TempDir(), "instructions.md")
	if err := os.WriteFile(path, []byte{0xff, 0xfe}, 0o600); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
	t.Setenv("AGENTDOCK_INSTRUCTIONS_FILE", path)

	cfg, err := FromEnv()
	if err != nil {
		t.Fatalf("FromEnv() error = %v", err)
	}
	if err := cfg.Normalize(); err == nil || !strings.Contains(err.Error(), "UTF-8") {
		t.Fatalf("Normalize() error = %v, want UTF-8 error", err)
	}
}

func TestNormalizeRejectsNonRegularInstructionsFile(t *testing.T) {
	setTestUserHome(t, t.TempDir())
	t.Setenv("AGENTDOCK_INSTRUCTIONS_FILE", t.TempDir())

	cfg, err := FromEnv()
	if err != nil {
		t.Fatalf("FromEnv() error = %v", err)
	}
	if err := cfg.Normalize(); err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatalf("Normalize() error = %v, want regular file error", err)
	}
}
