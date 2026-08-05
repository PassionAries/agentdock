package scripts

import (
	"bytes"
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestCoreSkillBundleNormalizesTextLineEndings(t *testing.T) {
	python := ""
	for _, candidate := range []string{"python3", "python"} {
		path, err := exec.LookPath(candidate)
		if err != nil {
			continue
		}
		if err := exec.Command(path, "--version").Run(); err == nil {
			python = path
			break
		}
	}
	if python == "" {
		t.Skip("Python is required to test the core Skill bundle builder")
	}
	script, err := filepath.Abs("build-core-skill-bundle.py")
	if err != nil {
		t.Fatal(err)
	}

	build := func(lineEnding string) string {
		t.Helper()
		repoRoot := t.TempDir()
		for _, name := range []string{"skill-authoring", "skill-installation", "skill-vetter-runtime"} {
			skillRoot := filepath.Join(repoRoot, "core-skills", name)
			if err := os.MkdirAll(skillRoot, 0o700); err != nil {
				t.Fatal(err)
			}
			document := "---\nname: " + name + "\ndescription: Test Skill.\nversion: 1.0.0\n---\n\n# Test\n"
			document = strings.ReplaceAll(document, "\n", lineEnding)
			if err := os.WriteFile(filepath.Join(skillRoot, "SKILL.md"), []byte(document), 0o600); err != nil {
				t.Fatal(err)
			}
			scriptBody := strings.ReplaceAll("print('test')\n", "\n", lineEnding)
			if err := os.WriteFile(filepath.Join(skillRoot, "run.py"), []byte(scriptBody), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		output := filepath.Join(t.TempDir(), "bundle")
		command := exec.Command(python, script, "--repo-root", repoRoot, "--output", output)
		if data, err := command.CombinedOutput(); err != nil {
			t.Fatalf("build core Skill bundle: %v\n%s", err, data)
		}
		return output
	}

	lfBundle := build("\n")
	crlfBundle := build("\r\n")
	for _, relative := range []string{
		"manifest.json",
		filepath.Join("packages", "skill-authoring.zip"),
		filepath.Join("packages", "skill-installation.zip"),
		filepath.Join("packages", "skill-vetter-runtime.zip"),
	} {
		lfData, err := os.ReadFile(filepath.Join(lfBundle, relative))
		if err != nil {
			t.Fatal(err)
		}
		crlfData, err := os.ReadFile(filepath.Join(crlfBundle, relative))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(lfData, crlfData) {
			t.Fatalf("core Skill bundle differs between LF and CRLF input: %s", relative)
		}
	}
}

func TestUnifiedInstallerEntriesReplaceLegacyNames(t *testing.T) {
	for _, path := range []string{
		"install.sh",
		"install-linux-platform.sh",
		"install-macos-platform.sh",
		"install.ps1",
	} {
		if info, err := os.Stat(path); err != nil {
			t.Fatalf("required installer file %s: %v", path, err)
		} else if !info.Mode().IsRegular() {
			t.Fatalf("required installer path is not a regular file: %s", path)
		}
	}

	for _, legacyPath := range []string{
		"install-linux.sh",
		"install-linux-bootstrap.sh",
		"install-macos.sh",
		"install-windows.ps1",
	} {
		if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
			t.Fatalf("legacy installer entry must not exist: %s", legacyPath)
		}
	}

	data, err := os.ReadFile("install.sh")
	if err != nil {
		t.Fatalf("read install.sh: %v", err)
	}
	entry := string(data)
	for _, want := range []string{
		"install-linux-platform.sh",
		"install-macos-platform.sh",
		"AGENTDOCK_INSTALLER_BASE_URL",
		"verify_checksum",
	} {
		if !strings.Contains(entry, want) {
			t.Fatalf("install.sh missing %q", want)
		}
	}
}

func TestInstallLinuxWritesExplicitNexusDockToken(t *testing.T) {
	data, err := os.ReadFile("install-linux-platform.sh")
	if err != nil {
		t.Fatalf("read install-linux-platform.sh: %v", err)
	}
	script := string(data)
	checks := []string{
		"local nexus_token=\"$7\"",
		"printf 'AGENTDOCK_NEXUS_TOKEN=%s\\n' \"$nexus_token\"",
		"NexusDock API 是否需要 token？",
		"nexus_token=\"$(prompt_secret 'NexusDock token')\"",
	}
	for _, want := range checks {
		if !strings.Contains(script, want) {
			t.Fatalf("install-linux-platform.sh missing NexusDock token handling: %s", want)
		}
	}
	for _, removed := range []string{"AGENTDOCK_NEXUS_DEVICE_NAME", "AGENTDOCK_NEXUS_HEARTBEAT_SECONDS", "Nexus 设备名"} {
		if strings.Contains(script, removed) {
			t.Fatalf("install-linux-platform.sh still contains removed device-agent config %q", removed)
		}
	}
}

func TestDockerSmokeUsesStreamableHTTPAcceptHeader(t *testing.T) {
	data, err := os.ReadFile("smoke-docker.sh")
	if err != nil {
		t.Fatalf("read smoke-docker.sh: %v", err)
	}
	const streamableHTTPAccept = `if path == "/mcp":
        headers["accept"] = "application/json, text/event-stream"`
	const optionalIsError = `envelope.get("isError", False) is False`

	// actions/checkout 在 Windows Runner 上可能把 shell 脚本检出为 CRLF；
	// 同时验证两种换行，测试协议语义而不是平台文本格式。
	lfScript := strings.ReplaceAll(string(data), "\r\n", "\n")
	for _, test := range []struct {
		name   string
		script string
	}{
		{name: "LF", script: lfScript},
		{name: "CRLF", script: strings.ReplaceAll(lfScript, "\n", "\r\n")},
	} {
		t.Run(test.name, func(t *testing.T) {
			script := strings.ReplaceAll(test.script, "\r\n", "\n")
			if !strings.Contains(script, streamableHTTPAccept) {
				t.Fatal("smoke-docker.sh must send the Streamable HTTP Accept header for MCP requests")
			}
			if !strings.Contains(script, optionalIsError) {
				t.Fatal("smoke-docker.sh must treat an omitted MCP isError field as success")
			}
		})
	}
}

func TestInstallWindowsUsesChecksumsDPAPIAndCurrentUserStartup(t *testing.T) {
	data, err := os.ReadFile("install.ps1")
	if err != nil {
		t.Fatalf("read install.ps1: %v", err)
	}
	for index, value := range data {
		if value > 0x7f {
			t.Fatalf("install.ps1 must remain ASCII for Windows PowerShell 5.1; non-ASCII byte at offset %d", index)
		}
	}

	script := string(data)
	for _, line := range strings.Split(script, "\n") {
		trimmed := strings.TrimSpace(line)
		for _, keyword := range []string{"else", "elseif", "catch", "finally"} {
			if trimmed == keyword || strings.HasPrefix(trimmed, keyword+" ") {
				t.Fatalf("install.ps1 must keep %s on the same line as the preceding closing brace: %q", keyword, line)
			}
		}
	}

	for _, want := range []string{
		"agentdock_windows_$architecture.zip",
		"[string] $OfflineArchive = ''",
		"[string] $OfflineChecksumFile = ''",
		"[string] $OfflineCloudflaredBinary = ''",
		"Using bundled AgentDock payload",
		"-SourceBinary $OfflineCloudflaredBinary",
		"agentdock-tray.exe",
		"agentdock.ico",
		"manage-windows.ps1",
		"Initialize-OAuthCredentials",
		"named-server-url.txt",
		"[switch] $ConfigurePublicAccess",
		"[string] $TunnelTokenFile = ''",
		"[switch] $DeleteTunnelTokenFile",
		"Write-RuntimeManifest",
		"Write-InstallResult",
		"runtime.json",
		"New-ItemProperty -Path $runKey -Name $trayRunValueName",
		"cloudflared-windows-$Architecture.exe",
		"Get-FileHash -LiteralPath $archivePath -Algorithm SHA256",
		"Stop-AgentDockForUpgrade -BinaryPath $destinationBinary",
		"Get-ProcessesByPath -ProcessName 'agentdock'",
		"Get-CimInstance Win32_Process",
		"ExecutablePath",
		"Get-AgentDockTaskState",
		"Get-InteractiveDesktopUser",
		"Start-ElevatedAgentDockTaskAction",
		"New-ElevatedAgentDockScheduledTask",
		"New-ScheduledTaskPrincipal",
		"-RunLevel Highest",
		"Set-AgentDockTaskSecurity",
		"prepare-elevated",
		"Restore-AgentDockTaskBackup",
		"setup-elevated-context",
		"Start Setup normally under the signed-in account",
		"Stop-CloudflaredForUpgrade -BinaryPath $cloudflaredBinary",
		"Copy-Item -LiteralPath $destinationBinary -Destination $binaryBackup -Force",
		"Install-AgentDockBinary -SourceBinary $sourceBinary -DestinationBinary $destinationBinary",
		"Write-ProtectedText -Path $tokenPath",
		"Write-ProtectedText -Path $PasswordPath",
		"Write-ProtectedText -Path $TokenSecretPath",
		"Write-ProtectedText -Path $tunnelTokenPath",
		"Copy-Item -LiteralPath $binaryBackup -Destination $destinationBinary -Force",
		"DataProtectionScope]::CurrentUser",
		"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
		"New-ItemProperty -Path $runKey -Name $runValueName",
		"New-ItemProperty -Path $runKey -Name $cloudflaredRunValueName",
		"service launch-core --runtime-root",
		"--start-core --runtime-root",
		"& $destinationBinary service start --runtime-root $runtimeDir",
		"& $destinationBinary tunnel start --runtime-root $runtimeDir",
		"--start-tunnel --runtime-root",
		"$taskArguments = \"service launch-core --runtime-root",
		"New-ScheduledTaskAction -Execute $LauncherPath",
		"-LauncherPath $destinationBinary",
		"[string] $TaskRuntimeRoot = ''",
		"Start-CloudflaredLauncher -LauncherPath $cloudflaredLauncherPath",
		"Wait-QuickTunnelUrl -LogPaths @($cloudflaredStdoutLogPath, $cloudflaredStderrLogPath)",
		"Wait-QuickTunnelReady -Path $quickTunnelUrlPath -ExpectedUrl $publicUrl",
		"quick-tunnel-url.txt",
		"Restart-AgentDockForQuickTunnel",
		"Update-RuntimePublicUrl -PublicUrl `$publicUrl",
		"Write-TextAtomically -Path '$escapedServerUrlPath' -Value `$publicUrl",
		"Write-TextAtomically -Path '$escapedQuickTunnelUrlPath' -Value `$publicUrl",
		"RedirectStandardOutput = '$escapedCloudflaredStdoutLogPath'",
		"RedirectStandardError = '$escapedCloudflaredStderrLogPath'",
		"RuntimeInformation]::OSArchitecture",
		"Authentication: Bearer Token and OAuth are both enabled.",
		"$coreSkillOutput = @(& $destinationBinary skill bootstrap --bundle $coreSkillBundle 2>&1)",
		"-ErrorCode $installErrorCode",
		"http://127.0.0.1:$HealthPort/healthz",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("install.ps1 missing %q", want)
		}
	}
	stopCall := strings.Index(script, "Stop-AgentDockForUpgrade -BinaryPath $destinationBinary")
	replaceCall := strings.Index(script, "Install-AgentDockBinary -SourceBinary $sourceBinary -DestinationBinary $destinationBinary")
	if stopCall < 0 || replaceCall < 0 || stopCall > replaceCall {
		t.Fatal("install.ps1 must stop the running instance before replacing agentdock.exe")
	}
	backupCall := strings.Index(script, "Copy-Item -LiteralPath $destinationBinary -Destination $binaryBackup -Force")
	if backupCall < stopCall || backupCall > replaceCall {
		t.Fatal("install.ps1 must back up the stopped binary before replacement")
	}
	manifestCall := strings.Index(script, "$manifestTunnelMode = $resolvedTunnelMode")
	coreStartCall := strings.Index(script, "& $destinationBinary service start --runtime-root $runtimeDir")
	tunnelStartCall := strings.Index(script, "& $destinationBinary tunnel start --runtime-root $runtimeDir")
	if manifestCall < 0 || coreStartCall < 0 || tunnelStartCall < 0 || manifestCall > coreStartCall || manifestCall > tunnelStartCall {
		t.Fatal("install.ps1 must write the runtime manifest before native core and Tunnel startup")
	}

	const securityAssemblyLoad = "Add-Type -AssemblyName System.Security"
	if got := strings.Count(script, securityAssemblyLoad); got != 2 {
		t.Fatalf("install.ps1 must load System.Security in the installer and generated tunnel launcher; got %d occurrences", got)
	}
	if !strings.Contains(script, "-Verb RunAs") {
		t.Fatal("Windows installer must elevate only the scheduled-task helper")
	}
	if !strings.Contains(script, "DataProtectionScope]::CurrentUser") {
		t.Fatal("Windows secrets must remain bound to the interactive user")
	}
	if strings.Contains(script, "Start-Process -FilePath $destinationBinary -Verb RunAs") {
		t.Fatal("the installer must not launch the core directly under a different administrator account")
	}
	if strings.Contains(script, "current account cannot elevate") {
		t.Fatal("scheduled-task cleanup must request UAC instead of rejecting a standard user before elevation")
	}
	if strings.Contains(script, "--token $TunnelToken") || strings.Contains(script, "--token `$env:TUNNEL_TOKEN") {
		t.Fatal("cloudflared token must be decrypted into its environment, not placed in process arguments")
	}
	for _, forbidden := range []string{
		"Set-PrivateAcl",
		"Get-Acl",
		"Set-Acl",
		"icacls.exe",
		"$icaclsArguments",
		"$AclSelfTest",
		"SetSecurityDescriptorSddlForm(",
	} {
		if strings.Contains(script, forbidden) {
			t.Fatalf("install.ps1 still contains removed privileged startup or ACL code %q", forbidden)
		}
	}
	for _, incompatible := range []string{
		"RandomNumberGenerator]::Fill",
		"Convert]::ToHexString",
		`Replace(\"`,
	} {
		if strings.Contains(script, incompatible) {
			t.Fatalf("install.ps1 contains Windows PowerShell 5.1 incompatible syntax %q", incompatible)
		}
	}
}

func TestWindowsManagerKeepsTunnelTransitionsAndManualTaskStartValid(t *testing.T) {
	data, err := os.ReadFile("manage-windows.ps1")
	if err != nil {
		t.Fatalf("read manage-windows.ps1: %v", err)
	}
	if len(data) < 3 || data[0] != 0xef || data[1] != 0xbb || data[2] != 0xbf {
		t.Fatal("manage-windows.ps1 must use UTF-8 with BOM for Windows PowerShell 5.1")
	}

	script := string(data)
	for _, want := range []string{
		"function Start-TaskPreservingStartupState",
		"Enable-ScheduledTask -TaskName $TaskName",
		"Disable-ScheduledTask -TaskName $TaskName",
		"Update-RuntimeManifest -RuntimePort $settings.port -RuntimeMode 'none' -PublicUrl ''",
		"named-server-url.txt",
		"quick-tunnel-url.txt",
		"'regenerate-quick'",
		"'set-startup'",
		"'start-tunnel'",
		"'stop-tunnel'",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("manage-windows.ps1 missing %q", want)
		}
	}
	if strings.Contains(script, "RuntimeMode 'quick' -PublicUrl ''") {
		t.Fatal("Quick Tunnel transition must not write an invalid quick manifest without public_url")
	}
	for _, want := range []string{
		"& $AgentDockBinary tunnel $Command --runtime-root $RuntimeRoot",
		"'tunnel', 'configure'",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("manage-windows.ps1 must delegate Tunnel operations to native commands: %q", want)
		}
	}
}

func TestWindowsControlPanelUsesNativeTunnelCommands(t *testing.T) {
	appData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "App.xaml.cs"))
	if err != nil {
		t.Fatalf("read App.xaml.cs: %v", err)
	}
	runtimeData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "Services", "RuntimeService.cs"))
	if err != nil {
		t.Fatalf("read RuntimeService.cs: %v", err)
	}
	app := string(appData)
	runtimeService := string(runtimeData)
	for _, want := range []string{
		`"--start-tunnel"`,
		`RunTunnelActionAsync("start",`,
		`RunTunnelStartupAsync()`,
		`RunNativeAgentDockAsync("tunnel"`,
		`allowElevation: false`,
		`"configure"`,
		`"--token-file"`,
		`RunNativeAgentDockAsync("config"`,
		`"--nexus-token-file"`,
	} {
		if !strings.Contains(app, want) && !strings.Contains(runtimeService, want) {
			t.Fatalf("Windows control panel missing native Tunnel behavior %q", want)
		}
	}
	for _, forbidden := range []string{
		`RunManagementScriptAsync(["-Action", "start-tunnel"]`,
		`RunManagementScriptAsync(["-Action", "stop-tunnel"]`,
		`RunManagementScriptAsync(["-Action", "regenerate-quick"]`,
		`powershell.exe`,
		`manage-windows.ps1`,
	} {
		if strings.Contains(runtimeService, forbidden) {
			t.Fatalf("Windows control panel still invokes PowerShell for Tunnel lifecycle %q", forbidden)
		}
	}
}

func TestDesktopRuntimeSurfacesDoNotUseLegacyLaunchers(t *testing.T) {
	trayData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "tray", "app_windows.go"))
	if err != nil {
		t.Fatalf("read Windows tray: %v", err)
	}
	tray := string(trayData)
	for _, want := range []string{
		"runNativeAgentDock",
		"procSetClipboardData",
		"procShellExecuteW",
		`"tunnel", "regenerate"`,
		`"service", "restart"`,
	} {
		if !strings.Contains(tray, want) {
			t.Fatalf("Windows tray missing native runtime behavior %q", want)
		}
	}
	for _, forbidden := range []string{
		"powershell.exe",
		"startPowerShellScript",
		"AgentDockLauncher",
		"CloudflaredLauncher",
	} {
		if strings.Contains(tray, forbidden) {
			t.Fatalf("Windows tray still depends on legacy launcher %q", forbidden)
		}
	}

	selfUpdateData, err := os.ReadFile(filepath.Join("..", "internal", "selfupdate", "service_darwin.go"))
	if err != nil {
		t.Fatalf("read macOS self-update service adapter: %v", err)
	}
	selfUpdate := string(selfUpdateData)
	for _, want := range []string{
		`"ProgramArguments.0": paths.binary`,
		`"ProgramArguments.2": "launch-core"`,
		`"ProgramArguments.4": paths.runtimeRoot`,
	} {
		if !strings.Contains(selfUpdate, want) {
			t.Fatalf("macOS self-update adapter missing native LaunchAgent contract %q", want)
		}
	}
	for _, forbidden := range []string{"start-agentdock.sh", "startScript"} {
		if strings.Contains(selfUpdate, forbidden) {
			t.Fatalf("macOS self-update adapter still depends on legacy launcher %q", forbidden)
		}
	}
}

func TestWindowsUninstallerCleansManagedTunnelState(t *testing.T) {
	data, err := os.ReadFile("uninstall-windows.ps1")
	if err != nil {
		t.Fatalf("read uninstall-windows.ps1: %v", err)
	}
	script := string(data)
	for _, want := range []string{
		"Get-CimInstance Win32_Process",
		"Get-ProcessIdsByPath",
		"Stop-ProcessByPath -ProcessName 'agentdock-tray'",
		"[switch] $KeepInstallDir",
		"Remove-DirectoryWithRetry -Path $InstallDir",
		"Stop-ProcessByPath -ProcessName 'cloudflared'",
		"Remove-ItemProperty -LiteralPath $runKey -Name $TrayStartupValueName",
		"'runtime.json'",
		"Remove-ItemProperty -LiteralPath $runKey -Name $CloudflaredStartupValueName",
		"'start-cloudflared.ps1'",
		"'installer\\manage-windows.ps1'",
		"'named-server-url.txt'",
		"'control-panel-settings.json'",
		"'oauth-password.dpapi'",
		"'oauth-token-secret.dpapi'",
		"'cloudflared-token.dpapi'",
		"'cloudflared.out.log'",
		"'cloudflared.err.log'",
		"'quick-tunnel-url.txt'",
		"$StartupValueName -eq 'AgentDock' -and $CloudflaredStartupValueName -eq 'AgentDockCloudflared' -and $TrayStartupValueName -eq 'AgentDockTray'",
		"Remove-AgentDockScheduledTask",
		"-TaskAdminAction remove",
		"-Verb RunAs",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("uninstall-windows.ps1 missing %q", want)
		}
	}
}

func TestDesktopControlSurfacesCanRefreshQuickTunnel(t *testing.T) {
	checks := map[string][]string{
		filepath.Join("..", "desktop", "windows", "control-panel", "MainWindow.xaml.cs"): {
			"RegenerateQuickButton_Click",
			"RegenerateQuickTunnelAsync",
			"旧地址已隐藏，正在启动新的 Quick Tunnel",
			"PublicMcpTextBox.Text = \"\"",
		},
		filepath.Join("..", "desktop", "macos", "AgentDockApp", "Sources", "SetupWindowController.swift"): {
			"refreshingQuickTunnel",
			"重新生成临时地址",
			"正在生成新的临时公网地址",
		},
	}
	for path, required := range checks {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		content := string(data)
		for _, want := range required {
			if !strings.Contains(content, want) {
				t.Fatalf("%s missing Quick Tunnel refresh behavior %q", path, want)
			}
		}
	}
}

func TestLinuxInstallerIntegratesCloudflareTunnelWithoutLeakingToken(t *testing.T) {
	data, err := os.ReadFile("install-linux-platform.sh")
	if err != nil {
		t.Fatalf("read install-linux-platform.sh: %v", err)
	}
	script := string(data)
	for _, want := range []string{
		"你是否有已接入 Cloudflare 的域名？",
		"AGENTDOCK_CLOUDFLARE_TUNNEL_TOKEN",
		"AGENTDOCK_TUNNEL_MODE=$mode",
		"TUNNEL_TOKEN=$token",
		"EnvironmentFile=$cloudflared_env_file",
		"service launch-core --runtime-root $runtime_root",
		"tunnel launch --runtime-root $runtime_root",
		"write_runtime_manifest",
		`"service_manager": "$service_manager"`,
		"AGENTDOCK_SERVER_URL=%s\\n",
		"AGENTDOCK_OAUTH_ENABLED=%s\\n",
		"AGENTDOCK_OAUTH_PASSWORD=%s\\n",
		"AGENTDOCK_OAUTH_TOKEN_SECRET=%s\\n",
		"Bearer Token、OAuth 均已启用",
		`server_url="$TUNNEL_PUBLIC_URL"`,
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("install-linux-platform.sh missing Cloudflare Tunnel integration %q", want)
		}
	}
	if strings.Contains(script, "--token $token") || strings.Contains(script, "--token \\$TUNNEL_TOKEN") {
		t.Fatal("cloudflared token must be provided through its private environment file, not process arguments")
	}
	for _, legacy := range []string{
		"ExecStart=$cloudflared_binary tunnel",
		`command="$cloudflared_binary"`,
		"ExecStart=$source_dir/bin/agentdock \\",
	} {
		if strings.Contains(script, legacy) {
			t.Fatalf("installer still emits legacy direct runtime command %q", legacy)
		}
	}
}

func TestLinuxInstallerPreservesCredentialsAndCapturesQuickURL(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Linux installer shell behavior is covered by the Alpine native runtime E2E")
	}
	tempDir := t.TempDir()
	envFile := filepath.Join(tempDir, "agentdock.env")
	initial := strings.Join([]string{
		"AGENTDOCK_HOST=127.0.0.9",
		"AGENTDOCK_PORT=19999",
		"AGENTDOCK_AUTH_TOKEN=stable-token",
		"AGENTDOCK_OAUTH_ENABLED=true",
		"AGENTDOCK_OAUTH_PASSWORD=stable-oauth-password",
		"AGENTDOCK_OAUTH_TOKEN_SECRET=stable-oauth-secret-0123456789abcdef",
		"AGENTDOCK_BROWSER_ENABLED=true",
		"",
	}, "\n")
	if err := os.WriteFile(envFile, []byte(initial), 0o600); err != nil {
		t.Fatal(err)
	}

	script := `
set -Eeuo pipefail
source ./install-linux-platform.sh
run_root() {
  if [[ "$1" == systemctl ]]; then
    return 0
  fi
  if [[ "$1" == install ]]; then
    shift
    local args=()
    while (( $# > 0 )); do
      case "$1" in
        -o|-g) shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    command install "${args[@]}"
    return
  fi
  "$@"
}
write_env_file "$TEST_ENV_FILE" 127.0.0.1 8765 stable-token info "" "" \
  https://new.trycloudflare.com yes true stable-oauth-password stable-oauth-secret-0123456789abcdef
cloudflared_service_active() { return 0; }
cloudflared_quick_url() { printf 'https://new.trycloudflare.com'; }
start_cloudflared_service systemd agentdock-cloudflared quick ""
printf '\nCAPTURED=%s\n' "$TUNNEL_PUBLIC_URL"
`
	cmd := exec.Command("bash", "-c", script)
	cmd.Dir = "."
	cmd.Env = append(os.Environ(), "TEST_ENV_FILE="+envFile)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("run installer functions: %v\n%s", err, output)
	}
	got, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	text := string(got)
	for _, want := range []string{
		"AGENTDOCK_BROWSER_ENABLED=true",
		"AGENTDOCK_AUTH_TOKEN=stable-token",
		"AGENTDOCK_OAUTH_ENABLED=true",
		"AGENTDOCK_OAUTH_PASSWORD=stable-oauth-password",
		"AGENTDOCK_OAUTH_TOKEN_SECRET=stable-oauth-secret-0123456789abcdef",
		"AGENTDOCK_SERVER_URL=https://new.trycloudflare.com",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("rewritten env missing %q:\n%s", want, text)
		}
	}
	if !strings.Contains(string(output), "CAPTURED=https://new.trycloudflare.com") {
		t.Fatalf("quick URL was not captured: %s", output)
	}
}

func TestCloudflareComposeKeepsTunnelTokenOutOfAgentDock(t *testing.T) {
	data, err := os.ReadFile("../docker-compose.cloudflare-tunnel.yml")
	if err != nil {
		t.Fatalf("read docker-compose.cloudflare-tunnel.yml: %v", err)
	}
	compose := string(data)
	for _, want := range []string{
		`profiles: ["cloudflare-quick"]`,
		`profiles: ["cloudflare-named"]`,
		`http://agentdock:8765`,
		`TUNNEL_TOKEN: "${TUNNEL_TOKEN:?set TUNNEL_TOKEN for the named tunnel}"`,
	} {
		if !strings.Contains(compose, want) {
			t.Fatalf("Cloudflare compose overlay missing %q", want)
		}
	}
	baseData, err := os.ReadFile("../docker-compose.yml")
	if err != nil {
		t.Fatalf("read docker-compose.yml: %v", err)
	}
	if strings.Contains(string(baseData), "TUNNEL_TOKEN") {
		t.Fatal("base AgentDock service must not receive TUNNEL_TOKEN")
	}
}

func TestWindowsSetupKeepsPublicAccessExplicitAndSecretsOffCommandLine(t *testing.T) {
	var setupBuilder strings.Builder
	for _, path := range []string{
		filepath.Join("..", "packaging", "windows", "AgentDock.iss"),
		filepath.Join("..", "packaging", "windows", "includes", "messages.iss"),
		filepath.Join("..", "packaging", "windows", "includes", "code.iss"),
	} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read Windows Setup source %s: %v", path, err)
		}
		setupBuilder.Write(data)
		setupBuilder.WriteByte('\n')
	}
	setup := setupBuilder.String()
	for _, want := range []string{
		"PrivilegesRequired=lowest",
		"#include \"includes\\messages.iss\"",
		"#include \"includes\\code.iss\"",
		"DisableDirPage=yes",
		"LanguageDetectionMethod=uilanguage",
		"AgentDock active language: ",
		"Name: \"chinesesimplified\"",
		"DetectExistingInstallation",
		"ExistingInstallSource := 'setup'",
		"ExistingInstallSource := 'powershell'",
		"LoadExistingSettings",
		"LegacyAgentDockScheduledTaskExists",
		"/Query /TN \"\\AgentDock\"",
		"AgentDock legacy scheduled task detected.",
		"cloudflared-token.dpapi",
		"-TunnelMode ",
		"-TunnelTokenFile ",
		"-DeleteTunnelTokenFile",
		"-InstallChannel setup",
		"-CorePrivilegeMode ",
		"ElevatedCoreOption",
		"UpgradeKeepSettings",
		"UpgradeChangeSettings",
		"RuntimeUsesElevatedCore",
		"ElevatedSetupUnsupported",
		"GetIniString('AgentDock', 'Code'",
		"#ifdef SignedBuild",
		"SignedUninstaller=yes",
		"DeinitializeSetup",
		"function InitializeUninstall(): Boolean",
		"procedure CurUninstallStepChanged",
		"usAppMutexCheck",
		"managed cleanup completed successfully",
		"GetUninstallParameters('')",
		"[UninstallDelete]",
		"-KeepInstallDir",
		"PurgeStateQuestion",
		"Bearer Token：",
		"AgentDockSetup-amd64",
		"AgentDockSetup-arm64",
		"agentdock_windows_{#PayloadArchitecture}.zip",
		"Source: \"{#OfflinePayloadDir}\\cloudflared.exe\"",
		"-OfflineArchive ",
		"-OfflineChecksumFile ",
		"-OfflineCloudflaredBinary ",
		"CreateOutputProgressPage",
		"OfflineProgressDescription",
		"FinishedControlPanel",
		"DesktopShortcutCheckBox",
		"DesktopShortcutCheckBox.Checked := True",
		"ApplyDesktopControlPanelShortcut",
		"CreatedShortcutPath := CreateShellLink",
		"Result := CreatedShortcutPath <> ''",
		"DesktopShortcutCheckBox.Left := WizardForm.FinishedLabel.Left",
		"{userdesktop}\\{code:GetLocalizedMessage|DesktopShortcutName}.lnk",
		"if CurPageID = wpFinished then",
		"{app}\\bin\\agentdock-tray.exe",
	} {
		if !strings.Contains(setup, want) {
			t.Fatalf("AgentDock.iss missing %q", want)
		}
	}
	if strings.Contains(setup, " -TunnelToken ") {
		t.Fatal("Setup must pass the Cloudflare Tunnel Token through a temporary file, not process arguments")
	}
	for _, forbidden := range []string{
		"ResultMemo",
		"CopyLocalButton",
		"GetIniString('AgentDock', 'BearerToken'",
		"GetIniString('AgentDock', 'OAuthPassword'",
		"完成后会自动打开控制面板",
	} {
		if strings.Contains(setup, forbidden) {
			t.Fatalf("Setup completion page must not expose connection details or credentials: %q", forbidden)
		}
	}
	for _, forbidden := range []string{
		"(recommended)",
		"（推荐）",
		"The tray stays a normal user process",
		"托盘始终使用普通用户权限",
	} {
		if strings.Contains(setup, forbidden) {
			t.Fatalf("Setup must not show recommendation or privilege implementation details: %q", forbidden)
		}
	}
}

func TestDesktopAppIconAssets(t *testing.T) {
	pngData, err := os.ReadFile(filepath.Join("..", "packaging", "assets", "agentdock.png"))
	if err != nil {
		t.Fatalf("read shared AgentDock PNG: %v", err)
	}
	if len(pngData) < 24 || string(pngData[:8]) != "\x89PNG\r\n\x1a\n" {
		t.Fatal("shared AgentDock icon must be a valid PNG")
	}
	if width, height := binary.BigEndian.Uint32(pngData[16:20]), binary.BigEndian.Uint32(pngData[20:24]); width != 1024 || height != 1024 {
		t.Fatalf("shared AgentDock icon must be 1024x1024, got %dx%d", width, height)
	}

	icoData, err := os.ReadFile(filepath.Join("..", "packaging", "windows", "assets", "agentdock.ico"))
	if err != nil {
		t.Fatalf("read Windows AgentDock ICO: %v", err)
	}
	if len(icoData) < 6 || binary.LittleEndian.Uint16(icoData[2:4]) != 1 {
		t.Fatal("Windows AgentDock icon must be a valid ICO")
	}
	if count := binary.LittleEndian.Uint16(icoData[4:6]); count < 9 {
		t.Fatalf("Windows AgentDock icon must include multiple sizes, got %d entries", count)
	}
}

func TestWindowsControlPanelUsesStableAppUserModelID(t *testing.T) {
	appData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "App.xaml.cs"))
	if err != nil {
		t.Fatalf("read App.xaml.cs: %v", err)
	}
	app := string(appData)
	for _, want := range []string{
		"com.uvwt.agentdock.controlpanel",
		"SetCurrentProcessExplicitAppUserModelID",
		"_ = SetCurrentProcessExplicitAppUserModelID(AppUserModelId)",
	} {
		if !strings.Contains(app, want) {
			t.Fatalf("App.xaml.cs missing stable taskbar identity %q", want)
		}
	}

	setupData, err := os.ReadFile(filepath.Join("..", "packaging", "windows", "AgentDock.iss"))
	if err != nil {
		t.Fatalf("read AgentDock.iss: %v", err)
	}
	if !strings.Contains(string(setupData), "AppUserModelID: \"com.uvwt.agentdock.controlpanel\"") {
		t.Fatal("Start menu shortcut must use the same stable AppUserModelID as the control panel process")
	}
}

func TestWindowsControlPanelOmitsCopyButtons(t *testing.T) {
	xamlData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "MainWindow.xaml"))
	if err != nil {
		t.Fatalf("read MainWindow.xaml: %v", err)
	}
	codeData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "MainWindow.xaml.cs"))
	if err != nil {
		t.Fatalf("read MainWindow.xaml.cs: %v", err)
	}

	xaml := string(xamlData)
	code := string(codeData)
	for _, forbidden := range []string{
		`Content="复制"`,
		"CopyLocalMcpButton_Click",
		"CopyPublicMcpButton_Click",
		"CopyBearerButton_Click",
		"CopyOAuthButton_Click",
	} {
		if strings.Contains(xaml, forbidden) || strings.Contains(code, forbidden) {
			t.Fatalf("Windows control panel must not expose copy-button behavior %q", forbidden)
		}
	}
}

func TestDesktopTrayMenusUseNativeDismissalAndOmitCopyActions(t *testing.T) {
	windowsData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "App.xaml.cs"))
	if err != nil {
		t.Fatalf("read App.xaml.cs: %v", err)
	}
	macData, err := os.ReadFile(filepath.Join("..", "desktop", "macos", "AgentDockApp", "Sources", "AppDelegate.swift"))
	if err != nil {
		t.Fatalf("read AppDelegate.swift: %v", err)
	}
	windowsApp := string(windowsData)
	macApp := string(macData)

	orderedItems := []string{
		`AgentDock：{statusText}`,
		`"打开 AgentDock"`,
		`"停止 AgentDock"`,
		`"重启 AgentDock"`,
		`"启动 AgentDock"`,
		`"检查更新…"`,
		`"打开日志目录"`,
		`"打开配置目录"`,
		`"打开使用文档"`,
		`"退出菜单栏"`,
	}
	lastIndex := -1
	for _, item := range orderedItems {
		index := strings.Index(windowsApp, item)
		if index < 0 {
			t.Fatalf("Windows tray menu missing macOS-aligned item %q", item)
		}
		if index <= lastIndex {
			t.Fatalf("Windows tray menu item %q is out of order", item)
		}
		lastIndex = index
	}

	for _, want := range []string{
		"ContextMenuStrip = _trayMenu",
		"PopulateTrayMenu(_trayMenu, null)",
		"DispatcherTimer",
		"PopulateTrayMenu",
		"RefreshTraySnapshotAsync",
		"!_trayMenu.Visible",
		"Runtime.GetSnapshotAsync()",
		"snapshot.CoreRunning",
		"https://github.com/uvwt/agentdock#readme",
	} {
		if !strings.Contains(windowsApp, want) {
			t.Fatalf("Windows tray menu missing native live behavior %q", want)
		}
	}

	for _, want := range []string{
		`"打开 AgentDock"`,
		`"停止 AgentDock"`,
		`"重启 AgentDock"`,
		`"启动 AgentDock"`,
		`"检查更新…"`,
		`"打开日志目录"`,
		`"打开配置目录"`,
		`"打开使用文档"`,
		`"退出菜单栏"`,
	} {
		if !strings.Contains(macApp, want) {
			t.Fatalf("macOS tray menu missing item %q", want)
		}
	}

	for _, forbidden := range []string{
		`"复制本地 MCP 地址"`,
		`"复制公网 MCP 地址"`,
		"copyLocalMCP",
		"copyPublicMCP",
		"Forms.Clipboard.SetText",
		"NSPasteboard.general",
	} {
		if strings.Contains(windowsApp, forbidden) || strings.Contains(macApp, forbidden) {
			t.Fatalf("desktop tray menus must not expose copy-address behavior %q", forbidden)
		}
	}

	for _, forbidden := range []string{"NotifyIcon_MouseUp", "_trayMenu.Show("} {
		if strings.Contains(windowsApp, forbidden) {
			t.Fatalf("Windows tray menu must use native NotifyIcon dismissal instead of manual popup behavior %q", forbidden)
		}
	}
}

func TestWindowsUpdateFeedbackUsesUTF8AndImmediateStatus(t *testing.T) {
	appData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "App.xaml.cs"))
	if err != nil {
		t.Fatalf("read App.xaml.cs: %v", err)
	}
	windowData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "MainWindow.xaml.cs"))
	if err != nil {
		t.Fatalf("read MainWindow.xaml.cs: %v", err)
	}
	xamlData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "MainWindow.xaml"))
	if err != nil {
		t.Fatalf("read MainWindow.xaml: %v", err)
	}
	runtimeData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "Services", "RuntimeService.cs"))
	if err != nil {
		t.Fatalf("read RuntimeService.cs: %v", err)
	}
	progressXAMLData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "UpdateProgressWindow.xaml"))
	if err != nil {
		t.Fatalf("read UpdateProgressWindow.xaml: %v", err)
	}
	progressCodeData, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "UpdateProgressWindow.xaml.cs"))
	if err != nil {
		t.Fatalf("read UpdateProgressWindow.xaml.cs: %v", err)
	}
	scriptData, err := os.ReadFile(filepath.Join("manage-windows.ps1"))
	if err != nil {
		t.Fatalf("read manage-windows.ps1: %v", err)
	}

	app := string(appData)
	window := string(windowData)
	xaml := string(xamlData)
	runtimeService := string(runtimeData)
	progressXAML := string(progressXAMLData)
	progressCode := string(progressCodeData)
	script := string(scriptData)

	for _, want := range []string{
		`_updateInProgress ? "正在检查更新…" : "检查更新…"`,
		`ControlPanelWindow.SetUpdateState(true, "正在检查更新，请稍候…")`,
		`var check = await Runtime.CheckForUpdatesAsync()`,
		`if (!check.UpdateAvailable)`,
		`MessageBoxButton.YesNo`,
		`new UpdateProgressWindow(check.CurrentVersion, check.LatestVersion)`,
		`var output = await Runtime.RunUpdateAsync(progress)`,
	} {
		if !strings.Contains(app, want) {
			t.Fatalf("Windows tray update flow missing %q", want)
		}
	}

	for _, want := range []string{
		`x:Name="UpdateButton"`,
		`await ((App)Application.Current).CheckForUpdatesAsync(this)`,
		`public void SetUpdateState`,
		`public void SetUpdateStatus`,
	} {
		if !strings.Contains(xaml, want) && !strings.Contains(window, want) {
			t.Fatalf("Windows control-panel update flow missing %q", want)
		}
	}

	for _, want := range []string{
		`public async Task<UpdateCheckResult> CheckForUpdatesAsync`,
		`startInfo.ArgumentList.Add("--check")`,
		`JsonSerializer.Deserialize<UpdateCheckResult>`,
		`IProgress<UpdateProgress>? progress`,
		`ReadProcessLinesAsync`,
		`MapUpdateProgress`,
		`StandardOutputEncoding = utf8`,
		`StandardErrorEncoding = utf8`,
	} {
		if !strings.Contains(runtimeService, want) {
			t.Fatalf("Windows update process handling missing %q", want)
		}
	}

	for _, want := range []string{
		`x:Class="AgentDock.ControlPanel.UpdateProgressWindow"`,
		`<ProgressBar x:Name="UpdateProgressBar"`,
		`IsEnabled="False"`,
		`if (!_canClose)`,
		`UpdateProgressBar.Value = Math.Max`,
		`public void Complete(string message)`,
		`public void Fail(string message)`,
	} {
		if !strings.Contains(progressXAML, want) && !strings.Contains(progressCode, want) {
			t.Fatalf("Windows update progress window missing %q", want)
		}
	}

	for _, want := range []string{
		`[Console]::InputEncoding = $Utf8NoBom`,
		`[Console]::OutputEncoding = $Utf8NoBom`,
		`$global:OutputEncoding = $Utf8NoBom`,
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("Windows management script missing UTF-8 output setup %q", want)
		}
	}

	for _, forbidden := range []string{
		`RunTrayActionAsync("update")`,
		`RunCoreActionAsync("update"`,
		`var output = await Runtime.RunUpdateAsync();`,
		`var output = await _runtime.RunUpdateAsync();`,
	} {
		if strings.Contains(app, forbidden) || strings.Contains(window, forbidden) {
			t.Fatalf("Windows update UI must not bypass check-and-confirm flow %q", forbidden)
		}
	}
}

func TestWindowsControlPanelKeepsExistingBackgroundAndStylesOnlyButtonsAndTabs(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "App.xaml"))
	if err != nil {
		t.Fatalf("read App.xaml: %v", err)
	}
	app := string(data)

	for _, want := range []string{
		`x:Key="SurfaceBrush" Color="#F5F7FA"`,
		`x:Key="BorderBrush" Color="#D8DEE8"`,
		`<Style TargetType="Button">`,
		`<Style TargetType="TabControl">`,
		`<Style TargetType="TabItem">`,
		`x:Name="PART_SelectedContentHost"`,
		`Background="White"`,
	} {
		if !strings.Contains(app, want) {
			t.Fatalf("App.xaml missing restrained Windows style %q", want)
		}
	}

	for _, forbidden := range []string{
		`x:Key="PanelBrush"`,
		`x:Key="ContentBrush"`,
		`<Style TargetType="ComboBox">`,
	} {
		if strings.Contains(app, forbidden) {
			t.Fatalf("button/tab styling must not change the existing window background or unrelated controls: %q", forbidden)
		}
	}
}
func TestWindowsControlPanelResolvesRuntimeRootFromExecutableDirectory(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "desktop", "windows", "control-panel", "Services", "RuntimeService.cs"))
	if err != nil {
		t.Fatalf("read RuntimeService.cs: %v", err)
	}
	service := string(data)
	for _, want := range []string{
		"new DirectoryInfo(AppContext.BaseDirectory)",
		"executableDirectory.Parent?.FullName",
		"string.Equals(executableDirectory.Name, \"bin\"",
	} {
		if !strings.Contains(service, want) {
			t.Fatalf("RuntimeService.cs missing installed runtime root behavior %q", want)
		}
	}
	if strings.Contains(service, "Directory.GetParent(baseDirectory)?.FullName") {
		t.Fatal("RuntimeService must not resolve the parent from a trailing AppContext.BaseDirectory string")
	}
}

func TestWindowsSetupIncludesSimplifiedChineseBaseMessages(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "packaging", "windows", "languages", "ChineseSimplified.isl"))
	if err != nil {
		t.Fatalf("read ChineseSimplified.isl: %v", err)
	}
	language := string(data)
	for _, want := range []string{
		"LanguageID=$0804",
		"ButtonNext=下一步",
		"ButtonCancel=取消",
		"WelcomeLabel1=欢迎使用",
		"FinishedHeadingLabel=[name] 安装完成",
		"ConfirmUninstall=确实要完全删除",
	} {
		if !strings.Contains(language, want) {
			t.Fatalf("ChineseSimplified.isl missing %q", want)
		}
	}
}

func TestWindowsSigningPinsConfiguredSelfSignedCertificate(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("sign-windows.ps1"))
	if err != nil {
		t.Fatalf("read sign-windows.ps1: %v", err)
	}
	script := string(data)
	for _, want := range []string{
		"SignerCertificate.Thumbprint -ne $expectedCertificate.Thumbprint",
		"Test-IsExpectedSelfSignedTrustFailure",
		"@('UnknownError', 'NotTrusted')",
		"certificate chain processed",
		"$signature.Status -eq 'Valid'",
		"signtool verify failed",
		"X509KeyStorageFlags]::EphemeralKeySet",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("sign-windows.ps1 missing self-signed verification requirement %q", want)
		}
	}
	for _, forbidden := range []string{"StoreLocation]::CurrentUser", "TrustedPublisher", "TrustedPeople"} {
		if strings.Contains(script, forbidden) {
			t.Fatalf("sign-windows.ps1 must not modify Windows trust stores: %q", forbidden)
		}
	}
}

func TestWindowsInstallerExercisesConfiguredAuthenticodeCertificate(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", ".github", "workflows", "windows-installer.yml"))
	if err != nil {
		t.Fatalf("read Windows installer workflow: %v", err)
	}
	workflow := string(data)
	for _, want := range []string{
		"Test configured Authenticode certificate",
		"Prepare offline AMD64 payload",
		"build-windows-offline-setup.ps1",
		"AgentDockSetup-amd64.exe",
		"AgentDockSetup-arm64.exe",
		"WINDOWS_SIGNING_CERT_BASE64",
		"WINDOWS_SIGNING_CERT_PASSWORD",
		"sign-windows.ps1 -Path $paths",
		"sign-windows.ps1 -Path $paths -VerifyOnly",
		"dotnet publish .\\desktop\\windows\\control-panel\\AgentDock.ControlPanel.csproj",
		"manage-windows.ps1",
		"-AllowLegacyTaskMutation",
	} {
		if !strings.Contains(workflow, want) {
			t.Fatalf("windows-installer.yml missing Authenticode integration check %q", want)
		}
	}
}

func TestMacOSReleaseChecksCloudflaredFromPayloadDirectory(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", ".github", "workflows", "release.yml"))
	if err != nil {
		t.Fatalf("read release workflow: %v", err)
	}
	workflow := string(data)
	for _, want := range []string{
		"cd payload",
		`shasum -a 256 "cloudflared_darwin_$architecture" > "cloudflared_darwin_$architecture.sha256"`,
		"shasum -a 256 -c cloudflared_darwin_amd64.sha256",
		"shasum -a 256 -c cloudflared_darwin_arm64.sha256",
		"AgentDock.app/Contents/Library/LoginItems/AgentDockLoginHelper.app/Contents/MacOS/AgentDockLoginHelper",
	} {
		if !strings.Contains(workflow, want) {
			t.Fatalf("release.yml missing macOS cloudflared checksum behavior %q", want)
		}
	}
	if strings.Contains(workflow, `shasum -a 256 "$output" > "$output.sha256"`) {
		t.Fatal("macOS cloudflared checksum must not record the payload directory before validation inside payload")
	}
	if strings.Contains(workflow, "AgentDock.app/Contents/MacOS/AgentDockLoginHelper") {
		t.Fatal("release verification must resolve the login helper inside its nested app bundle")
	}
}

func TestMacOSReleasePublishesDesktopUpdateArchive(t *testing.T) {
	workflowData, err := os.ReadFile(filepath.Join("..", ".github", "workflows", "release.yml"))
	if err != nil {
		t.Fatalf("read release workflow: %v", err)
	}
	buildData, err := os.ReadFile(filepath.Join("..", "packaging", "macos", "build-app.sh"))
	if err != nil {
		t.Fatalf("read macOS App build script: %v", err)
	}
	workflow := string(workflowData)
	build := string(buildData)
	for _, want := range []string{
		"dist/macos-app/AgentDock-macos-universal.zip",
		"dist/macos-app/AgentDock-macos-universal.zip.sha256",
		"shasum -a 256 -c AgentDock-macos-universal.zip.sha256",
		`curl -fL "$release_base/AgentDock-macos-universal.zip" -o "$zip"`,
		`codesign --verify --deep --strict --verbose=2 "$zip_dir/AgentDock.app"`,
	} {
		if !strings.Contains(workflow, want) {
			t.Fatalf("release.yml missing macOS desktop update asset behavior %q", want)
		}
	}
	for _, want := range []string{
		`ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"`,
		`unzip -tq "$ZIP_PATH"`,
		`shasum -a 256 "${ZIP_PATH:t}" > "${ZIP_PATH:t}.sha256"`,
	} {
		if !strings.Contains(build, want) {
			t.Fatalf("build-app.sh missing macOS desktop update archive behavior %q", want)
		}
	}
}

func TestReleaseWorkflowChecksOutRequestedTag(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", ".github", "workflows", "release.yml"))
	if err != nil {
		t.Fatalf("read release workflow: %v", err)
	}
	workflow := string(data)
	checkoutCount := strings.Count(workflow, "uses: actions/checkout@v4")
	requestedRefCount := strings.Count(workflow, "ref: ${{ github.event.inputs.tag || github.ref }}")
	if checkoutCount == 0 || requestedRefCount != checkoutCount {
		t.Fatalf("every release checkout must use the requested tag: checkouts=%d refs=%d", checkoutCount, requestedRefCount)
	}
	for _, want := range []string{
		`source_commit="$(git rev-parse HEAD)"`,
		`internal/buildinfo.Commit=${source_commit}`,
		`$sourceCommit = (git rev-parse HEAD).Trim()`,
		`internal/buildinfo.Commit=$sourceCommit`,
		`echo "commit=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"`,
		`BUILD_COMMIT=${{ steps.build.outputs.commit }}`,
		`cache-to: type=gha,mode=max,scope=${{ matrix.variant }},ignore-error=true`,
	} {
		if !strings.Contains(workflow, want) {
			t.Fatalf("release.yml missing checked-out source commit behavior %q", want)
		}
	}
	if strings.Contains(workflow, "internal/buildinfo.Commit=${GITHUB_SHA}") ||
		strings.Contains(workflow, "internal/buildinfo.Commit=$env:GITHUB_SHA") ||
		strings.Contains(workflow, "BUILD_COMMIT=${{ github.sha }}") {
		t.Fatal("release build metadata must describe the checked-out tag, not the workflow dispatch commit")
	}
}

func TestWindowsReleaseRequiresSignedCoreTrayAndSetup(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", ".github", "workflows", "release.yml"))
	if err != nil {
		t.Fatalf("read release workflow: %v", err)
	}
	workflow := string(data)
	for _, want := range []string{
		"WINDOWS_SIGNING_CERT_BASE64 is required for a formal release",
		"dotnet publish .\\desktop\\windows\\control-panel\\AgentDock.ControlPanel.csproj",
		"dist\\manage-windows.ps1",
		"scripts\\sign-windows.ps1",
		"build-windows-setup:",
		"AgentDockSetup-amd64.exe",
		"AgentDockSetup-arm64.exe",
		"build-windows-offline-setup.ps1",
		"cloudflared-windows-amd64.exe",
		"payload\\cloudflared.exe",
		"dist/*.exe.sha256",
		"-VerifyOnly",
	} {
		if !strings.Contains(workflow, want) {
			t.Fatalf("release.yml missing signed Windows release requirement %q", want)
		}
	}
	if strings.Contains(workflow, "if: steps.signing.outputs.enabled == 'true'") {
		t.Fatal("formal Windows release must not silently skip Authenticode signing")
	}
}
