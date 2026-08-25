package mcp

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/uvwt/agentdock/internal/app"
	"github.com/uvwt/agentdock/internal/config"
	toolskill "github.com/uvwt/agentdock/internal/tool/skill"
)

func TestSkillsExtensionRefreshesSnapshotOnSkillsList(t *testing.T) {
	root := t.TempDir()
	workspace := filepath.Join(root, "workspace")
	cfg := config.Config{
		AgentDockDefaultDir: workspace,
		AgentDockHome:       filepath.Join(root, ".agentdock"),
		MCPExportedSkills:   []string{"demo-skill"},
	}
	if err := cfg.Normalize(); err != nil {
		t.Fatalf("Normalize() error = %v", err)
	}
	runtime, err := app.NewRuntime(cfg)
	if err != nil {
		t.Fatalf("NewRuntime() error = %v", err)
	}
	defer func() { _ = runtime.Close() }()

	installExportTestSkill(t, runtime, workspace, "1.0.0", "first snapshot")

	serverTransport, clientTransport := mcpsdk.NewInMemoryTransports()
	server := NewServer(runtime, cfg)
	serverDone := make(chan error, 1)
	go func() { serverDone <- server.sdk.Run(t.Context(), serverTransport) }()

	client := mcpsdk.NewClient(
		&mcpsdk.Implementation{Name: "agentdock-skills-test", Version: "1.0.0"},
		&mcpsdk.ClientOptions{Capabilities: &mcpsdk.ClientCapabilities{}},
	)
	if err := mcpsdk.AddSendingCustomMethod[*skillsListParams, *skillsListResult](client, "skills/list"); err != nil {
		t.Fatal(err)
	}
	if err := mcpsdk.AddSendingCustomMethod[*skillsGetParams, *skillsGetResult](client, "skills/get"); err != nil {
		t.Fatal(err)
	}

	session, err := client.Connect(t.Context(), clientTransport, nil)
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}
	defer func() { _ = session.Close() }()

	initialize := session.InitializeResult()
	if initialize == nil || initialize.Capabilities == nil {
		t.Fatalf("InitializeResult() = %#v", initialize)
	}
	if _, ok := initialize.Capabilities.Extensions[skillsExtensionName]; !ok {
		t.Fatalf("skills extension not advertised: %#v", initialize.Capabilities.Extensions)
	}

	listed, err := mcpsdk.CallCustomMethod[*skillsListParams, *skillsListResult](
		t.Context(), session, "skills/list", &skillsListParams{},
	)
	if err != nil {
		t.Fatalf("skills/list error = %v", err)
	}
	if len(listed.Skills) != 1 {
		t.Fatalf("skills/list = %#v", listed.Skills)
	}
	manifest := listed.Skills[0]
	if manifest.URI != "skill://demo-skill/SKILL.md" {
		t.Fatalf("manifest URI = %q", manifest.URI)
	}
	if manifest.Frontmatter["license"] != "MIT" {
		t.Fatalf("frontmatter = %#v", manifest.Frontmatter)
	}
	if len(manifest.Resources) != 3 {
		t.Fatalf("resources = %#v", manifest.Resources)
	}
	for _, resource := range manifest.Resources {
		if !strings.HasPrefix(resource.Digest, "sha256:") || len(resource.Digest) != len("sha256:")+64 {
			t.Fatalf("invalid digest = %q", resource.Digest)
		}
		if strings.Contains(resource.URI, ".agentdock-install.json") {
			t.Fatalf("private install metadata leaked: %q", resource.URI)
		}
	}

	guideURI := "skill://demo-skill/references/guide%20one.md"
	if !manifestHasResource(manifest, guideURI) {
		t.Fatalf("encoded supporting resource missing: %#v", manifest.Resources)
	}
	got, err := mcpsdk.CallCustomMethod[*skillsGetParams, *skillsGetResult](
		t.Context(), session, "skills/get", &skillsGetParams{URI: manifest.URI},
	)
	if err != nil {
		t.Fatalf("skills/get error = %v", err)
	}
	if got.Skill.URI != manifest.URI || len(got.Skill.Resources) != len(manifest.Resources) {
		t.Fatalf("skills/get = %#v", got.Skill)
	}

	// 一次 Scan Tools 从 skills/list 开始；激活新版本后，在下一次 list 前仍必须读取旧快照。
	installExportTestSkill(t, runtime, workspace, "1.0.1", "second snapshot")
	resource, err := session.ReadResource(t.Context(), &mcpsdk.ReadResourceParams{URI: guideURI})
	if err != nil {
		t.Fatalf("resources/read error = %v", err)
	}
	if len(resource.Contents) != 1 || resource.Contents[0].URI != guideURI {
		t.Fatalf("resources/read = %#v", resource.Contents)
	}
	if !strings.Contains(resource.Contents[0].Text, "first snapshot") || strings.Contains(resource.Contents[0].Text, "second snapshot") {
		t.Fatalf("resources/read did not preserve the first catalog snapshot: %q", resource.Contents[0].Text)
	}
	binary, err := session.ReadResource(t.Context(), &mcpsdk.ReadResourceParams{URI: "skill://demo-skill/asset.bin"})
	if err != nil {
		t.Fatalf("binary resources/read error = %v", err)
	}
	if len(binary.Contents) != 1 || len(binary.Contents[0].Blob) != 3 || binary.Contents[0].Text != "" {
		t.Fatalf("binary resources/read = %#v", binary.Contents)
	}

	// 新一次 Scan Tools 会再次调用 skills/list，此时必须刷新到当前激活版本。
	refreshed, err := mcpsdk.CallCustomMethod[*skillsListParams, *skillsListResult](
		t.Context(), session, "skills/list", &skillsListParams{},
	)
	if err != nil {
		t.Fatalf("second skills/list error = %v", err)
	}
	if len(refreshed.Skills) != 1 || refreshed.Skills[0].Frontmatter["version"] != "1.0.1" {
		t.Fatalf("second skills/list did not refresh active Skill: %#v", refreshed.Skills)
	}
	resource, err = session.ReadResource(t.Context(), &mcpsdk.ReadResourceParams{URI: guideURI})
	if err != nil {
		t.Fatalf("resources/read after rescan error = %v", err)
	}
	if len(resource.Contents) != 1 || !strings.Contains(resource.Contents[0].Text, "second snapshot") || strings.Contains(resource.Contents[0].Text, "first snapshot") {
		t.Fatalf("resources/read did not refresh after new skills/list: %q", resource.Contents[0].Text)
	}

	if _, err := mcpsdk.CallCustomMethod[*skillsGetParams, *skillsGetResult](
		t.Context(), session, "skills/get", &skillsGetParams{URI: "skill://not-exported/SKILL.md"},
	); err == nil {
		t.Fatal("skills/get accepted a non-exported Skill")
	}

	if err := session.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	if err := <-serverDone; err != nil {
		t.Fatalf("Server.Run() error = %v", err)
	}
}

func TestSkillsExtensionIsAbsentWithoutConfiguredExports(t *testing.T) {
	root := t.TempDir()
	cfg := config.Config{AgentDockDefaultDir: filepath.Join(root, "workspace"), AgentDockHome: filepath.Join(root, ".agentdock")}
	if err := cfg.Normalize(); err != nil {
		t.Fatal(err)
	}
	runtime, err := app.NewRuntime(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = runtime.Close() }()

	serverTransport, clientTransport := mcpsdk.NewInMemoryTransports()
	server := NewServer(runtime, cfg)
	serverDone := make(chan error, 1)
	go func() { serverDone <- server.sdk.Run(t.Context(), serverTransport) }()

	client := mcpsdk.NewClient(
		&mcpsdk.Implementation{Name: "agentdock-skills-test", Version: "1.0.0"},
		&mcpsdk.ClientOptions{Capabilities: &mcpsdk.ClientCapabilities{}},
	)
	session, err := client.Connect(t.Context(), clientTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	if initialize := session.InitializeResult(); initialize != nil && initialize.Capabilities != nil {
		if _, ok := initialize.Capabilities.Extensions[skillsExtensionName]; ok {
			t.Fatalf("skills extension advertised without configured exports: %#v", initialize.Capabilities.Extensions)
		}
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func installExportTestSkill(t *testing.T, runtime *app.Runtime, workspace, version, marker string) {
	t.Helper()
	source := filepath.Join(workspace, "skill-source-"+version)
	if err := os.MkdirAll(filepath.Join(source, "references"), 0o700); err != nil {
		t.Fatal(err)
	}
	document := "---\nname: demo-skill\ndescription: Demo GPT export.\nversion: " + version + "\nlicense: MIT\n---\n\n# Demo\n\n" + marker + "\n"
	if err := os.WriteFile(filepath.Join(source, "SKILL.md"), []byte(document), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "references", "guide one.md"), []byte("guide: "+marker+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "asset.bin"), []byte{0xff, 0x00, 0x01}, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := runtime.Call(t.Context(), "skill_package", map[string]any{
		"action": "install", "source": source, "activate": true,
	}); err != nil {
		t.Fatalf("install Skill %s: %v", version, err)
	}
}

func manifestHasResource(manifest toolskill.ExportManifest, uri string) bool {
	for _, resource := range manifest.Resources {
		if resource.URI == uri {
			return true
		}
	}
	return false
}
