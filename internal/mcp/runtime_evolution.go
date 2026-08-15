package mcp

import (
	"context"

	"github.com/uvwt/agentdock/internal/app"
)

func (s *Server) RuntimeEvolve(ctx context.Context, args map[string]any) (app.Result, error) {
	return s.runtime.RuntimeEvolve(ctx, args)
}
