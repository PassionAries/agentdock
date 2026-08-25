package config

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestNormalizeMCPExportedSkillsDeduplicatesAndCapsSelection(t *testing.T) {
	root := t.TempDir()
	cfg := Config{
		AgentDockHome:       filepath.Join(root, ".agentdock"),
		AgentDockDefaultDir: filepath.Join(root, "workspace"),
		MCPExportedSkills:   []string{"alpha", " beta ", "alpha", "gamma", "delta", "epsilon"},
	}
	if err := cfg.Normalize(); err != nil {
		t.Fatalf("Normalize() error = %v", err)
	}
	want := []string{"alpha", "beta", "gamma", "delta", "epsilon"}
	if strings.Join(cfg.MCPExportedSkills, ",") != strings.Join(want, ",") {
		t.Fatalf("MCPExportedSkills = %#v, want %#v", cfg.MCPExportedSkills, want)
	}

	cfg.MCPExportedSkills = []string{"one", "two", "three", "four", "five", "six"}
	if err := cfg.Normalize(); err == nil || !strings.Contains(err.Error(), "at most 5 skills") {
		t.Fatalf("Normalize() error = %v, want max-five validation", err)
	}
}

func TestFromEnvReadsMCPExportedSkills(t *testing.T) {
	t.Setenv("AGENTDOCK_MCP_EXPORTED_SKILLS", "alpha,beta")
	cfg, err := FromEnv()
	if err != nil {
		t.Fatalf("FromEnv() error = %v", err)
	}
	if strings.Join(cfg.MCPExportedSkills, ",") != "alpha,beta" {
		t.Fatalf("MCPExportedSkills = %#v", cfg.MCPExportedSkills)
	}
}
