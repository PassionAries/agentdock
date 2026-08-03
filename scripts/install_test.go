package scripts

import (
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

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
		"Start-AgentDockLauncher -LauncherPath $launcherPath",
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
		"$env:AGENTDOCK_OAUTH_ENABLED = 'true'",
		"$env:AGENTDOCK_SERVER_URL = `$serverUrl",
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

	const securityAssemblyLoad = "Add-Type -AssemblyName System.Security"
	if got := strings.Count(script, securityAssemblyLoad); got != 3 {
		t.Fatalf("install.ps1 must load System.Security in the installer and both generated launchers; got %d occurrences", got)
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
		"agentdock.nexus.token.v1",
		"'regenerate-quick'",
		"'save-settings'",
		"'set-startup'",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("manage-windows.ps1 missing %q", want)
		}
	}
	if strings.Contains(script, "RuntimeMode 'quick' -PublicUrl ''") {
		t.Fatal("Quick Tunnel transition must not write an invalid quick manifest without public_url")
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
		"tunnel --no-autoupdate --url $target_url",
		"tunnel --no-autoupdate run",
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
}

func TestLinuxInstallerPreservesCredentialsAndCapturesQuickURL(t *testing.T) {
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
