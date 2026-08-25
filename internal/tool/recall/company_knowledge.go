package recall

import (
	"context"
	"net/url"
	pathpkg "path"
	"strings"
)

// CompanyKnowledgeSearch 将 Recall 的内部搜索结果收敛成 OpenAI Company Knowledge
// 约定的标准 search 结果。这里刻意不暴露 Recall 的 score、内部路由和存储细节。
func (svc *Service) CompanyKnowledgeSearch(ctx context.Context, args map[string]any) (Result, error) {
	query := strings.TrimSpace(stringArg(args, "query", ""))
	if query == "" {
		return nil, toolError("MISSING_QUERY", "query is required", "validation")
	}

	searched, err := svc.Search(ctx, map[string]any{"query": query, "kind": "all"})
	if err != nil {
		return nil, err
	}

	results := make([]any, 0)
	for _, raw := range anySlice(searched["results"]) {
		item, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		id, ok := companyKnowledgeRecallID(stringValue(item["path"]))
		if !ok {
			continue
		}
		results = append(results, map[string]any{
			"id":    id,
			"title": recallKnowledgeTitle(item, id),
			"url":   recallKnowledgeURL(svc.config().NexusEndpoint, id),
		})
	}
	return Result{"results": results}, nil
}

// CompanyKnowledgeFetch 接受规范化的公开 Recall path，并继续复用 recall_read 的私密笔记隔离规则。
// Company Knowledge 需要完整来源文本，因此 include_raw=true 后只接受 raw_content，不静默退回摘要字段。
func (svc *Service) CompanyKnowledgeFetch(ctx context.Context, args map[string]any) (Result, error) {
	rawID := strings.TrimSpace(stringArg(args, "id", ""))
	if rawID == "" {
		return nil, toolError("MISSING_ID", "id is required", "validation")
	}
	id, ok := companyKnowledgeRecallID(rawID)
	if !ok {
		cleaned := pathpkg.Clean(strings.TrimPrefix(rawID, "/"))
		if isPrivateRecallPath(cleaned) {
			return nil, toolError("PRIVATE_NOTES_OUT_OF_RECALL_SCOPE", "private-notes is not readable through company knowledge fetch", "validation")
		}
		return nil, toolError("INVALID_COMPANY_KNOWLEDGE_ID", "id must be a canonical public Recall document id returned by search", "validation")
	}

	read, err := svc.Read(ctx, map[string]any{"path": id, "include_raw": true})
	if err != nil {
		return nil, err
	}
	doc, ok := read["recall"].(map[string]any)
	if !ok {
		return nil, toolError("INVALID_RECALL_DOCUMENT", "Recall returned an invalid document", "upstream")
	}
	text, ok := doc["raw_content"].(string)
	if !ok {
		return nil, toolError("RECALL_RAW_CONTENT_UNAVAILABLE", "Recall did not return raw_content for company knowledge fetch", "upstream")
	}

	metadata := map[string]any{"path": id}
	if frontmatter, ok := doc["frontmatter"].(map[string]any); ok && len(frontmatter) > 0 {
		metadata["frontmatter"] = frontmatter
	}
	if size, ok := doc["size_bytes"]; ok {
		metadata["size_bytes"] = size
	}

	return Result{
		"id":       id,
		"title":    recallKnowledgeTitle(doc, id),
		"text":     text,
		"url":      recallKnowledgeURL(svc.config().NexusEndpoint, id),
		"metadata": metadata,
	}, nil
}

func anySlice(value any) []any {
	items, _ := value.([]any)
	return items
}

func firstString(values map[string]any, keys ...string) string {
	for _, key := range keys {
		if value := stringValue(values[key]); strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func stringValue(value any) string {
	text, _ := value.(string)
	return text
}

func recallKnowledgeTitle(values map[string]any, id string) string {
	if title := strings.TrimSpace(firstString(values, "title", "name")); title != "" {
		return title
	}
	if frontmatter, ok := values["frontmatter"].(map[string]any); ok {
		if title := strings.TrimSpace(firstString(frontmatter, "title", "name")); title != "" {
			return title
		}
	}
	name := pathpkg.Base(strings.TrimSpace(id))
	return strings.TrimSuffix(name, pathpkg.Ext(name))
}

func recallKnowledgeURL(endpoint, id string) string {
	parsed, err := url.Parse(strings.TrimSpace(endpoint))
	if err != nil || !parsed.IsAbs() || parsed.Host == "" {
		return ""
	}
	query := parsed.Query()
	query.Set("path", id)
	parsed.RawQuery = query.Encode()
	parsed.Fragment = "recall/library"
	return parsed.String()
}

func isPrivateRecallPath(value string) bool {
	cleaned := strings.TrimLeft(strings.TrimSpace(value), "/")
	return cleaned == "private-notes" || strings.HasPrefix(cleaned, "private-notes/")
}

func companyKnowledgeRecallID(value string) (string, bool) {
	raw := strings.TrimSpace(strings.TrimPrefix(value, "/"))
	if raw == "" {
		return "", false
	}
	cleaned := pathpkg.Clean(raw)
	if cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") || cleaned != raw || isPrivateRecallPath(cleaned) {
		return "", false
	}
	return cleaned, true
}
