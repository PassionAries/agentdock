package desktopruntime

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
)

// ConfigUpdateRequest 是桌面端保存日常运行设置时使用的结构化请求。
type ConfigUpdateRequest struct {
	RuntimeRoot    string
	Port           int
	LogLevel       string
	NexusEndpoint  string
	NexusTokenFile string
	BrowserEnabled bool
	ACPEnabled     bool
	ACPAgent       string
}

func RunConfigCommand(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return configCommandUsageError()
	}
	switch args[0] {
	case "update":
		flags := flag.NewFlagSet("agentdock config update", flag.ContinueOnError)
		flags.SetOutput(stderr)
		runtimeRoot := flags.String("runtime-root", "", "桌面运行目录")
		port := flags.Int("port", 0, "本地监听端口")
		logLevel := flags.String("log-level", "info", "日志级别")
		nexusEndpoint := flags.String("nexus-endpoint", "", "Nexus endpoint")
		nexusTokenFile := flags.String("nexus-token-file", "", "Nexus Token 临时文件")
		browserEnabled := flags.Bool("browser-enabled", false, "启用浏览器")
		acpEnabled := flags.Bool("acp-enabled", false, "启用 Coding Agent")
		acpAgent := flags.String("acp-agent", "codex", "Coding Agent 预设")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		if flags.NArg() != 0 {
			return configCommandUsageError()
		}
		request := ConfigUpdateRequest{
			RuntimeRoot:    strings.TrimSpace(*runtimeRoot),
			Port:           *port,
			LogLevel:       strings.ToLower(strings.TrimSpace(*logLevel)),
			NexusEndpoint:  strings.TrimSpace(*nexusEndpoint),
			NexusTokenFile: strings.TrimSpace(*nexusTokenFile),
			BrowserEnabled: *browserEnabled,
			ACPEnabled:     *acpEnabled,
			ACPAgent:       strings.ToLower(strings.TrimSpace(*acpAgent)),
		}
		if err := validateConfigUpdate(request); err != nil {
			return err
		}
		if err := platformUpdateConfig(ctx, request); err != nil {
			return err
		}
		_, err := fmt.Fprintln(stdout, `{"updated":true}`)
		return err
	default:
		return configCommandUsageError()
	}
}

func validateConfigUpdate(request ConfigUpdateRequest) error {
	if request.RuntimeRoot == "" {
		return errors.New("runtime-root 不能为空")
	}
	if request.Port < 1 || request.Port > 65535 {
		return errors.New("端口必须是 1 到 65535 之间的整数")
	}
	switch request.LogLevel {
	case "debug", "info", "warn", "error":
	default:
		return fmt.Errorf("不支持的日志级别: %s", request.LogLevel)
	}
	if strings.ContainsAny(request.NexusEndpoint, "\r\n") {
		return errors.New("配置值不能包含换行符")
	}
	if !request.ACPEnabled {
		return nil
	}
	switch request.ACPAgent {
	case "codex", "claude", "grok":
	default:
		return fmt.Errorf("不支持的 Coding Agent: %s", request.ACPAgent)
	}
	return nil
}

func configCommandUsageError() error {
	return errors.New("用法：agentdock config update --runtime-root <目录> --port <端口> --log-level <级别> [高级设置]")
}
