[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AgentDock\bin'),
    [switch] $PurgeState,
    [string] $StartupValueName = 'AgentDock',
    [string] $CloudflaredStartupValueName = 'AgentDockCloudflared',
    [string] $TrayStartupValueName = 'AgentDockTray'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-ProcessByPath {
    param(
        [string] $ProcessName,
        [string] $BinaryPath
    )

    if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
        return
    }
    $normalizedBinaryPath = [IO.Path]::GetFullPath($BinaryPath)
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object {
        try {
            [string]::Equals(
                [IO.Path]::GetFullPath($_.Path),
                $normalizedBinaryPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        } catch {
            $false
        }
    } | Stop-Process -Force -ErrorAction SilentlyContinue
}

$runtimeDir = Split-Path -Parent $InstallDir
$userHome = [Environment]::GetFolderPath('UserProfile')
$agentDockBinary = Join-Path $InstallDir 'agentdock.exe'
$trayBinary = Join-Path $InstallDir 'agentdock-tray.exe'
$cloudflaredBinary = Join-Path $InstallDir 'cloudflared.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

Stop-ProcessByPath -ProcessName 'agentdock-tray' -BinaryPath $trayBinary
Stop-ProcessByPath -ProcessName 'cloudflared' -BinaryPath $cloudflaredBinary
Stop-ProcessByPath -ProcessName 'agentdock' -BinaryPath $agentDockBinary

if (Test-Path -LiteralPath $runKey) {
    Remove-ItemProperty -LiteralPath $runKey -Name $StartupValueName -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $runKey -Name $CloudflaredStartupValueName -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $runKey -Name $TrayStartupValueName -ErrorAction SilentlyContinue
}

# Legacy scheduled-task cleanup applies only to the default installation names.
if ($StartupValueName -eq 'AgentDock' -and $CloudflaredStartupValueName -eq 'AgentDockCloudflared' -and $TrayStartupValueName -eq 'AgentDockTray') {
    $task = Get-ScheduledTask -TaskName 'AgentDock' -ErrorAction SilentlyContinue
    if ($task) {
        try {
            Stop-ScheduledTask -TaskName 'AgentDock' -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName 'AgentDock' -Confirm:$false -ErrorAction Stop
        } catch {
            Write-Warning "Legacy AgentDock scheduled task could not be removed: $($_.Exception.Message)"
        }
    }
}

Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
foreach ($name in @(
    'start-agentdock.ps1',
    'start-cloudflared.ps1',
    'auth-token.dpapi',
    'oauth-password.dpapi',
    'oauth-token-secret.dpapi',
    'server-url.txt',
    'cloudflared-mode.txt',
    'cloudflared-token.dpapi',
    'cloudflared.out.log',
    'cloudflared.err.log',
    'runtime.json'
)) {
    Remove-Item -LiteralPath (Join-Path $runtimeDir $name) -Force -ErrorAction SilentlyContinue
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$updated = @($userPath -split ';' | Where-Object { $_ -and $_ -ne $InstallDir }) -join ';'
[Environment]::SetEnvironmentVariable('Path', $updated, 'User')

if ($PurgeState) {
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        throw 'Unable to resolve the current user profile directory.'
    }
    Remove-Item -LiteralPath (Join-Path $userHome '.agentdock') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $userHome 'AgentDock') -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'AgentDock, its tray, and its managed Cloudflare Tunnel were uninstalled.'
