package mcp

import "strings"

const baseServerInstructions = "For substantial AgentDock, project, deployment, or debugging work, call agentdock_context first. Inspect real state before modifying it. For dynamic MCP, use mcp_tool_search, then mcp_tool_inspect, then mcp_tool_call. Use task_manage for multi-step work and recall_bootstrap when Nexus Recall is available. Never expose secrets."

func serverInstructions(custom string) string {
	custom = strings.TrimSpace(custom)
	if custom == "" {
		return baseServerInstructions
	}
	return baseServerInstructions + "\n\nAdditional operator instructions:\n" + custom
}
