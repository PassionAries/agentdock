package mcp

import (
	"context"
	"fmt"
	"strings"
	"sync"

	sdkjsonrpc "github.com/modelcontextprotocol/go-sdk/jsonrpc"
	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
	toolskill "github.com/uvwt/agentdock/internal/tool/skill"
)

const skillsExtensionName = "io.modelcontextprotocol/skills"

type skillsListParams struct {
	mcpsdk.ParamsBase
	Cursor string `json:"cursor,omitempty"`
}

type skillsListResult struct {
	mcpsdk.ResultBase
	Skills     []toolskill.ExportManifest `json:"skills"`
	NextCursor string                     `json:"nextCursor,omitempty"`
}

type skillsGetParams struct {
	mcpsdk.ParamsBase
	URI string `json:"uri"`
}

type skillsGetResult struct {
	mcpsdk.ResultBase
	Skill toolskill.ExportManifest `json:"skill"`
}

type skillCatalog struct {
	manifests     []toolskill.ExportManifest
	manifestByURI map[string]toolskill.ExportManifest
	contentByURI  map[string]toolskill.ExportContent
}

type skillCatalogCache struct {
	mu      sync.RWMutex
	catalog *skillCatalog
}

func (s *Server) registerSkillExtension() {
	if err := mcpsdk.AddReceivingCustomMethod[*skillsListParams, *skillsListResult](
		s.sdk,
		"skills/list",
		func(ctx context.Context, _ *mcpsdk.ServerSession, params *skillsListParams) (*skillsListResult, error) {
			if params != nil && strings.TrimSpace(params.Cursor) != "" {
				return nil, &sdkjsonrpc.Error{Code: sdkjsonrpc.CodeInvalidParams, Message: "skills/list cursor is invalid or expired"}
			}
			catalog, err := s.refreshExportedSkillCatalog(ctx)
			if err != nil {
				return nil, err
			}
			return &skillsListResult{Skills: append([]toolskill.ExportManifest(nil), catalog.manifests...)}, nil
		},
	); err != nil {
		panic(fmt.Sprintf("register skills/list: %v", err))
	}

	if err := mcpsdk.AddReceivingCustomMethod[*skillsGetParams, *skillsGetResult](
		s.sdk,
		"skills/get",
		func(ctx context.Context, _ *mcpsdk.ServerSession, params *skillsGetParams) (*skillsGetResult, error) {
			if params == nil || strings.TrimSpace(params.URI) == "" {
				return nil, &sdkjsonrpc.Error{Code: sdkjsonrpc.CodeInvalidParams, Message: "skills/get uri is required"}
			}
			catalog, err := s.exportedSkillCatalog(ctx)
			if err != nil {
				return nil, err
			}
			manifest, ok := catalog.manifestByURI[params.URI]
			if !ok {
				return nil, &sdkjsonrpc.Error{Code: sdkjsonrpc.CodeInvalidParams, Message: "skills/get uri is not exported by this server"}
			}
			return &skillsGetResult{Skill: manifest}, nil
		},
	); err != nil {
		panic(fmt.Sprintf("register skills/get: %v", err))
	}

	// resources/read 仍走标准 MCP 方法；模板只负责把 skill:// 请求交给本 handler，
	// 真正的授权边界是最近一次 skills/list 快照中的精确 URI 集合。
	s.sdk.AddResourceTemplate(&mcpsdk.ResourceTemplate{
		Name:        "agentdock-exported-skills",
		Title:       "AgentDock exported Skill resources",
		Description: "Resources from the AgentDock Skills extension export catalog.",
		URITemplate: "skill://{skill}/{+path}",
	}, func(ctx context.Context, request *mcpsdk.ReadResourceRequest) (*mcpsdk.ReadResourceResult, error) {
		if request == nil || request.Params == nil || strings.TrimSpace(request.Params.URI) == "" {
			return nil, &sdkjsonrpc.Error{Code: sdkjsonrpc.CodeInvalidParams, Message: "resource uri is required"}
		}
		catalog, err := s.exportedSkillCatalog(ctx)
		if err != nil {
			return nil, err
		}
		content, ok := catalog.contentByURI[request.Params.URI]
		if !ok {
			return nil, mcpsdk.ResourceNotFoundError(request.Params.URI)
		}
		item := &mcpsdk.ResourceContents{URI: content.URI, MIMEType: content.MIMEType}
		if content.IsText {
			item.Text = string(content.Data)
		} else {
			item.Blob = append([]byte(nil), content.Data...)
		}
		return &mcpsdk.ReadResourceResult{Contents: []*mcpsdk.ResourceContents{item}}, nil
	})
}

func (s *Server) exportedSkillCatalog(ctx context.Context) (*skillCatalog, error) {
	s.skillCatalog.mu.RLock()
	catalog := s.skillCatalog.catalog
	s.skillCatalog.mu.RUnlock()
	if catalog != nil {
		return catalog, nil
	}
	return s.refreshExportedSkillCatalog(ctx)
}

// refreshExportedSkillCatalog starts a new exported-Skill scan snapshot. The
// client begins a new import by calling skills/list; skills/get and
// resources/read then use that snapshot until the next skills/list call.
func (s *Server) refreshExportedSkillCatalog(_ context.Context) (*skillCatalog, error) {
	catalog := &skillCatalog{
		manifests:     make([]toolskill.ExportManifest, 0, len(s.cfg.MCPExportedSkills)),
		manifestByURI: make(map[string]toolskill.ExportManifest, len(s.cfg.MCPExportedSkills)),
		contentByURI:  map[string]toolskill.ExportContent{},
	}
	for _, name := range s.cfg.MCPExportedSkills {
		snapshot, err := s.runtime.ExportSkillSnapshot(name)
		if err != nil {
			return nil, fmt.Errorf("export MCP Skill %q: %w", name, err)
		}
		if _, exists := catalog.manifestByURI[snapshot.Manifest.URI]; exists {
			return nil, fmt.Errorf("duplicate exported Skill URI %q", snapshot.Manifest.URI)
		}
		catalog.manifests = append(catalog.manifests, snapshot.Manifest)
		catalog.manifestByURI[snapshot.Manifest.URI] = snapshot.Manifest
		for uri, content := range snapshot.Contents {
			if _, exists := catalog.contentByURI[uri]; exists {
				return nil, fmt.Errorf("duplicate exported Skill resource URI %q", uri)
			}
			catalog.contentByURI[uri] = content
		}
	}

	s.skillCatalog.mu.Lock()
	s.skillCatalog.catalog = catalog
	s.skillCatalog.mu.Unlock()
	return catalog, nil
}
