package mcp

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/uvwt/agentdock/internal/app"
	"github.com/uvwt/agentdock/internal/config"
)

type mcpAppTestHarness struct {
	runtime    *app.Runtime
	session    *mcpsdk.ClientSession
	serverDone chan error
}

func newMCPAppTestHarness(t *testing.T, cfg config.Config) *mcpAppTestHarness {
	t.Helper()
	if err := cfg.Normalize(); err != nil {
		t.Fatalf("Normalize() error = %v", err)
	}
	runtime, err := app.NewRuntime(cfg)
	if err != nil {
		t.Fatalf("NewRuntime() error = %v", err)
	}

	serverTransport, clientTransport := mcpsdk.NewInMemoryTransports()
	server := NewServer(runtime, cfg)
	serverDone := make(chan error, 1)
	go func() { serverDone <- server.sdk.Run(t.Context(), serverTransport) }()

	client := mcpsdk.NewClient(
		&mcpsdk.Implementation{Name: "agentdock-mcp-apps-test", Version: "1.0.0"},
		&mcpsdk.ClientOptions{Capabilities: &mcpsdk.ClientCapabilities{}},
	)
	session, err := client.Connect(t.Context(), clientTransport, nil)
	if err != nil {
		_ = runtime.Close()
		t.Fatalf("Connect() error = %v", err)
	}

	harness := &mcpAppTestHarness{runtime: runtime, session: session, serverDone: serverDone}
	t.Cleanup(func() {
		if err := session.Close(); err != nil {
			t.Errorf("Close() error = %v", err)
		}
		if err := <-serverDone; err != nil && !errors.Is(err, context.Canceled) {
			t.Errorf("Server.Run() error = %v", err)
		}
		if err := runtime.Close(); err != nil {
			t.Errorf("Runtime.Close() error = %v", err)
		}
	})
	return harness
}

func TestMCPAppsExposeReadOnlyRenderToolsAndResources(t *testing.T) {
	root := t.TempDir()
	harness := newMCPAppTestHarness(t, config.Config{
		AgentDockDefaultDir: root,
		AgentDockHome:       filepath.Join(root, ".agentdock"),
	})

	initialize := harness.session.InitializeResult()
	if initialize == nil || initialize.Capabilities == nil || initialize.Capabilities.Resources == nil {
		t.Fatalf("resources capability not advertised: %#v", initialize)
	}

	tools := map[string]*mcpsdk.Tool{}
	for tool, err := range harness.session.Tools(t.Context(), nil) {
		if err != nil {
			t.Fatalf("Tools() error = %v", err)
		}
		tools[tool.Name] = tool
	}
	for name, uri := range map[string]string{
		"render_task_progress": app.TaskProgressUIResourceURI,
		"render_file_diff":     app.FileDiffUIResourceURI,
	} {
		tool := tools[name]
		if tool == nil {
			t.Fatalf("tools/list did not expose %q", name)
		}
		if tool.Meta["ui/resourceUri"] != uri || tool.Meta["openai/outputTemplate"] != uri {
			t.Fatalf("%s _meta = %#v", name, tool.Meta)
		}
		if tool.Annotations == nil || !tool.Annotations.ReadOnlyHint || tool.Annotations.DestructiveHint == nil || *tool.Annotations.DestructiveHint || tool.Annotations.OpenWorldHint == nil || *tool.Annotations.OpenWorldHint {
			t.Fatalf("%s annotations = %#v", name, tool.Annotations)
		}
	}
	if tools["render_acp_status"] != nil {
		t.Fatal("render_acp_status should not be exposed when ACP is disabled")
	}

	resources := map[string]*mcpsdk.Resource{}
	for resource, err := range harness.session.Resources(t.Context(), nil) {
		if err != nil {
			t.Fatalf("Resources() error = %v", err)
		}
		resources[resource.URI] = resource
	}
	for _, uri := range []string{app.TaskProgressUIResourceURI, app.FileDiffUIResourceURI} {
		resource := resources[uri]
		if resource == nil || resource.MIMEType != mcpAppMIMEType {
			t.Fatalf("resource %s = %#v", uri, resource)
		}
		read, err := harness.session.ReadResource(t.Context(), &mcpsdk.ReadResourceParams{URI: uri})
		if err != nil {
			t.Fatalf("ReadResource(%s) error = %v", uri, err)
		}
		if len(read.Contents) != 1 || read.Contents[0].MIMEType != mcpAppMIMEType || !strings.Contains(read.Contents[0].Text, "window.openai") || !strings.Contains(read.Contents[0].Text, "connect-src 'none'") {
			t.Fatalf("ReadResource(%s) = %#v", uri, read.Contents)
		}
		if read.Contents[0].Meta["openai/widgetPrefersBorder"] != true || read.Contents[0].Meta["openai/widgetCSP"] == nil {
			t.Fatalf("resource meta %s = %#v", uri, read.Contents[0].Meta)
		}
	}
	if resources[app.ACPStatusUIResourceURI] != nil {
		t.Fatal("ACP UI resource should not be listed when ACP is disabled")
	}

	taskResult, err := harness.session.CallTool(t.Context(), &mcpsdk.CallToolParams{
		Name: "render_task_progress",
		Arguments: map[string]any{"task": map[string]any{
			"id": "tsk_demo", "title": "Demo", "status": "active", "completed_step_count": 1, "step_count": 2,
		}},
	})
	if err != nil || taskResult.IsError {
		t.Fatalf("render_task_progress result=%#v err=%v", taskResult, err)
	}
	taskStructured, ok := taskResult.StructuredContent.(map[string]any)
	if !ok || taskStructured["view"] != "task_progress" {
		t.Fatalf("render_task_progress structuredContent = %#v", taskResult.StructuredContent)
	}

	diffResult, err := harness.session.CallTool(t.Context(), &mcpsdk.CallToolParams{
		Name:      "render_file_diff",
		Arguments: map[string]any{"diff": "--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n", "path": "a"},
	})
	if err != nil || diffResult.IsError {
		t.Fatalf("render_file_diff result=%#v err=%v", diffResult, err)
	}
	diffStructured, ok := diffResult.StructuredContent.(map[string]any)
	if !ok || diffStructured["view"] != "file_diff" || diffStructured["path"] != "a" {
		t.Fatalf("render_file_diff structuredContent = %#v", diffResult.StructuredContent)
	}
}

func TestMCPAppsExposeACPViewOnlyWhenACPEnabled(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	harness := newMCPAppTestHarness(t, config.Config{
		AgentDockDefaultDir: root,
		AgentDockHome:       filepath.Join(root, ".agentdock"),
		ACPEnabled:          true,
		ACPAgentName:        "helper",
		ACPCommand:          executable,
	})

	var renderTool *mcpsdk.Tool
	for tool, err := range harness.session.Tools(t.Context(), nil) {
		if err != nil {
			t.Fatal(err)
		}
		if tool.Name == "render_acp_status" {
			renderTool = tool
			break
		}
	}
	if renderTool == nil || renderTool.Meta["ui/resourceUri"] != app.ACPStatusUIResourceURI || renderTool.Meta["openai/outputTemplate"] != app.ACPStatusUIResourceURI {
		t.Fatalf("render_acp_status = %#v", renderTool)
	}

	read, err := harness.session.ReadResource(t.Context(), &mcpsdk.ReadResourceParams{URI: app.ACPStatusUIResourceURI})
	if err != nil {
		t.Fatalf("ReadResource() error = %v", err)
	}
	if len(read.Contents) != 1 || !strings.Contains(read.Contents[0].Text, "acp_status") {
		t.Fatalf("ACP resource contents = %#v", read.Contents)
	}

	result, err := harness.session.CallTool(t.Context(), &mcpsdk.CallToolParams{
		Name:      "render_acp_status",
		Arguments: map[string]any{"state": map[string]any{"status": "running", "session_id": "acps_demo"}},
	})
	if err != nil || result.IsError {
		t.Fatalf("render_acp_status result=%#v err=%v", result, err)
	}
	structured, ok := result.StructuredContent.(map[string]any)
	if !ok || structured["view"] != "acp_status" {
		t.Fatalf("render_acp_status structuredContent = %#v", result.StructuredContent)
	}
}
