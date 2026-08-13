package acp

import (
	"errors"
	"strconv"
	"strings"
)

const (
	claudeAgentACPName = "@agentclientprotocol/claude-agent-acp"
	codexACPName       = "@agentclientprotocol/codex-acp"
)

// requiresHostSteeringFallback identifies released adapters with confirmed
// broken injected-steering semantics. Keep each identity/version gate narrow so
// fixed releases automatically return to the negotiated native behavior.
func requiresHostSteeringFallback(info AgentInfo) bool {
	major, minor, patch, ok := parseReleaseVersion(info.Version)
	if !ok {
		return false
	}
	switch info.Name {
	case claudeAgentACPName:
		return major == 0 && (minor < 64 || (minor == 64 && patch <= 2))
	case codexACPName:
		// codex-acp 1.1.9 reports steering as injected while a streaming final
		// answer can continue unchanged. Use the observable host-owned fallback
		// only for confirmed affected releases; newer versions use native steer.
		return major < 1 || (major == 1 && (minor < 1 || (minor == 1 && patch <= 9)))
	default:
		return false
	}
}

func hostSteeringFallbackReason(info AgentInfo) string {
	if info.Name == claudeAgentACPName {
		return "claude_ede_compatibility"
	}
	if info.Name == codexACPName {
		return "codex_streaming_compatibility"
	}
	return "adapter_steering_compatibility"
}

func isCodexNoRolloutError(info AgentInfo, err error) bool {
	if info.Name != codexACPName || err == nil {
		return false
	}
	major, minor, patch, ok := parseReleaseVersion(info.Version)
	if !ok || major > 1 || (major == 1 && (minor > 1 || (minor == 1 && patch > 9))) {
		return false
	}
	var acpErr *Error
	if !errors.As(err, &acpErr) || acpErr.Code != "ACP_REMOTE_ERROR" {
		return false
	}
	rpcData, _ := acpErr.Details["rpc_data"].(string)
	return strings.Contains(rpcData, "no rollout found for thread id")
}

func parseReleaseVersion(value string) (major, minor, patch int, ok bool) {
	value = strings.TrimSpace(strings.TrimPrefix(value, "v"))
	if suffix := strings.IndexAny(value, "-+"); suffix >= 0 {
		value = value[:suffix]
	}
	parts := strings.Split(value, ".")
	if len(parts) != 3 {
		return 0, 0, 0, false
	}
	values := []*int{&major, &minor, &patch}
	for index, part := range parts {
		parsed, err := strconv.Atoi(part)
		if err != nil || parsed < 0 {
			return 0, 0, 0, false
		}
		*values[index] = parsed
	}
	return major, minor, patch, true
}
