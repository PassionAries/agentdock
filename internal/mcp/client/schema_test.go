package client

import (
	"errors"
	"testing"
)

func TestCompileToolInputSchemaSupportsDraft2020Keywords(t *testing.T) {
	validator, err := compileToolInputSchema(map[string]any{
		"type": "object",
		"properties": map[string]any{
			"name": map[string]any{"$ref": "#/$defs/nonEmptyName"},
		},
		"required":             []any{"name"},
		"additionalProperties": false,
		"$defs": map[string]any{
			"nonEmptyName": map[string]any{
				"type":      "string",
				"minLength": 2,
				"pattern":   "^[A-Z]",
			},
		},
	})
	if err != nil {
		t.Fatalf("compileToolInputSchema() error = %v", err)
	}
	tool := Tool{Name: "create_user", inputValidator: validator}
	if err := validateToolArguments(tool, map[string]any{"name": "Alice"}); err != nil {
		t.Fatalf("validateToolArguments(valid) error = %v", err)
	}
	if err := validateToolArguments(tool, map[string]any{"name": "alice"}); err == nil {
		t.Fatal("validateToolArguments() accepted a value that violates pattern")
	}
	if err := validateToolArguments(tool, map[string]any{"name": "Alice", "extra": true}); err == nil {
		t.Fatal("validateToolArguments() accepted an additional property")
	}
}

func TestCompileToolInputSchemaRejectsInvalidOrNonObjectRoot(t *testing.T) {
	tests := []struct {
		name   string
		schema map[string]any
	}{
		{name: "empty", schema: map[string]any{}},
		{name: "array root", schema: map[string]any{"type": "array"}},
		{name: "invalid keyword value", schema: map[string]any{"type": "object", "required": "name"}},
		{name: "external reference", schema: map[string]any{"type": "object", "properties": map[string]any{"value": map[string]any{"$ref": "https://example.invalid/schema.json"}}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := compileToolInputSchema(test.schema); err == nil {
				t.Fatal("compileToolInputSchema() accepted invalid schema")
			}
		})
	}
}

func TestValidateToolArgumentsPreservesNullableCompatibility(t *testing.T) {
	tool := Tool{
		Name: "update_user",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"nickname": map[string]any{"type": "string", "nullable": true},
				"metadata": map[string]any{"nullable": true},
			},
		},
	}
	if err := validateToolArguments(tool, map[string]any{"nickname": nil, "metadata": nil}); err != nil {
		t.Fatalf("validateToolArguments(nullable) error = %v", err)
	}
	if err := validateToolArguments(tool, map[string]any{"nickname": 42}); err == nil {
		t.Fatal("validateToolArguments() accepted a non-null value with the wrong type")
	}
}

func TestValidateToolArgumentsReturnsAgentDockErrorDetails(t *testing.T) {
	tool := Tool{
		Name: "echo",
		InputSchema: map[string]any{
			"type":       "object",
			"required":   []any{"text"},
			"properties": map[string]any{"text": map[string]any{"type": "string"}},
		},
	}
	err := validateToolArguments(tool, nil)
	var mcpErr *Error
	if !errors.As(err, &mcpErr) {
		t.Fatalf("validateToolArguments() error = %T, want *Error", err)
	}
	if mcpErr.Code != "MCP_ARGUMENT_INVALID" || mcpErr.Details["tool"] != "echo" || mcpErr.Details["reason"] == "" {
		t.Fatalf("unexpected MCP error: %#v", mcpErr)
	}
}
