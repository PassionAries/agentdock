[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $SetupPath,
    [string] $InstallRoot = (Join-Path $env:RUNNER_TEMP 'agentdock-setup-e2e'),
    [switch] $AllowLegacyTaskMutation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $AllowLegacyTaskMutation) {
    throw 'Legacy scheduled-task mutation is disabled. Pass -AllowLegacyTaskMutation only in an isolated Windows test environment.'
}

function Wait-ProcessOrThrow {
    param(
        [Diagnostics.Process] $Process,
        [int] $TimeoutSeconds,
        [string] $Description,
        [string] $LogPath
    )

    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
            Write-Host "----- $Description log -----"
            Get-Content -LiteralPath $LogPath | Write-Host
            Write-Host "----- end $Description log -----"
        }
        throw "$Description did not exit within $TimeoutSeconds seconds."
    }
    if ($Process.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
            Write-Host "----- $Description log -----"
            Get-Content -LiteralPath $LogPath | Write-Host
            Write-Host "----- end $Description log -----"
        }
        throw "$Description failed with exit code $($Process.ExitCode)."
    }
}

function Get-RunValue {
    param([string] $Name)

    try {
        return Get-ItemPropertyValue -LiteralPath $runKey -Name $Name -ErrorAction Stop
    } catch {
        return $null
    }
}

function Stop-ProcessByPath {
    param([string] $ProcessName, [string] $BinaryPath)

    if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
        return
    }
    $normalized = [IO.Path]::GetFullPath($BinaryPath)
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object {
        try {
            [string]::Equals(
                [IO.Path]::GetFullPath($_.Path),
                $normalized,
                [StringComparison]::OrdinalIgnoreCase
            )
        } catch {
            $false
        }
    } | Stop-Process -Force -ErrorAction SilentlyContinue
}

$resolvedSetup = (Resolve-Path -LiteralPath $SetupPath).Path
$binaryPath = Join-Path $InstallRoot 'bin\agentdock.exe'
$trayPath = Join-Path $InstallRoot 'bin\agentdock-tray.exe'
$trayIconPath = Join-Path $InstallRoot 'bin\agentdock.ico'
$manifestPath = Join-Path $InstallRoot 'runtime.json'
$launcherPath = Join-Path $InstallRoot 'start-agentdock.ps1'
$uninstallerPath = Join-Path $InstallRoot 'unins000.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$userHome = [Environment]::GetFolderPath('UserProfile')
$stateRoot = Join-Path $userHome '.agentdock'
$stateMarker = Join-Path $stateRoot ('setup-e2e-preserve-' + [Guid]::NewGuid().ToString('N') + '.txt')
$healthUrl = 'http://127.0.0.1:8765/healthz'
$setupProcess = $null
$repairProcess = $null
$uninstallProcess = $null
$setupLogPath = Join-Path $env:RUNNER_TEMP 'agentdock-setup-e2e-install.log'
$repairLogPath = Join-Path $env:RUNNER_TEMP 'agentdock-setup-e2e-repair.log'
$uninstallLogPath = Join-Path $env:RUNNER_TEMP 'agentdock-setup-e2e-uninstall.log'
$oldReleaseBaseUrl = $env:AGENTDOCK_RELEASE_BASE_URL
$oldCloudflaredReleaseBaseUrl = $env:AGENTDOCK_CLOUDFLARED_RELEASE_BASE_URL

try {
    Unregister-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $InstallRoot 'start-agentdock.ps1'),
        '# legacy PowerShell install marker',
        [Text.UTF8Encoding]::new($false)
    )

    # 指向必然失败的地址，确保 Setup 的核心载荷不会偷偷退回在线下载。
    $env:AGENTDOCK_RELEASE_BASE_URL = 'http://127.0.0.1:1/agentdock-offline-e2e'
    $env:AGENTDOCK_CLOUDFLARED_RELEASE_BASE_URL = 'http://127.0.0.1:1/cloudflared-offline-e2e'
    Remove-Item -LiteralPath $setupLogPath, $repairLogPath, $uninstallLogPath -Force -ErrorAction SilentlyContinue
    Write-Host "Starting AgentDockSetup.exe: $resolvedSetup"
    $setupProcess = Start-Process `
        -FilePath $resolvedSetup `
        -ArgumentList @(
            '/VERYSILENT',
            '/SUPPRESSMSGBOXES',
            '/LANG=chinesesimplified',
            '/NORESTART',
            "/DIR=$InstallRoot",
            "/LOG=$setupLogPath",
            '/MODE=local',
            '/AUTOSTART=1'
        ) `
        -PassThru
    Wait-ProcessOrThrow `
        -Process $setupProcess `
        -TimeoutSeconds 180 `
        -Description 'AgentDock Setup installation' `
        -LogPath $setupLogPath
    Write-Host 'AgentDock Setup installation exited successfully.'
    $initialLog = Get-Content -LiteralPath $setupLogPath -Raw
    if ($initialLog -notmatch 'AgentDock active language: chinesesimplified') {
        throw 'Setup did not use the Simplified Chinese messages.'
    }
    if ($initialLog -notmatch 'existing installation detected: source=powershell') {
        throw 'Setup did not recognize the legacy PowerShell installation.'
    }

    foreach ($path in @($binaryPath, $trayPath, $trayIconPath, $manifestPath, $uninstallerPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Setup did not create expected file: $path"
        }
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.install_channel -ne 'setup') {
        throw "Unexpected install channel: $($manifest.install_channel)"
    }
    if ($manifest.tunnel_mode -ne 'none') {
        throw "Local Setup unexpectedly enabled public access: $($manifest.tunnel_mode)"
    }
    if ($manifest.local_mcp_url -ne 'http://127.0.0.1:8765/mcp') {
        throw "Unexpected local MCP URL: $($manifest.local_mcp_url)"
    }

    $health = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -TimeoutSec 5
    if ($health.StatusCode -ne 200) {
        throw "Unexpected health status: $($health.StatusCode)"
    }
    foreach ($name in @('AgentDock', 'AgentDockTray')) {
        $value = Get-ItemPropertyValue -LiteralPath $runKey -Name $name -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Setup did not create HKCU startup value: $name"
        }
    }

    Write-Host 'Creating a running legacy AgentDock scheduled task for migration testing.'
    Stop-ProcessByPath -ProcessName 'agentdock' -BinaryPath $binaryPath
    Start-Sleep -Milliseconds 500
    foreach ($name in @('AgentDock', 'AgentDockTray')) {
        Remove-ItemProperty -LiteralPath $runKey -Name $name -ErrorAction SilentlyContinue
    }
    $legacyTaskAction = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`""
    $legacyTaskTrigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask `
        -TaskName 'AgentDock' `
        -TaskPath '\' `
        -Action $legacyTaskAction `
        -Trigger $legacyTaskTrigger `
        -Description 'AgentDock legacy migration test' `
        -Force | Out-Null
    Start-ScheduledTask -TaskName 'AgentDock' -TaskPath '\'
    $legacyDeadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        try {
            $legacyHealth = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -TimeoutSec 2
            $legacyTask = Get-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction Stop
            if ($legacyHealth.StatusCode -eq 200 -and $legacyTask.State -eq 'Running') {
                break
            }
        } catch {
        }
        if ([DateTime]::UtcNow -ge $legacyDeadline) {
            throw 'Legacy AgentDock scheduled task did not start a healthy server.'
        }
    } while ($true)

    Write-Host 'Starting AgentDockSetup.exe again to verify Setup-managed repair detection.'
    $repairProcess = Start-Process `
        -FilePath $resolvedSetup `
        -ArgumentList @(
            '/VERYSILENT',
            '/SUPPRESSMSGBOXES',
            '/LANG=chinesesimplified',
            '/NORESTART',
            "/DIR=$InstallRoot",
            "/LOG=$repairLogPath"
        ) `
        -PassThru
    Wait-ProcessOrThrow `
        -Process $repairProcess `
        -TimeoutSeconds 180 `
        -Description 'AgentDock Setup repair' `
        -LogPath $repairLogPath
    $repairLog = Get-Content -LiteralPath $repairLogPath -Raw
    if ($repairLog -notmatch 'existing installation detected: source=setup') {
        throw 'Setup did not recognize the existing Setup-managed installation.'
    }
    if ($repairLog -notmatch 'AgentDock legacy scheduled task detected') {
        throw 'Setup did not detect the legacy AgentDock scheduled task.'
    }
    if ($null -ne (Get-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction SilentlyContinue)) {
        throw 'Setup did not remove the migrated legacy AgentDock scheduled task.'
    }
    foreach ($name in @('AgentDock', 'AgentDockTray')) {
        if ([string]::IsNullOrWhiteSpace((Get-RunValue -Name $name))) {
            throw "Setup repair did not preserve startup through HKCU: $name"
        }
    }
    if ((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).tunnel_mode -ne 'none') {
        throw 'Setup repair did not preserve local-only connection mode.'
    }

    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    [IO.File]::WriteAllText($stateMarker, 'preserve', [Text.UTF8Encoding]::new($false))

    Write-Host "Starting AgentDock uninstaller: $uninstallerPath"
    $uninstallProcess = Start-Process `
        -FilePath $uninstallerPath `
        -ArgumentList @(
            '/VERYSILENT',
            '/SUPPRESSMSGBOXES',
            '/NORESTART',
            "/LOG=$uninstallLogPath"
        ) `
        -PassThru
    Wait-ProcessOrThrow `
        -Process $uninstallProcess `
        -TimeoutSeconds 120 `
        -Description 'AgentDock Setup uninstall' `
        -LogPath $uninstallLogPath
    Write-Host 'AgentDock Setup uninstall exited successfully.'
    if (Test-Path -LiteralPath $binaryPath -PathType Leaf) {
        throw 'AgentDock binary remained after Setup uninstall.'
    }
    if (-not (Test-Path -LiteralPath $stateMarker -PathType Leaf)) {
        throw 'Silent Setup uninstall unexpectedly deleted user state.'
    }
    foreach ($name in @('AgentDock', 'AgentDockTray', 'AgentDockCloudflared')) {
        if ($null -ne (Get-RunValue -Name $name)) {
            throw "HKCU startup value remained after Setup uninstall: $name"
        }
    }

    Write-Host 'AgentDock Setup install, health check, and uninstall passed.'
} catch {
    foreach ($log in @($setupLogPath, $repairLogPath, $uninstallLogPath)) {
        if (Test-Path -LiteralPath $log -PathType Leaf) {
            Write-Host "----- failure log: $log -----"
            Get-Content -LiteralPath $log | Write-Host
            Write-Host "----- end failure log -----"
        }
    }
    throw
} finally {
    $env:AGENTDOCK_RELEASE_BASE_URL = $oldReleaseBaseUrl
    $env:AGENTDOCK_CLOUDFLARED_RELEASE_BASE_URL = $oldCloudflaredReleaseBaseUrl
    Stop-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($process in @($setupProcess, $repairProcess, $uninstallProcess)) {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Stop-ProcessByPath -ProcessName 'agentdock-tray' -BinaryPath $trayPath
    Stop-ProcessByPath -ProcessName 'agentdock' -BinaryPath $binaryPath
    foreach ($name in @('AgentDock', 'AgentDockTray', 'AgentDockCloudflared')) {
        Remove-ItemProperty -LiteralPath $runKey -Name $name -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stateMarker -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $setupLogPath, $repairLogPath, $uninstallLogPath -Force -ErrorAction SilentlyContinue
}
