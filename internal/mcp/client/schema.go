package client

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	jsonschema "github.com/santhosh-tekuri/jsonschema/v6"
	"github.com/santhosh-tekuri/jsonschema/v6/kind"
)

const toolInputSchemaResource = "urn:agentdock:mcp-tool-input-schema"

type toolInputValidator struct {
	schema *jsonschema.Schema
}

type localSchemaLoader struct{}

func (localSchemaLoader) Load(url string) (any, error) {
	return nil, fmt.Errorf("external schema reference is not allowed: %s", url)
}

func compileToolInputSchema(raw map[string]any) (*toolInputValidator, error) {
	if len(raw) == 0 {
		return nil, fmt.Errorf("inputSchema must not be empty")
	}
	if !schemaRootAllowsObject(raw["type"]) {
		return nil, fmt.Errorf("inputSchema root must allow object")
	}

	compiler := jsonschema.NewCompiler()
	compiler.DefaultDraft(jsonschema.Draft2020)
	compiler.UseLoader(localSchemaLoader{})
	if err := compiler.AddResource(toolInputSchemaResource, normalizeNullableSchema(raw)); err != nil {
		return nil, fmt.Errorf("load inputSchema: %w", err)
	}
	compiled, err := compiler.Compile(toolInputSchemaResource)
	if err != nil {
		return nil, fmt.Errorf("compile inputSchema: %w", err)
	}
	return &toolInputValidator{schema: compiled}, nil
}

func validateToolArguments(tool Tool, arguments map[string]any) error {
	if arguments == nil {
		arguments = map[string]any{}
	}
	validator := tool.inputValidator
	if validator == nil {
		compiled, err := compileToolInputSchema(tool.InputSchema)
		if err != nil {
			return newError(
				"MCP_SCHEMA_INVALID",
				"upstream MCP tool returned an invalid input schema",
				false,
				map[string]any{"tool": tool.Name, "reason": err.Error()},
				err,
			)
		}
		validator = compiled
	}

	// 先经过 JSON 编解码，确保校验器看到的数值和复合类型与真正发送给
	// 上游 MCP Server 的 JSON 数据模型一致，而不是 Go 调用方的具体类型。
	raw, err := json.Marshal(arguments)
	if err != nil {
		return newError("MCP_ARGUMENT_INVALID", "encode MCP tool arguments", false, map[string]any{"tool": tool.Name}, err)
	}
	var normalized any
	if err := json.Unmarshal(raw, &normalized); err != nil {
		return newError("MCP_ARGUMENT_INVALID", "decode MCP tool arguments", false, map[string]any{"tool": tool.Name}, err)
	}
	if err := validator.schema.Validate(normalized); err != nil {
		return newError(
			"MCP_ARGUMENT_INVALID",
			"MCP tool arguments do not match the discovered input schema",
			false,
			map[string]any{"tool": tool.Name, "reason": compactSchemaError(err)},
			err,
		)
	}
	return nil
}

func schemaRootAllowsObject(rawType any) bool {
	if rawType == nil {
		return true
	}
	switch typed := rawType.(type) {
	case string:
		return typed == "object"
	case []any:
		for _, item := range typed {
			if item == "object" {
				return true
			}
		}
	case []string:
		for _, item := range typed {
			if item == "object" {
				return true
			}
		}
	}
	return false
}

// nullable 是部分 MCP Server 仍会返回的 OpenAPI 兼容扩展。编译前只在
// 副本中将它转换成标准 JSON Schema 的 null 联合类型，公开 schema 保持原样。
func normalizeNullableSchema(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		normalized := make(map[string]any, len(typed))
		for key, child := range typed {
			normalized[key] = normalizeNullableSchema(child)
		}
		if nullable, _ := typed["nullable"].(bool); nullable {
			if rawType, exists := normalized["type"]; exists {
				normalized["type"] = appendNullType(rawType)
			}
			delete(normalized, "nullable")
		}
		return normalized
	case []any:
		normalized := make([]any, len(typed))
		for i, child := range typed {
			normalized[i] = normalizeNullableSchema(child)
		}
		return normalized
	case []string:
		normalized := make([]any, len(typed))
		for i, child := range typed {
			normalized[i] = child
		}
		return normalized
	default:
		return value
	}
}

func appendNullType(value any) any {
	switch typed := value.(type) {
	case nil:
		// 未声明 type 的 schema 本来就允许 null，不额外收紧。
		return nil
	case string:
		if typed == "null" {
			return typed
		}
		return []any{typed, "null"}
	case []any:
		for _, item := range typed {
			if item == "null" {
				return typed
			}
		}
		return append(typed, "null")
	default:
		return value
	}
}

func compactSchemaError(err error) string {
	var validationErr *jsonschema.ValidationError
	if !errors.As(err, &validationErr) {
		return strings.Join(strings.Fields(err.Error()), " ")
	}
	leaf := firstSchemaErrorLeaf(validationErr)
	path := schemaInstancePath(leaf.InstanceLocation)
	switch failure := leaf.ErrorKind.(type) {
	case *kind.Required:
		if len(failure.Missing) > 0 {
			return path + "." + failure.Missing[0] + " is required"
		}
	case *kind.Type:
		if len(failure.Want) > 0 {
			return path + " must be " + strings.Join(failure.Want, " or ")
		}
	}
	return strings.Join(strings.Fields(leaf.Error()), " ")
}

func firstSchemaErrorLeaf(err *jsonschema.ValidationError) *jsonschema.ValidationError {
	for len(err.Causes) > 0 {
		err = err.Causes[0]
	}
	return err
}

func schemaInstancePath(parts []string) string {
	var path strings.Builder
	path.WriteByte('$')
	for _, part := range parts {
		if _, err := strconv.Atoi(part); err == nil {
			path.WriteByte('[')
			path.WriteString(part)
			path.WriteByte(']')
			continue
		}
		path.WriteByte('.')
		path.WriteString(part)
	}
	return path.String()
}
