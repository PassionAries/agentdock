[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'start',
        'stop',
        'restart',
        'start-tunnel',
        'stop-tunnel',
        'update',
        'set-mode',
        'regenerate-quick',
        'save-settings',
        'set-startup',
        'launch-core',
        'launch-tunnel',
        'set-task-startup',
        'task-start',
        'task-stop'
    )]
    [string] $Action,
    [string] $RuntimeRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AgentDock'),
    [ValidateSet('none', 'quick', 'named')]
    [string] $Mode = 'none',
    [string] $ServerUrl = '',
    [string] $TunnelTokenFile = '',
    [int] $Port = 0,
    [ValidateSet('debug', 'info', 'warn', 'error')]
    [string] $LogLevel = 'info',
    [string] $NexusEndpoint = '',
    [string] $NexusTokenFile = '',
    [ValidateSet('true', 'false')]
    [string] $BrowserEnabled = 'false',
    [string] $BrowserRunnerDir = '',
    [string] $BrowserNodePath = '',
    [ValidateSet('core', 'tray')]
    [string] $Component = 'core',
    [ValidateSet('true', 'false')]
    [string] $Enabled = 'false'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$global:OutputEncoding = $Utf8NoBom
Add-Type -AssemblyName System.Security

function Convert-ToBoolean {
    param(
        [object] $Value,
        [bool] $Default = $false
    )

    if ($Value -is [bool]) {
        return [bool] $Value
    }
    if ($null -eq $Value) {
        return $Default
    }
    switch ([string] $Value) {
        'true' { return $true }
        'false' { return $false }
        default { return $Default }
    }
}

function Get-ObjectProperty {
    param(
        [object] $Object,
        [string] $Name,
        [object] $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Set-ObjectProperty {
    param(
        [object] $Object,
        [string] $Name,
        [object] $Value
    )

    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
        return
    }
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
}

function Read-JsonFile {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{}
    }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "无法读取 JSON 文件 $Path：$($_.Exception.Message)"
    }
}

function Write-TextAtomically {
    param(
        [string] $Path,
        [string] $Value
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporaryPath = "$Path.tmp.$PID"
    [IO.File]::WriteAllText($temporaryPath, $Value, $Utf8NoBom)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Write-JsonAtomically {
    param(
        [string] $Path,
        [object] $Value
    )

    Write-TextAtomically -Path $Path -Value ($Value | ConvertTo-Json -Depth 8)
}

function Read-TextFile {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    try {
        return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).Trim()
    } catch {
        return ''
    }
}

function Write-ProtectedText {
    param(
        [string] $Path,
        [string] $Value,
        [string] $Entropy
    )

    $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($Value),
        [Text.Encoding]::UTF8.GetBytes($Entropy),
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    Write-TextAtomically -Path $Path -Value ([Convert]::ToBase64String($protectedBytes))
}

function Read-ProtectedText {
    param(
        [string] $Path,
        [string] $Entropy
    )

    $encoded = Read-TextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($encoded)) {
        return ''
    }
    try {
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            [Convert]::FromBase64String($encoded),
            [Text.Encoding]::UTF8.GetBytes($Entropy),
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Text.Encoding]::UTF8.GetString($plainBytes)
    } catch {
        throw "无法读取当前 Windows 用户保存的凭据：$Path"
    }
}

function New-RandomHex {
    param([int] $ByteCount)

    $bytes = New-Object byte[] $ByteCount
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    } finally {
        $generator.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Read-SecretFile {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到临时凭据文件：$Path"
    }
    $value = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "临时凭据文件为空：$Path"
    }
    return $value
}

function Normalize-HttpsOrigin {
    param([string] $Value)

    $trimmed = $Value.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw '固定域名模式需要 HTTPS 公网地址。'
    }
    try {
        $uri = [Uri] $trimmed
    } catch {
        throw "公网地址无效：$Value"
    }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "公网地址必须是完整 HTTPS Origin：$Value"
    }
    if ($uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
        throw "公网地址不能包含路径、查询参数、片段或用户信息：$Value"
    }
    return $trimmed
}

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    throw 'RuntimeRoot 不能为空。'
}
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$ManifestPath = Join-Path $RuntimeRoot 'runtime.json'
$SettingsPath = Join-Path $RuntimeRoot 'control-panel-settings.json'
$AuthTokenPath = Join-Path $RuntimeRoot 'auth-token.dpapi'
$OAuthPasswordPath = Join-Path $RuntimeRoot 'oauth-password.dpapi'
$OAuthSecretPath = Join-Path $RuntimeRoot 'oauth-token-secret.dpapi'
$TunnelTokenPath = Join-Path $RuntimeRoot 'cloudflared-token.dpapi'
$NexusTokenPath = Join-Path $RuntimeRoot 'nexus-token.dpapi'
$TunnelModePath = Join-Path $RuntimeRoot 'cloudflared-mode.txt'
$ServerUrlPath = Join-Path $RuntimeRoot 'server-url.txt'
$NamedServerUrlPath = Join-Path $RuntimeRoot 'named-server-url.txt'
$QuickTunnelUrlPath = Join-Path $RuntimeRoot 'quick-tunnel-url.txt'
$CloudflaredStdoutPath = Join-Path $RuntimeRoot 'cloudflared.out.log'
$CloudflaredStderrPath = Join-Path $RuntimeRoot 'cloudflared.err.log'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

$Manifest = Read-JsonFile -Path $ManifestPath
$AgentDockBinary = [string] (Get-ObjectProperty -Object $Manifest -Name 'agentdock_binary' -Default (Join-Path $RuntimeRoot 'bin\agentdock.exe'))
$TrayBinary = [string] (Get-ObjectProperty -Object $Manifest -Name 'tray_binary' -Default (Join-Path $RuntimeRoot 'bin\agentdock-tray.exe'))
$AgentDockLauncher = [string] (Get-ObjectProperty -Object $Manifest -Name 'agentdock_launcher' -Default (Join-Path $RuntimeRoot 'start-agentdock.ps1'))
$CloudflaredLauncher = [string] (Get-ObjectProperty -Object $Manifest -Name 'cloudflared_launcher' -Default (Join-Path $RuntimeRoot 'start-cloudflared.ps1'))
$CloudflaredBinary = [string] (Get-ObjectProperty -Object $Manifest -Name 'cloudflared_binary' -Default (Join-Path $RuntimeRoot 'bin\cloudflared.exe'))
$PrivilegeMode = [string] (Get-ObjectProperty -Object $Manifest -Name 'privilege_mode' -Default 'standard')
$TaskName = [string] (Get-ObjectProperty -Object $Manifest -Name 'agentdock_task_name' -Default 'AgentDock')
$CoreStartupValueName = [string] (Get-ObjectProperty -Object $Manifest -Name 'startup_value_name' -Default 'AgentDock')
$TrayStartupValueName = [string] (Get-ObjectProperty -Object $Manifest -Name 'tray_startup_value_name' -Default 'AgentDockTray')
$CloudflaredStartupValueName = [string] (Get-ObjectProperty -Object $Manifest -Name 'cloudflared_startup_value_name' -Default 'AgentDockCloudflared')
$InstalledManagerPath = Join-Path $RuntimeRoot 'installer\manage-windows.ps1'
$ManagerPath = if (Test-Path -LiteralPath $InstalledManagerPath -PathType Leaf) { $InstalledManagerPath } else { $PSCommandPath }

function Get-ControlPanelSettings {
    $stored = Read-JsonFile -Path $SettingsPath
    $manifestPort = [int] (Get-ObjectProperty -Object $Manifest -Name 'port' -Default 8765)
    $storedPort = [int] (Get-ObjectProperty -Object $stored -Name 'port' -Default $manifestPort)
    if ($storedPort -lt 1 -or $storedPort -gt 65535) {
        $storedPort = 8765
    }
    $storedLogLevel = [string] (Get-ObjectProperty -Object $stored -Name 'log_level' -Default 'info')
    if (@('debug', 'info', 'warn', 'error') -notcontains $storedLogLevel) {
        $storedLogLevel = 'info'
    }
    return [pscustomobject][ordered]@{
        port = $storedPort
        log_level = $storedLogLevel
        nexus_endpoint = [string] (Get-ObjectProperty -Object $stored -Name 'nexus_endpoint' -Default '')
        browser_enabled = Convert-ToBoolean -Value (Get-ObjectProperty -Object $stored -Name 'browser_enabled' -Default $false)
        browser_runner_dir = [string] (Get-ObjectProperty -Object $stored -Name 'browser_runner_dir' -Default '')
        browser_node_path = [string] (Get-ObjectProperty -Object $stored -Name 'browser_node_path' -Default '')
    }
}

function Update-RuntimeManifest {
    param(
        [int] $RuntimePort,
        [string] $RuntimeMode,
        [string] $PublicUrl
    )

    Set-ObjectProperty -Object $Manifest -Name 'schema_version' -Value 1
    Set-ObjectProperty -Object $Manifest -Name 'agentdock_binary' -Value $AgentDockBinary
    Set-ObjectProperty -Object $Manifest -Name 'tray_binary' -Value $TrayBinary
    Set-ObjectProperty -Object $Manifest -Name 'agentdock_launcher' -Value $AgentDockLauncher
    Set-ObjectProperty -Object $Manifest -Name 'cloudflared_binary' -Value $CloudflaredBinary
    Set-ObjectProperty -Object $Manifest -Name 'cloudflared_launcher' -Value $CloudflaredLauncher
    Set-ObjectProperty -Object $Manifest -Name 'startup_value_name' -Value $CoreStartupValueName
    Set-ObjectProperty -Object $Manifest -Name 'tray_startup_value_name' -Value $TrayStartupValueName
    Set-ObjectProperty -Object $Manifest -Name 'cloudflared_startup_value_name' -Value $CloudflaredStartupValueName
    Set-ObjectProperty -Object $Manifest -Name 'host' -Value '127.0.0.1'
    Set-ObjectProperty -Object $Manifest -Name 'port' -Value $RuntimePort
    Set-ObjectProperty -Object $Manifest -Name 'local_mcp_url' -Value "http://127.0.0.1:$RuntimePort/mcp"
    Set-ObjectProperty -Object $Manifest -Name 'tunnel_mode' -Value $RuntimeMode
    Set-ObjectProperty -Object $Manifest -Name 'public_url' -Value $PublicUrl
    Write-JsonAtomically -Path $ManifestPath -Value $Manifest
}

function Ensure-Credentials {
    if ([string]::IsNullOrWhiteSpace((Read-TextFile -Path $AuthTokenPath))) {
        Write-ProtectedText -Path $AuthTokenPath -Value (New-RandomHex -ByteCount 32) -Entropy 'agentdock.startup.v1'
    }
    if ([string]::IsNullOrWhiteSpace((Read-TextFile -Path $OAuthPasswordPath))) {
        Write-ProtectedText -Path $OAuthPasswordPath -Value (New-RandomHex -ByteCount 12) -Entropy 'agentdock.oauth.password.v1'
    }
    if ([string]::IsNullOrWhiteSpace((Read-TextFile -Path $OAuthSecretPath))) {
        Write-ProtectedText -Path $OAuthSecretPath -Value (New-RandomHex -ByteCount 32) -Entropy 'agentdock.oauth.secret.v1'
    }
}

function Get-ProcessesAtPath {
    param(
        [string] $ProcessName,
        [string] $BinaryPath
    )

    if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
        return @()
    }
    $normalizedPath = [IO.Path]::GetFullPath($BinaryPath)
    return @(Get-CimInstance Win32_Process -Filter "Name = '$($ProcessName).exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and
        [string]::Equals(
            [IO.Path]::GetFullPath($_.ExecutablePath),
            $normalizedPath,
            [StringComparison]::OrdinalIgnoreCase
        )
    })
}

function Stop-ProcessesAtPath {
    param(
        [string] $ProcessName,
        [string] $BinaryPath
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $processes = @(Get-ProcessesAtPath -ProcessName $ProcessName -BinaryPath $BinaryPath)
        foreach ($process in $processes) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        if ($processes.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "无法停止 $ProcessName：$BinaryPath"
}

function Test-AgentDockHealth {
    param([int] $HealthPort)

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$HealthPort/healthz" -TimeoutSec 2
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Wait-AgentDockHealth {
    param([int] $HealthPort)

    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        if (Test-AgentDockHealth -HealthPort $HealthPort) {
            return
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "AgentDock 健康检查失败：http://127.0.0.1:$HealthPort/healthz"
}

function Escape-SingleQuoted {
    param([string] $Value)
    return $Value.Replace("'", "''")
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedManagerAction {
    param(
        [string] $InternalAction,
        [string] $InternalEnabled = 'false'
    )

    $escapedManager = Escape-SingleQuoted -Value $ManagerPath
    $escapedRoot = Escape-SingleQuoted -Value $RuntimeRoot
    $command = "& '$escapedManager' -Action '$InternalAction' -RuntimeRoot '$escapedRoot' -Enabled '$InternalEnabled'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" `
        -Verb RunAs `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "需要管理员权限的操作失败，退出码：$($process.ExitCode)"
    }
}

function Write-Launchers {
    $settings = Get-ControlPanelSettings
    $escapedManager = Escape-SingleQuoted -Value $ManagerPath
    $escapedRoot = Escape-SingleQuoted -Value $RuntimeRoot
    $escapedAgentDockBinary = Escape-SingleQuoted -Value $AgentDockBinary
    $escapedCloudflaredBinary = Escape-SingleQuoted -Value $CloudflaredBinary

    # 旧版本升级仍可能由自更新逻辑识别该文件，因此暂时保留兼容启动器。
    # 新安装和桌面端均直接调用 agentdock service；支持的旧版本淘汰后可删除此文件。
    $coreLauncher = @"
`$ErrorActionPreference = 'Stop'
`$env:AGENTDOCK_PORT = '$($settings.port)'
`$agentDockBinary = '$escapedAgentDockBinary'
& '$escapedAgentDockBinary' service launch-core --runtime-root '$escapedRoot'
exit `$LASTEXITCODE
"@
    Write-TextAtomically -Path $AgentDockLauncher -Value $coreLauncher

    $tunnelLauncher = @"
`$ErrorActionPreference = 'Stop'
`$cloudflaredBinary = '$escapedCloudflaredBinary'
& '$escapedManager' -Action launch-tunnel -RuntimeRoot '$escapedRoot'
exit `$LASTEXITCODE
"@
    Write-TextAtomically -Path $CloudflaredLauncher -Value $tunnelLauncher
}

function Start-HiddenLauncher {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到启动脚本：$Path"
    }
    $arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Path`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Set-RunValue {
    param(
        [string] $Name,
        [string] $Value
    )

    New-Item -Path $RunKey -Force | Out-Null
    New-ItemProperty -Path $RunKey -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Remove-RunValue {
    param([string] $Name)
    Remove-ItemProperty -LiteralPath $RunKey -Name $Name -ErrorAction SilentlyContinue
}

function Get-CoreStartupCommand {
    return "`"$TrayBinary`" --start-core --runtime-root `"$RuntimeRoot`""
}

function Get-TunnelStartupCommand {
    return "powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$CloudflaredLauncher`""
}

function Get-TrayStartupCommand {
    return "`"$TrayBinary`" --background"
}

function Invoke-TaskOperation {
    param([ValidateSet('start', 'stop')] [string] $Operation)

    try {
        if ($Operation -eq 'start') {
            Start-TaskPreservingStartupState
        } else {
            Stop-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
        }
    } catch {
        if (Test-IsAdministrator) {
            throw
        }
        Invoke-ElevatedManagerAction -InternalAction "task-$Operation"
    }
}

function Start-TaskPreservingStartupState {
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
    $wasEnabled = [bool] $task.Settings.Enabled

    # 用户关闭开机启动后仍应允许手动启动。这里临时启用任务，启动后恢复原状态。
    if (-not $wasEnabled) {
        Enable-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop | Out-Null
    }
    try {
        Start-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
    } finally {
        if (-not $wasEnabled) {
            Disable-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop | Out-Null
        }
    }
}

function Set-TaskStartupState {
    param([bool] $ShouldEnable)

    if (-not (Test-IsAdministrator)) {
        Invoke-ElevatedManagerAction -InternalAction 'set-task-startup' -InternalEnabled $ShouldEnable.ToString().ToLowerInvariant()
        return
    }
    if ($ShouldEnable) {
        Enable-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop | Out-Null
    } else {
        Disable-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop | Out-Null
    }
}

function Invoke-LaunchCore {
    if (-not (Test-Path -LiteralPath $AgentDockBinary -PathType Leaf)) {
        throw "找不到 AgentDock 核心程序：$AgentDockBinary"
    }
    Ensure-Credentials
    $settings = Get-ControlPanelSettings

    $env:AGENTDOCK_AUTH_TOKEN = Read-ProtectedText -Path $AuthTokenPath -Entropy 'agentdock.startup.v1'
    $env:AGENTDOCK_HOST = '127.0.0.1'
    $env:AGENTDOCK_PORT = [string] $settings.port
    $env:AGENTDOCK_LOG_LEVEL = [string] $settings.log_level
    $env:AGENTDOCK_BROWSER_ENABLED = ([bool] $settings.browser_enabled).ToString().ToLowerInvariant()

    foreach ($name in @(
        'AGENTDOCK_NEXUS_ENDPOINT',
        'AGENTDOCK_NEXUS_TOKEN',
        'AGENTDOCK_BROWSER_RUNNER_DIR',
        'AGENTDOCK_BROWSER_NODE_PATH',
        'AGENTDOCK_SERVER_URL',
        'AGENTDOCK_OAUTH_ENABLED',
        'AGENTDOCK_OAUTH_PASSWORD',
        'AGENTDOCK_OAUTH_TOKEN_SECRET'
    )) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }

    if (-not [string]::IsNullOrWhiteSpace([string] $settings.nexus_endpoint)) {
        $env:AGENTDOCK_NEXUS_ENDPOINT = [string] $settings.nexus_endpoint
    }
    if (Test-Path -LiteralPath $NexusTokenPath -PathType Leaf) {
        $env:AGENTDOCK_NEXUS_TOKEN = Read-ProtectedText -Path $NexusTokenPath -Entropy 'agentdock.nexus.token.v1'
    }
    if (-not [string]::IsNullOrWhiteSpace([string] $settings.browser_runner_dir)) {
        $env:AGENTDOCK_BROWSER_RUNNER_DIR = [string] $settings.browser_runner_dir
    }
    if (-not [string]::IsNullOrWhiteSpace([string] $settings.browser_node_path)) {
        $env:AGENTDOCK_BROWSER_NODE_PATH = [string] $settings.browser_node_path
    }

    $activeServerUrl = Read-TextFile -Path $ServerUrlPath
    if (-not [string]::IsNullOrWhiteSpace($activeServerUrl)) {
        $env:AGENTDOCK_SERVER_URL = $activeServerUrl
        $env:AGENTDOCK_OAUTH_ENABLED = 'true'
        $env:AGENTDOCK_OAUTH_PASSWORD = Read-ProtectedText -Path $OAuthPasswordPath -Entropy 'agentdock.oauth.password.v1'
        $env:AGENTDOCK_OAUTH_TOKEN_SECRET = Read-ProtectedText -Path $OAuthSecretPath -Entropy 'agentdock.oauth.secret.v1'
    }

    & $AgentDockBinary
    return $LASTEXITCODE
}

function Invoke-NativeCoreCommand {
    param([ValidateSet('start', 'stop', 'restart')] [string] $Command)

    & $AgentDockBinary service $Command --runtime-root $RuntimeRoot
    if ($LASTEXITCODE -ne 0) {
        throw "AgentDock 原生服务命令执行失败：$Command，退出码：$LASTEXITCODE"
    }
}

function Start-Core {
    Invoke-NativeCoreCommand -Command start
}

function Stop-Core {
    Invoke-NativeCoreCommand -Command stop
}

function Restart-Core {
    Invoke-NativeCoreCommand -Command restart
}

function Wait-CloudflaredRunning {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        if (@(Get-ProcessesAtPath -ProcessName 'cloudflared' -BinaryPath $CloudflaredBinary).Count -gt 0) {
            return
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "cloudflared 未保持运行：$CloudflaredBinary"
}

function Get-QuickTunnelUrlFromLogs {
    param([Diagnostics.Process] $Process)

    $deadline = [DateTime]::UtcNow.AddSeconds(35)
    do {
        Start-Sleep -Milliseconds 500
        foreach ($path in @($CloudflaredStdoutPath, $CloudflaredStderrPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                continue
            }
            try {
                $match = [Regex]::Match(
                    (Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop),
                    'https://[A-Za-z0-9-]+\.trycloudflare\.com'
                )
                if ($match.Success) {
                    return $match.Value
                }
            } catch {
            }
        }
        if ($Process.HasExited) {
            throw "cloudflared 在生成临时地址前退出，退出码：$($Process.ExitCode)"
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'cloudflared 未在 35 秒内生成 trycloudflare.com 临时地址。'
}

function Invoke-LaunchTunnel {
    $modeValue = (Read-TextFile -Path $TunnelModePath).ToLowerInvariant()
    if ($modeValue -eq 'none' -or [string]::IsNullOrWhiteSpace($modeValue)) {
        return 0
    }
    if (@('quick', 'named') -notcontains $modeValue) {
        throw "不支持的 Cloudflare Tunnel 模式：$modeValue"
    }
    if (-not (Test-Path -LiteralPath $CloudflaredBinary -PathType Leaf)) {
        throw '找不到 cloudflared.exe，请运行 Setup.exe 修复安装。'
    }

    $settings = Get-ControlPanelSettings
    $arguments = @('tunnel', '--no-autoupdate')
    if ($modeValue -eq 'quick') {
        $arguments += @('--url', "http://127.0.0.1:$($settings.port)")
    } else {
        $token = Read-ProtectedText -Path $TunnelTokenPath -Entropy 'agentdock.cloudflare.tunnel.v1'
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw '固定域名模式没有保存 Cloudflare Tunnel Token。'
        }
        $env:TUNNEL_TOKEN = $token
        $arguments += 'run'
    }

    Write-TextAtomically -Path $CloudflaredStdoutPath -Value ''
    Write-TextAtomically -Path $CloudflaredStderrPath -Value ''
    if ($modeValue -eq 'quick') {
        Remove-Item -LiteralPath $QuickTunnelUrlPath -Force -ErrorAction SilentlyContinue
    }

    $process = Start-Process `
        -FilePath $CloudflaredBinary `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $CloudflaredStdoutPath `
        -RedirectStandardError $CloudflaredStderrPath `
        -PassThru
    if ($modeValue -eq 'quick') {
        try {
            $publicUrl = Get-QuickTunnelUrlFromLogs -Process $process
            Write-TextAtomically -Path $ServerUrlPath -Value $publicUrl
            Restart-Core
            Update-RuntimeManifest -RuntimePort $settings.port -RuntimeMode 'quick' -PublicUrl $publicUrl
            # 最后写入 ready 文件，确保 GUI 不会提前读取到尚未生效的新地址。
            Write-TextAtomically -Path $QuickTunnelUrlPath -Value $publicUrl
        } catch {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            throw
        }
    }

    $process.WaitForExit()
    return $process.ExitCode
}

function Start-Tunnel {
    $modeValue = (Read-TextFile -Path $TunnelModePath).ToLowerInvariant()
    if (@('quick', 'named') -notcontains $modeValue) {
        return
    }
    if (@(Get-ProcessesAtPath -ProcessName 'cloudflared' -BinaryPath $CloudflaredBinary).Count -gt 0) {
        return
    }
    Write-Launchers
    Start-HiddenLauncher -Path $CloudflaredLauncher
    Wait-CloudflaredRunning
}

function Stop-Tunnel {
    Stop-ProcessesAtPath -ProcessName 'cloudflared' -BinaryPath $CloudflaredBinary
}

function Wait-QuickTunnelReady {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        $publicUrl = Read-TextFile -Path $QuickTunnelUrlPath
        if (-not [string]::IsNullOrWhiteSpace($publicUrl)) {
            return $publicUrl
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw '新的 Quick Tunnel 地址未在 45 秒内准备完成。'
}

function Preserve-NamedServerUrl {
    $currentMode = (Read-TextFile -Path $TunnelModePath).ToLowerInvariant()
    $currentServerUrl = Read-TextFile -Path $ServerUrlPath
    if ($currentMode -eq 'named' -and -not [string]::IsNullOrWhiteSpace($currentServerUrl)) {
        Write-TextAtomically -Path $NamedServerUrlPath -Value $currentServerUrl
    }
}

function Clear-ActivePublicUrl {
    Write-TextAtomically -Path $ServerUrlPath -Value ''
    Remove-Item -LiteralPath $QuickTunnelUrlPath -Force -ErrorAction SilentlyContinue
}

function Set-TunnelMode {
    param(
        [string] $RequestedMode,
        [string] $RequestedServerUrl,
        [string] $RequestedTokenFile
    )

    if (@('none', 'quick', 'named') -notcontains $RequestedMode) {
        throw "不支持的公网模式：$RequestedMode"
    }
    Ensure-Credentials
    Preserve-NamedServerUrl

    $normalizedServerUrl = ''
    if ($RequestedMode -eq 'named') {
        $candidate = $RequestedServerUrl.Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = Read-TextFile -Path $NamedServerUrlPath
        }
        $normalizedServerUrl = Normalize-HttpsOrigin -Value $candidate

        $providedToken = Read-SecretFile -Path $RequestedTokenFile
        if (-not [string]::IsNullOrWhiteSpace($providedToken)) {
            Write-ProtectedText -Path $TunnelTokenPath -Value $providedToken -Entropy 'agentdock.cloudflare.tunnel.v1'
        }
        $storedToken = Read-ProtectedText -Path $TunnelTokenPath -Entropy 'agentdock.cloudflare.tunnel.v1'
        if ([string]::IsNullOrWhiteSpace($storedToken)) {
            throw '固定域名模式需要 Cloudflare Tunnel Token。'
        }
    }

    Stop-Tunnel
    $settings = Get-ControlPanelSettings
    switch ($RequestedMode) {
        'none' {
            Write-TextAtomically -Path $TunnelModePath -Value 'none'
            Clear-ActivePublicUrl
            Remove-RunValue -Name $CloudflaredStartupValueName
            Update-RuntimeManifest -RuntimePort $settings.port -RuntimeMode 'none' -PublicUrl ''
            Write-Launchers
            Restart-Core
        }
        'quick' {
            Write-TextAtomically -Path $TunnelModePath -Value 'quick'
            Clear-ActivePublicUrl
            Update-RuntimeManifest -RuntimePort $settings.port -RuntimeMode 'none' -PublicUrl ''
            Write-Launchers
            Set-RunValue -Name $CloudflaredStartupValueName -Value (Get-TunnelStartupCommand)
            Restart-Core
            Start-Tunnel
            [void] (Wait-QuickTunnelReady)
        }
        'named' {
            Write-TextAtomically -Path $NamedServerUrlPath -Value $normalizedServerUrl
            Write-TextAtomically -Path $ServerUrlPath -Value $normalizedServerUrl
            Write-TextAtomically -Path $TunnelModePath -Value 'named'
            Remove-Item -LiteralPath $QuickTunnelUrlPath -Force -ErrorAction SilentlyContinue
            Update-RuntimeManifest -RuntimePort $settings.port -RuntimeMode 'named' -PublicUrl $normalizedServerUrl
            Write-Launchers
            Set-RunValue -Name $CloudflaredStartupValueName -Value (Get-TunnelStartupCommand)
            Restart-Core
            Start-Tunnel
        }
    }
}

function Regenerate-QuickTunnel {
    $modeValue = (Read-TextFile -Path $TunnelModePath).ToLowerInvariant()
    if ($modeValue -ne 'quick') {
        throw '只有临时地址模式可以重新生成 Quick Tunnel。'
    }
    Stop-Tunnel
    Clear-ActivePublicUrl
    $settings = Get-ControlPanelSettings
    Update-RuntimeManifest -RuntimePort $settings.port -RuntimeMode 'none' -PublicUrl ''
    Restart-Core
    Start-Tunnel
    [void] (Wait-QuickTunnelReady)
}

function Save-ControlPanelSettings {
    if ($Port -lt 1 -or $Port -gt 65535) {
        throw '端口必须是 1 到 65535 之间的整数。'
    }

    $settings = [pscustomobject][ordered]@{
        port = $Port
        log_level = $LogLevel
        nexus_endpoint = $NexusEndpoint.Trim()
        browser_enabled = Convert-ToBoolean -Value $BrowserEnabled
        browser_runner_dir = $BrowserRunnerDir.Trim()
        browser_node_path = $BrowserNodePath.Trim()
    }
    Write-JsonAtomically -Path $SettingsPath -Value $settings

    $nexusToken = Read-SecretFile -Path $NexusTokenFile
    if (-not [string]::IsNullOrWhiteSpace($nexusToken)) {
        Write-ProtectedText -Path $NexusTokenPath -Value $nexusToken -Entropy 'agentdock.nexus.token.v1'
    }

    $modeValue = (Read-TextFile -Path $TunnelModePath).ToLowerInvariant()
    if (@('none', 'quick', 'named') -notcontains $modeValue) {
        $modeValue = 'none'
    }

    Stop-Tunnel
    $publicUrl = ''
    if ($modeValue -eq 'named') {
        $publicUrl = Read-TextFile -Path $ServerUrlPath
    }
    if ($modeValue -eq 'quick') {
        Clear-ActivePublicUrl
    }
    $manifestMode = if ($modeValue -eq 'quick') { 'none' } else { $modeValue }
    Update-RuntimeManifest -RuntimePort $Port -RuntimeMode $manifestMode -PublicUrl $publicUrl
    Write-Launchers
    Restart-Core
    if ($modeValue -ne 'none') {
        Start-Tunnel
    }
    if ($modeValue -eq 'quick') {
        [void] (Wait-QuickTunnelReady)
    }
}

function Set-ComponentStartup {
    param(
        [string] $TargetComponent,
        [bool] $ShouldEnable
    )

    $enabledValue = $ShouldEnable.ToString().ToLowerInvariant()
    & $AgentDockBinary service autostart `
        --runtime-root $RuntimeRoot `
        --component $TargetComponent `
        --enabled $enabledValue
    if ($LASTEXITCODE -ne 0) {
        throw "AgentDock 原生开机启动命令执行失败，退出码：$LASTEXITCODE"
    }
}

function Start-AgentDockRuntime {
    Start-Core
    Start-Tunnel
}

function Stop-AgentDockRuntime {
    Stop-Tunnel
    Stop-Core
}

function Restart-AgentDockRuntime {
    $modeValue = (Read-TextFile -Path $TunnelModePath).ToLowerInvariant()
    Stop-Tunnel
    Stop-Core
    if ($modeValue -eq 'quick') {
        Clear-ActivePublicUrl
        $settings = Get-ControlPanelSettings
        Update-RuntimeManifest -RuntimePort $settings.port -RuntimeMode 'none' -PublicUrl ''
    }
    Start-Core
    Start-Tunnel
    if ($modeValue -eq 'quick') {
        [void] (Wait-QuickTunnelReady)
    }
}

switch ($Action) {
    'launch-core' {
        exit (Invoke-LaunchCore)
    }
    'launch-tunnel' {
        exit (Invoke-LaunchTunnel)
    }
    'set-task-startup' {
        if (-not (Test-IsAdministrator)) {
            throw '设置最高权限计划任务需要管理员权限。'
        }
        Set-TaskStartupState -ShouldEnable (Convert-ToBoolean -Value $Enabled)
        exit 0
    }
    'task-start' {
        if (-not (Test-IsAdministrator)) {
            throw '启动最高权限计划任务需要管理员权限。'
        }
        Start-TaskPreservingStartupState
        exit 0
    }
    'task-stop' {
        if (-not (Test-IsAdministrator)) {
            throw '停止最高权限计划任务需要管理员权限。'
        }
        Stop-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Stop-ProcessesAtPath -ProcessName 'agentdock' -BinaryPath $AgentDockBinary
        exit 0
    }
    'start' {
        Start-AgentDockRuntime
    }
    'stop' {
        Stop-AgentDockRuntime
    }
    'restart' {
        Restart-AgentDockRuntime
    }
    'start-tunnel' {
        Start-Tunnel
    }
    'stop-tunnel' {
        Stop-Tunnel
    }
    'update' {
        if (-not (Test-Path -LiteralPath $AgentDockBinary -PathType Leaf)) {
            throw "找不到 AgentDock 核心程序：$AgentDockBinary"
        }
        & $AgentDockBinary update
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }
    'set-mode' {
        Set-TunnelMode -RequestedMode $Mode -RequestedServerUrl $ServerUrl -RequestedTokenFile $TunnelTokenFile
    }
    'regenerate-quick' {
        Regenerate-QuickTunnel
    }
    'save-settings' {
        Save-ControlPanelSettings
    }
    'set-startup' {
        Set-ComponentStartup -TargetComponent $Component -ShouldEnable (Convert-ToBoolean -Value $Enabled)
    }
}
