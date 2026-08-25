package app

import (
	"net/url"
	"strings"
	"testing"
)

func TestCompanyKnowledgeSearchAndFetchExposeRecallAsReadOnlyDocuments(t *testing.T) {
	full := "---\ntype: runbook\n---\n\n# Deployment\nAgentDock deployment notes\n"
	store := map[string]string{
		"projects/agentdock/deployment.md": full,
		"private-notes/secret.md":          "AgentDock private secret",
	}
	rt, closeServer := newMemoryTestRuntime(t, store)
	defer closeServer()

	searched, err := rt.Call(t.Context(), "search", map[string]any{"query": "AgentDock"})
	if err != nil {
		t.Fatalf("search error = %v", err)
	}
	results, ok := searched["results"].([]any)
	if !ok || len(results) != 1 {
		t.Fatalf("search results = %#v", searched["results"])
	}
	item, ok := results[0].(map[string]any)
	if !ok {
		t.Fatalf("search item = %#v", results[0])
	}
	if item["id"] != "projects/agentdock/deployment.md" || item["title"] != "deployment" {
		t.Fatalf("search item identity = %#v", item)
	}
	if _, ok := item["text"]; ok {
		t.Fatalf("search result should stay on the canonical locator contract: %#v", item)
	}
	assertCompanyKnowledgeURL(t, item["url"], "projects/agentdock/deployment.md")

	fetched, err := rt.Call(t.Context(), "fetch", map[string]any{"id": item["id"]})
	if err != nil {
		t.Fatalf("fetch error = %v", err)
	}
	if fetched["id"] != item["id"] || fetched["title"] != "deployment" {
		t.Fatalf("fetch identity = %#v", fetched)
	}
	if fetched["text"] != full {
		t.Fatalf("fetch text = %q, want full Recall source", fetched["text"])
	}
	metadata, ok := fetched["metadata"].(map[string]any)
	if !ok || metadata["path"] != item["id"] || metadata["frontmatter"] == nil {
		t.Fatalf("fetch metadata = %#v", fetched["metadata"])
	}
	assertCompanyKnowledgeURL(t, fetched["url"], "projects/agentdock/deployment.md")
}

func TestCompanyKnowledgeFetchRejectsNonPublicRecallIDs(t *testing.T) {
	rt, closeServer := newMemoryTestRuntime(t, map[string]string{"private-notes/secret.md": "secret"})
	defer closeServer()

	for name, id := range map[string]string{
		"private note":              "private-notes/secret.md",
		"noncanonical private path": "projects/../private-notes/secret.md",
		"nested parent traversal":   "foo/../../private-notes/secret.md",
		"parent traversal":          "../outside.md",
	} {
		t.Run(name, func(t *testing.T) {
			_, err := rt.Call(t.Context(), "fetch", map[string]any{"id": id})
			if err == nil {
				t.Fatalf("fetch %q should fail", id)
			}
		})
	}
}

func TestCompanyKnowledgeSchemasUseCanonicalSearchAndFetchArguments(t *testing.T) {
	searchInput := InputSchema("search")
	searchRequired, _ := searchInput["required"].([]string)
	if len(searchRequired) != 1 || searchRequired[0] != "query" {
		t.Fatalf("search required = %#v", searchRequired)
	}
	fetchInput := InputSchema("fetch")
	fetchRequired, _ := fetchInput["required"].([]string)
	if len(fetchRequired) != 1 || fetchRequired[0] != "id" {
		t.Fatalf("fetch required = %#v", fetchRequired)
	}

	searchOutput := OutputSchema("search")
	results := searchOutput["properties"].(map[string]any)["results"].(map[string]any)
	item := results["items"].(map[string]any)
	itemRequired, _ := item["required"].([]string)
	if strings.Join(itemRequired, ",") != "id,title,url" {
		t.Fatalf("search result required = %#v", itemRequired)
	}
	fetchRequiredOutput, _ := OutputSchema("fetch")["required"].([]string)
	if strings.Join(fetchRequiredOutput, ",") != "id,title,text,url,metadata" {
		t.Fatalf("fetch output required = %#v", fetchRequiredOutput)
	}
}

func assertCompanyKnowledgeURL(t *testing.T, raw any, wantPath string) {
	t.Helper()
	value, ok := raw.(string)
	if !ok || value == "" {
		t.Fatalf("source URL = %#v", raw)
	}
	parsed, err := url.Parse(value)
	if err != nil || !parsed.IsAbs() {
		t.Fatalf("source URL must be absolute: %q, err=%v", value, err)
	}
	if got := parsed.Query().Get("path"); got != wantPath {
		t.Fatalf("source URL path query = %q, want %q", got, wantPath)
	}
	if parsed.Fragment != "recall/library" {
		t.Fatalf("source URL fragment = %q", parsed.Fragment)
	}
}
