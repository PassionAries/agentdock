package desktopruntime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/uvwt/agentdock/internal/desktopcontrol"
)

type controlActionParams struct {
	RuntimeRoot string `json:"runtime_root"`
}

type ControlRuntimeStatus struct {
	NexusConnected bool
}

// DispatchControlRequest 是后台核心的本地控制 API。这里只暴露桌面日常管理能力，
// 安装、卸载和提权仍由系统安装器负责。
func DispatchControlRequest(ctx context.Context, request desktopcontrol.Request, runtimeStatus ControlRuntimeStatus) (any, error) {
	var params controlActionParams
	if len(request.Params) > 0 {
		if err := json.Unmarshal(request.Params, &params); err != nil {
			return nil, errors.New("本地控制参数格式无效")
		}
	}
	if params.RuntimeRoot == "" {
		return nil, errors.New("本地控制参数缺少 runtime_root")
	}
	switch request.Method {
	case "ping":
		return map[string]bool{"ready": true}, nil
	case "service.status":
		status, err := platformServiceStatus(ctx, params.RuntimeRoot)
		if err != nil {
			return nil, err
		}
		status.NexusConnected = runtimeStatus.NexusConnected
		return status, nil
	case "tunnel.status":
		return platformTunnelStatus(ctx, params.RuntimeRoot)
	default:
		return nil, fmt.Errorf("不支持的本地控制方法: %s", request.Method)
	}
}
