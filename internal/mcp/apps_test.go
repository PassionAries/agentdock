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

func assertToolUIResource(t *testing.T, tool *mcpsdk.Tool, uri string) {
	t.Helper()
	if tool == nil {
		t.Fatal("UI tool is nil")
	}
	ui, ok := tool.Meta["ui"].(map[string]any)
	if !ok || ui["resourceUri"] != uri {
		t.Fatalf("%s standard ui metadata = %#v", tool.Name, tool.Meta["ui"])
	}
	if len(tool.Meta) != 1 {
		t.Fatalf("%s should expose only standard ui metadata: %#v", tool.Name, tool.Meta)
	}
}

func assertResourceUIMeta(t *testing.T, meta mcpsdk.Meta, domain string) {
	t.Helper()
	ui, ok := meta["ui"].(map[string]any)
	if !ok || ui["prefersBorder"] != true {
		t.Fatalf("standard resource ui metadata = %#v", meta["ui"])
	}
	csp, ok := ui["csp"].(map[string]any)
	if !ok || csp["connectDomains"] == nil || csp["resourceDomains"] == nil {
		t.Fatalf("standard resource csp = %#v", ui["csp"])
	}
	if domain == "" {
		if _, exists := ui["domain"]; exists {
			t.Fatalf("unexpected resource ui.domain = %#v", ui["domain"])
		}
	} else if ui["domain"] != domain {
		t.Fatalf("resource domain metadata = %#v", meta)
	}
	if len(meta) != 1 {
		t.Fatalf("resource should expose only standard ui metadata: %#v", meta)
	}
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

func TestMCPAppsBindResourcesDirectlyToBusinessTools(t *testing.T) {
	root := t.TempDir()
	const widgetDomain = "https://dockmini.example.test"
	harness := newMCPAppTestHarness(t, config.Config{
		AgentDockDefaultDir: root,
		AgentDockHome:       filepath.Join(root, ".agentdock"),
		OAuthServerURL:      widgetDomain + "/",
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
	if len(tools) != 18 {
		t.Fatalf("tools/list count = %d, want 18", len(tools))
	}
	contextTool := tools["agentdock_context"]
	if contextTool == nil {
		t.Fatal("tools/list did not expose agentdock_context")
	}
	assertToolUIResource(t, contextTool, app.AgentContextUIResourceURI)
	fileEditTool := tools["file_edit"]
	if fileEditTool == nil {
		t.Fatal("tools/list did not expose file_edit")
	}
	assertToolUIResource(t, fileEditTool, app.FileChangeUIResourceURI)
	taskManageTool := tools["task_manage"]
	if taskManageTool == nil {
		t.Fatal("tools/list did not expose task_manage")
	}
	assertToolUIResource(t, taskManageTool, app.TaskProgressUIResourceURI)
	if taskManageTool.Annotations == nil || taskManageTool.Annotations.ReadOnlyHint {
		t.Fatalf("task_manage annotations = %#v", taskManageTool.Annotations)
	}

	resources := map[string]*mcpsdk.Resource{}
	for resource, err := range harness.session.Resources(t.Context(), nil) {
		if err != nil {
			t.Fatalf("Resources() error = %v", err)
		}
		resources[resource.URI] = resource
	}
	if len(resources) != 3 {
		t.Fatalf("resources/list count = %d, want 3", len(resources))
	}
	for _, uri := range []string{app.AgentContextUIResourceURI, app.TaskProgressUIResourceURI, app.FileChangeUIResourceURI} {
		resource := resources[uri]
		if resource == nil || resource.MIMEType != mcpAppMIMEType {
			t.Fatalf("resource %s = %#v", uri, resource)
		}
		read, err := harness.session.ReadResource(t.Context(), &mcpsdk.ReadResourceParams{URI: uri})
		if err != nil {
			t.Fatalf("ReadResource(%s) error = %v", uri, err)
		}
		if len(read.Contents) != 1 || read.Contents[0].MIMEType != mcpAppMIMEType || !strings.Contains(read.Contents[0].Text, `window.addEventListener("message"`) || !strings.Contains(read.Contents[0].Text, "connect-src 'none'") {
			t.Fatalf("ReadResource(%s) = %#v", uri, read.Contents)
		}
		html := read.Contents[0].Text
		for _, marker := range []string{
			`window.parent.postMessage({jsonrpc:"2.0",id,method`,
			`rpcRequest("ui/initialize"`,
			`protocolVersion:"2026-01-26"`,
			`rpcNotify("ui/notifications/initialized"`,
			`rpcNotify("ui/notifications/size-changed",{height})`,
			`html.style.height="max-content"`,
			`html.getBoundingClientRect().height`,
			`new ResizeObserver(reportSize)`,
			`startAutoResize()`,
			`message.method==="ui/notifications/tool-result"`,
			`message.params&&message.params.structuredContent`,
		} {
			if !strings.Contains(html, marker) {
				t.Fatalf("resource %s missing standard MCP Apps bridge marker %q", uri, marker)
			}
		}
		for _, legacy := range []string{"window.openai", "toolOutput", "openai/widget", "openai/outputTemplate", "ui/resourceUri"} {
			if strings.Contains(html, legacy) {
				t.Fatalf("resource %s contains legacy bridge marker %q", uri, legacy)
			}
		}
		assertResourceUIMeta(t, resource.Meta, widgetDomain)
		assertResourceUIMeta(t, read.Contents[0].Meta, widgetDomain)
	}
	contextRead, err := harness.session.ReadResource(t.Context(), &mcpsdk.ReadResourceParams{URI: app.AgentContextUIResourceURI})
	if err != nil {
		t.Fatalf("ReadResource(agent context) error = %v", err)
	}
	if len(contextRead.Contents) != 1 {
		t.Fatalf("agent context resource = %#v", contextRead.Contents)
	}
	for _, marker := range []string{`expectedView="agentdock_context"`, "renderAgentContext", "contextSectionItemCount", `skills+" Skills"`, `mcps+" MCP"`, `workflows+" Workflow"`, `summary.push("Recall")`} {
		if !strings.Contains(contextRead.Contents[0].Text, marker) {
			t.Fatalf("agent context resource missing compact summary marker %q", marker)
		}
	}

	fileChangeRead, err := harness.session.ReadResource(t.Context(), &mcpsdk.ReadResourceParams{URI: app.FileChangeUIResourceURI})
	if err != nil {
		t.Fatalf("ReadResource(file change) error = %v", err)
	}
	if len(fileChangeRead.Contents) != 1 || !strings.Contains(fileChangeRead.Contents[0].Text, `expectedView="file_change"`) || !strings.Contains(fileChangeRead.Contents[0].Text, "renderFileChange") || strings.Contains(fileChangeRead.Contents[0].Text, "innerHTML") {
		t.Fatalf("file change resource = %#v", fileChangeRead.Contents)
	}
	fileChangeHTML := fileChangeRead.Contents[0].Text
	for _, marker := range []string{"background:#fff;color:#111", `end.append(el("span","brand","AgentDock"))`, ".compact-toggle", ".detail-panel[hidden]", `toggle.setAttribute("aria-expanded","false")`, `toggle.addEventListener("click"`, ".diff-add{color:#315b45;background:#f5fbf7", ".diff-del{color:#7a3e39;background:#fff7f6", `line.startsWith("--- ")`, `line.startsWith("+++ ")`, `line.startsWith("@@")`} {
		if !strings.Contains(fileChangeHTML, marker) {
			t.Fatalf("file change resource missing simplified UI marker %q", marker)
		}
	}
	taskRead, err := harness.session.ReadResource(t.Context(), &mcpsdk.ReadResourceParams{URI: app.TaskProgressUIResourceURI})
	if err != nil {
		t.Fatalf("ReadResource(task progress) error = %v", err)
	}
	for _, marker := range []string{".compact-progress", ".progress-fill", ".progress-node.completed", ".progress-node.in-progress", ".progress-node.blocked", `node.title=(step.title||step.id||"Step")+" · "+status`, `fill.style.width="calc((100% - 14px) * "+ratio+")"`, "taskProgress(steps)", ".steps::before", ".step-marker", `status==="completed"?"✓"`} {
		if len(taskRead.Contents) != 1 || !strings.Contains(taskRead.Contents[0].Text, marker) {
			t.Fatalf("task resource missing vertical progress marker %q", marker)
		}
	}
	if resources[app.ACPStatusUIResourceURI] != nil {
		t.Fatal("ACP UI resource should not be listed when ACP is disabled")
	}

	contextResult, err := harness.session.CallTool(t.Context(), &mcpsdk.CallToolParams{Name: "agentdock_context", Arguments: map[string]any{}})
	if err != nil || contextResult.IsError {
		t.Fatalf("agentdock_context result=%#v err=%v", contextResult, err)
	}
	contextStructured, ok := contextResult.StructuredContent.(map[string]any)
	if !ok || contextStructured["context"] == nil || len(contextStructured) != 1 {
		t.Fatalf("agentdock_context structuredContent = %#v", contextResult.StructuredContent)
	}

	filePath := filepath.Join(root, "note.txt")
	if err := os.WriteFile(filePath, []byte("alpha\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	fileEditResult, err := harness.session.CallTool(t.Context(), &mcpsdk.CallToolParams{
		Name: "file_edit",
		Arguments: map[string]any{
			"action": "replace", "path": "note.txt", "old": "alpha", "new": "beta", "dry_run": true,
		},
	})
	if err != nil || fileEditResult.IsError {
		t.Fatalf("file_edit result=%#v err=%v", fileEditResult, err)
	}
	fileEditStructured, ok := fileEditResult.StructuredContent.(map[string]any)
	if !ok || fileEditStructured["action"] != "replace" || fileEditStructured["dry_run"] != true || fileEditStructured["view"] != nil {
		t.Fatalf("file_edit structuredContent = %#v", fileEditResult.StructuredContent)
	}
	diffPreview, _ := fileEditStructured["diff_preview"].(string)
	if !strings.Contains(diffPreview, "beta") {
		t.Fatalf("file_edit diff_preview = %q", diffPreview)
	}
	fileBytes, err := os.ReadFile(filePath)
	if err != nil || string(fileBytes) != "alpha\n" {
		t.Fatalf("dry-run changed file: content=%q err=%v", fileBytes, err)
	}
	errorResult, err := harness.session.CallTool(t.Context(), &mcpsdk.CallToolParams{
		Name: "file_edit",
		Arguments: map[string]any{
			"action": "replace", "path": "note.txt", "old": "missing", "new": "beta", "expected_matches": 1,
		},
	})
	if err != nil || !errorResult.IsError {
		t.Fatalf("file_edit validation error result=%#v err=%v", errorResult, err)
	}
	errorStructured, ok := errorResult.StructuredContent.(map[string]any)
	if !ok || errorStructured["code"] != "MATCH_COUNT_MISMATCH" {
		t.Fatalf("file_edit validation structuredContent = %#v", errorResult.StructuredContent)
	}

	createdTask, err := harness.session.CallTool(t.Context(), &mcpsdk.CallToolParams{
		Name: "task_manage",
		Arguments: map[string]any{
			"action": "create", "title": "Widget task", "goal": "verify direct task UI",
			"completion_conditions": []string{"done"},
			"steps":                 []map[string]any{{"id": "verify", "title": "Verify"}},
		},
	})
	if err != nil || createdTask.IsError {
		t.Fatalf("task_manage create result=%#v err=%v", createdTask, err)
	}
	createdTaskStructured, ok := createdTask.StructuredContent.(map[string]any)
	if !ok || createdTaskStructured["action"] != "create" || createdTaskStructured["view"] != nil || createdTaskStructured["task_summary"] == nil {
		t.Fatalf("task_manage create structuredContent = %#v", createdTask.StructuredContent)
	}
	listedTasks, err := harness.session.CallTool(t.Context(), &mcpsdk.CallToolParams{Name: "task_manage", Arguments: map[string]any{"action": "list"}})
	if err != nil || listedTasks.IsError {
		t.Fatalf("task_manage list result=%#v err=%v", listedTasks, err)
	}
	listedStructured, ok := listedTasks.StructuredContent.(map[string]any)
	if !ok || listedStructured["action"] != "list" || listedStructured["tasks"] == nil {
		t.Fatalf("task_manage list structuredContent = %#v", listedTasks.StructuredContent)
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

	tools := map[string]*mcpsdk.Tool{}
	for tool, err := range harness.session.Tools(t.Context(), nil) {
		if err != nil {
			t.Fatal(err)
		}
		tools[tool.Name] = tool
	}
	if len(tools) != 21 {
		t.Fatalf("tools/list count = %d, want 21", len(tools))
	}
	assertToolUIResource(t, tools["acp_session"], app.ACPStatusUIResourceURI)
	for _, name := range []string{"acp_prompt", "acp_interaction"} {
		if tool := tools[name]; tool == nil {
			t.Fatalf("%s was not exposed", name)
		} else if tool.Meta["ui"] != nil {
			t.Fatalf("%s should not bind a static ACP widget: %#v", name, tool.Meta)
		}
	}

	read, err := harness.session.ReadResource(t.Context(), &mcpsdk.ReadResourceParams{URI: app.ACPStatusUIResourceURI})
	if err != nil {
		t.Fatalf("ReadResource() error = %v", err)
	}
	if len(read.Contents) != 1 || !strings.Contains(read.Contents[0].Text, "acp_status") {
		t.Fatalf("ACP resource contents = %#v", read.Contents)
	}
	for _, marker := range []string{"message-role", `message.role!=="user"&&message.role!=="assistant"`, "No user or assistant messages in this AgentDock process.", `compactShell({action:state.action||"status",title:identity}`} {
		if !strings.Contains(read.Contents[0].Text, marker) {
			t.Fatalf("ACP resource missing conversation marker %q", marker)
		}
	}
	assertResourceUIMeta(t, read.Contents[0].Meta, "")

	sessionList, err := harness.session.CallTool(t.Context(), &mcpsdk.CallToolParams{Name: "acp_session", Arguments: map[string]any{"action": "list"}})
	if err != nil || sessionList.IsError {
		t.Fatalf("acp_session list result=%#v err=%v", sessionList, err)
	}
	sessionStructured, ok := sessionList.StructuredContent.(map[string]any)
	if !ok || sessionStructured["action"] != "list" || sessionStructured["sessions"] == nil || sessionStructured["view"] != nil {
		t.Fatalf("acp_session list structuredContent = %#v", sessionList.StructuredContent)
	}

}

func TestAppWidgetDomainRequiresHTTPSOrigin(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "https origin", raw: "https://dockmini.example.test/", want: "https://dockmini.example.test"},
		{name: "https port", raw: "https://dockmini.example.test:8443", want: "https://dockmini.example.test:8443"},
		{name: "empty", raw: "", want: ""},
		{name: "http", raw: "http://127.0.0.1:8765", want: ""},
		{name: "path", raw: "https://dockmini.example.test/mcp", want: ""},
		{name: "query", raw: "https://dockmini.example.test?x=1", want: ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := appWidgetDomain(test.raw); got != test.want {
				t.Fatalf("appWidgetDomain(%q) = %q, want %q", test.raw, got, test.want)
			}
		})
	}
}
