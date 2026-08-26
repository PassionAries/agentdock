package app

import (
	"encoding/json"
	"math"
	"strings"
)

const (
	TaskProgressUIResourceURI = "ui://agentdock/task-progress"
	FileDiffUIResourceURI     = "ui://agentdock/file-diff"
	ACPStatusUIResourceURI    = "ui://agentdock/acp-status"

	maxRenderedDiffChars   = 262144
	maxRenderedObjectBytes = 262144
	maxRenderedInteger     = int64(1<<53 - 1)
)

func (r *Runtime) renderTaskProgress(args map[string]any) (Result, error) {
	task, err := requiredUIObject(args, "task")
	if err != nil {
		return nil, err
	}
	result := Result{"view": "task_progress", "task": task}
	if title, ok, err := optionalUIString(args, "title"); err != nil {
		return nil, err
	} else if ok {
		result["title"] = title
	}
	return result, nil
}

func (r *Runtime) renderFileDiff(args map[string]any) (Result, error) {
	diffValue, ok := args["diff"]
	if !ok {
		return nil, toolError("MISSING_DIFF", "diff is required", "validation")
	}
	diff, ok := diffValue.(string)
	if !ok {
		return nil, toolError("INVALID_DIFF", "diff must be a string", "validation")
	}
	if len([]rune(diff)) > maxRenderedDiffChars {
		return nil, toolErrorDetails("DIFF_TOO_LARGE", "diff exceeds the MCP App render limit", "validation", map[string]any{"max_chars": maxRenderedDiffChars})
	}

	result := Result{"view": "file_diff", "diff": diff}
	for _, key := range []string{"path", "summary"} {
		if value, present, err := optionalUIString(args, key); err != nil {
			return nil, err
		} else if present {
			result[key] = value
		}
	}
	for _, key := range []string{"insertions", "deletions"} {
		if value, present, err := optionalUIInteger(args, key); err != nil {
			return nil, err
		} else if present {
			result[key] = value
		}
	}
	return result, nil
}

func (r *Runtime) renderACPStatus(args map[string]any) (Result, error) {
	state, err := requiredUIObject(args, "state")
	if err != nil {
		return nil, err
	}
	result := Result{"view": "acp_status", "state": state}
	if title, ok, err := optionalUIString(args, "title"); err != nil {
		return nil, err
	} else if ok {
		result["title"] = title
	}
	return result, nil
}

func requiredUIObject(args map[string]any, key string) (map[string]any, error) {
	value, ok := args[key]
	if !ok {
		return nil, toolError("MISSING_"+strings.ToUpper(key), key+" is required", "validation")
	}
	object, ok := value.(map[string]any)
	if !ok {
		return nil, toolError("INVALID_"+strings.ToUpper(key), key+" must be an object", "validation")
	}
	encoded, err := json.Marshal(object)
	if err != nil {
		return nil, toolError("INVALID_"+strings.ToUpper(key), key+" must contain JSON-compatible values", "validation")
	}
	if len(encoded) > maxRenderedObjectBytes {
		return nil, toolErrorDetails(strings.ToUpper(key)+"_TOO_LARGE", key+" exceeds the MCP App render limit", "validation", map[string]any{"max_bytes": maxRenderedObjectBytes})
	}
	return object, nil
}

func optionalUIString(args map[string]any, key string) (string, bool, error) {
	value, ok := args[key]
	if !ok {
		return "", false, nil
	}
	text, ok := value.(string)
	if !ok {
		return "", false, toolError("INVALID_"+strings.ToUpper(key), key+" must be a string", "validation")
	}
	return text, true, nil
}

func optionalUIInteger(args map[string]any, key string) (int64, bool, error) {
	value, ok := args[key]
	if !ok {
		return 0, false, nil
	}
	invalid := func() (int64, bool, error) {
		return 0, false, toolError("INVALID_"+strings.ToUpper(key), key+" must be a non-negative safe integer", "validation")
	}
	switch number := value.(type) {
	case int:
		if number < 0 || uint64(number) > uint64(maxRenderedInteger) {
			return invalid()
		}
		return int64(number), true, nil
	case int64:
		if number < 0 || number > maxRenderedInteger {
			return invalid()
		}
		return number, true, nil
	case float64:
		if math.IsNaN(number) || math.IsInf(number, 0) || number < 0 || number > float64(maxRenderedInteger) || math.Trunc(number) != number {
			return invalid()
		}
		return int64(number), true, nil
	default:
		return invalid()
	}
}
