package app

import (
	"math"
	"strings"
	"testing"
)

func TestRenderTaskProgressReturnsProvidedSnapshot(t *testing.T) {
	runtime := &Runtime{}
	task := map[string]any{
		"id":                   "tsk_demo",
		"title":                "Demo task",
		"status":               "active",
		"completed_step_count": 1,
		"step_count":           2,
	}
	result, err := runtime.renderTaskProgress(map[string]any{"task": task, "title": "Progress"})
	if err != nil {
		t.Fatal(err)
	}
	gotTask, ok := result["task"].(map[string]any)
	if result["view"] != "task_progress" || !ok || gotTask["id"] != task["id"] || result["title"] != "Progress" {
		t.Fatalf("unexpected render result: %#v", result)
	}
	if _, err := runtime.renderTaskProgress(map[string]any{"task": map[string]any{"payload": strings.Repeat("x", maxRenderedObjectBytes)}}); err == nil {
		t.Fatal("expected oversized task snapshot to be rejected")
	}
}

func TestRenderFileDiffValidatesBoundedInput(t *testing.T) {
	runtime := &Runtime{}
	result, err := runtime.renderFileDiff(map[string]any{
		"diff":       "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n",
		"path":       "a.txt",
		"insertions": float64(1),
		"deletions":  1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result["view"] != "file_diff" || result["path"] != "a.txt" || result["insertions"] != int64(1) || result["deletions"] != int64(1) {
		t.Fatalf("unexpected diff render result: %#v", result)
	}

	if _, err := runtime.renderFileDiff(map[string]any{"diff": strings.Repeat("x", maxRenderedDiffChars+1)}); err == nil {
		t.Fatal("expected oversized diff to be rejected")
	}
	if _, err := runtime.renderFileDiff(map[string]any{"diff": 42}); err == nil {
		t.Fatal("expected non-string diff to be rejected")
	}
	for name, value := range map[string]any{
		"negative":     -1,
		"fractional":   1.5,
		"nan":          math.NaN(),
		"infinity":     math.Inf(1),
		"unsafe_float": float64(maxRenderedInteger) + 1,
		"overflow_int": int64(math.MaxInt64),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := runtime.renderFileDiff(map[string]any{"diff": "", "insertions": value}); err == nil {
				t.Fatalf("expected %v to be rejected", value)
			}
		})
	}
}

func TestRenderACPStatusRequiresObjectState(t *testing.T) {
	runtime := &Runtime{}
	state := map[string]any{"status": "running", "session_id": "acps_demo"}
	result, err := runtime.renderACPStatus(map[string]any{"state": state})
	if err != nil {
		t.Fatal(err)
	}
	gotState, ok := result["state"].(map[string]any)
	if result["view"] != "acp_status" || !ok || gotState["session_id"] != state["session_id"] {
		t.Fatalf("unexpected ACP render result: %#v", result)
	}
	if _, err := runtime.renderACPStatus(map[string]any{"state": "running"}); err == nil {
		t.Fatal("expected non-object ACP state to be rejected")
	}
	if _, err := runtime.renderACPStatus(map[string]any{"state": map[string]any{"payload": strings.Repeat("x", maxRenderedObjectBytes)}}); err == nil {
		t.Fatal("expected oversized ACP state to be rejected")
	}
}

func TestRenderToolInputSchemasAreStrict(t *testing.T) {
	for _, name := range []string{"render_task_progress", "render_file_diff", "render_acp_status"} {
		schema := InputSchema(name)
		if schema["additionalProperties"] != false {
			t.Fatalf("%s additionalProperties = %#v, want false", name, schema["additionalProperties"])
		}
	}
}
