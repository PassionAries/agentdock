[CmdletBinding()]
param(
    [string] $Version = 'latest',
    [string] $OfflineArchive = '',
    [string] $OfflineChecksumFile = '',
    [string] $OfflineCloudflaredBinary = '',
    [string] $InstallDir = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AgentDock\bin'),
    [switch] $RegisterStartup,
    [switch] $ConfigurePublicAccess,
    [int] $Port = 8765,
    [string] $AuthToken = '',
    [ValidateSet('auto', 'none', 'quick', 'named')]
    [string] $TunnelMode = 'auto',
    [string] $ServerUrl = '',
    [string] $TunnelToken = '',
    [string] $TunnelTokenFile = '',
    [switch] $DeleteTunnelTokenFile,
    [string] $ResultFile = '',
    [ValidateSet('script', 'setup')]
    [string] $InstallChannel = 'script',
    [string] $OAuthPassword = '',
    [string] $OAuthTokenSecret = '',
    [string] $StartupValueName = 'AgentDock',
    [string] $CloudflaredStartupValueName = 'AgentDockCloudflared',
    [string] $TrayStartupValueName = 'AgentDockTray',
    [ValidateSet('standard', 'elevated')]
    [string] $CorePrivilegeMode = 'standard',
    [ValidateSet('none', 'prepare-elevated', 'prepare-standard', 'restore', 'remove')]
    [string] $TaskAdminAction = 'none',
    [string] $TaskBackupDirectory = '',
    [string] $TaskLauncherPath = '',
    [string] $TaskUserSid = '',
    [string] $TaskUserName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Security

function Get-AgentDockArchitecture {
    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) {
        $architecture = $env:PROCESSOR_ARCHITEW6432
    }
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }

    switch ($architecture.ToUpperInvariant()) {
        'AMD64' { return 'amd64' }
        'X64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { throw "Unsupported Windows architecture: $architecture" }
    }
}

function Get-ReleaseBaseUrl {
    param([string] $RequestedVersion)

    $customBaseUrl = [Environment]::GetEnvironmentVariable('AGENTDOCK_RELEASE_BASE_URL')
    if (-not [string]::IsNullOrWhiteSpace($customBaseUrl)) {
        return $customBaseUrl.TrimEnd('/')
    }

    if ($RequestedVersion -eq 'latest') {
        return 'https://github.com/uvwt/agentdock/releases/latest/download'
    }

    $normalizedVersion = $RequestedVersion
    if (-not $normalizedVersion.StartsWith('v')) {
        $normalizedVersion = "v$normalizedVersion"
    }
    return "https://github.com/uvwt/agentdock/releases/download/$normalizedVersion"
}

function Get-CloudflaredReleaseBaseUrl {
    $customBaseUrl = [Environment]::GetEnvironmentVariable('AGENTDOCK_CLOUDFLARED_RELEASE_BASE_URL')
    if (-not [string]::IsNullOrWhiteSpace($customBaseUrl)) {
        return $customBaseUrl.TrimEnd('/')
    }
    return 'https://github.com/cloudflare/cloudflared/releases/latest/download'
}

function Add-UserPath {
    param([string] $Directory)

    $currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathParts = @($currentPath -split ';' | Where-Object { $_ })
    if ($pathParts -notcontains $Directory) {
        $updatedPath = (@($pathParts) + $Directory) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'User')
    }
    if (($env:Path -split ';') -notcontains $Directory) {
        $env:Path = "$env:Path;$Directory"
    }
}

function New-AgentDockSecret {
    param([int] $ByteCount = 32)

    $bytes = New-Object byte[] $ByteCount
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    } finally {
        $generator.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function New-AgentDockToken {
    return New-AgentDockSecret -ByteCount 32
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
    [IO.File]::WriteAllText($Path, [Convert]::ToBase64String($protectedBytes), $Utf8NoBom)
}

function Read-ProtectedText {
    param(
        [string] $Path,
        [string] $Entropy
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    $protectedBytes = [Convert]::FromBase64String([IO.File]::ReadAllText($Path).Trim())
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        [Text.Encoding]::UTF8.GetBytes($Entropy),
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($plainBytes)
}

function Read-TextFile {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    return [IO.File]::ReadAllText($Path).Trim()
}

function Write-TextFile {
    param(
        [string] $Path,
        [string] $Value
    )

    [IO.File]::WriteAllText($Path, $Value, $Utf8NoBom)
}

function Normalize-ServerUrl {
    param([string] $Value)

    $trimmed = $Value.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'A fixed Cloudflare hostname requires an HTTPS public origin.'
    }
    try {
        $uri = [Uri] $trimmed
    } catch {
        throw "Invalid public origin: $Value"
    }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "The public origin must be an absolute HTTPS URL: $Value"
    }
    if ($uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
        throw "The public origin must not contain a path, query, fragment, or user info: $Value"
    }
    return $trimmed
}

function Resolve-TunnelMode {
    param(
        [string] $RequestedMode,
        [string] $ModePath,
        [bool] $StartupRequested,
        [bool] $PublicAccessRequested
    )

    if ($RequestedMode -ne 'auto') {
        return $RequestedMode.ToLowerInvariant()
    }

    $environmentMode = [Environment]::GetEnvironmentVariable('AGENTDOCK_TUNNEL_MODE')
    if (-not [string]::IsNullOrWhiteSpace($environmentMode)) {
        $environmentMode = $environmentMode.Trim().ToLowerInvariant()
        if (@('none', 'quick', 'named') -notcontains $environmentMode) {
            throw "AGENTDOCK_TUNNEL_MODE must be none, quick, or named: $environmentMode"
        }
        return $environmentMode
    }

    $storedMode = Read-TextFile -Path $ModePath
    if (-not [string]::IsNullOrWhiteSpace($storedMode)) {
        $storedMode = $storedMode.ToLowerInvariant()
        if (@('quick', 'named') -contains $storedMode) {
            Write-Host "Reusing public access mode: $storedMode"
            return $storedMode
        }
    }

    if (-not $StartupRequested -or -not $PublicAccessRequested) {
        return 'none'
    }

    Write-Host ''
    Write-Host 'Choose public access:'
    Write-Host '- Have a Cloudflare domain: use a fixed address for long-running clients and OAuth.'
    Write-Host '- No domain: create a temporary address for a quick trial. It changes after cloudflared restarts.'
    $answer = Read-Host 'Do you have a domain already connected to Cloudflare? [y/N]'
    if ($answer -match '^(?i:y|yes)$') {
        return 'named'
    }
    return 'quick'
}

function Read-SecretFile {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Secret file was not found: $Path"
    }
    $value = (Get-Content -LiteralPath $Path -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Secret file is empty: $Path"
    }
    return $value
}

function Write-RuntimeManifest {
    param(
        [string] $Path,
        [string] $AgentDockBinary,
        [string] $TrayBinary,
        [string] $AgentDockLauncher,
        [string] $AgentDockTaskName,
        [string] $PrivilegeMode,
        [string] $CloudflaredLauncher,
        [int] $RuntimePort,
        [string] $RuntimeTunnelMode,
        [string] $RuntimePublicUrl,
        [string] $Channel
    )

    $manifest = [ordered]@{
        schema_version = 1
        agentdock_binary = $AgentDockBinary
        tray_binary = $TrayBinary
        agentdock_launcher = $AgentDockLauncher
        agentdock_task_name = $AgentDockTaskName
        privilege_mode = $PrivilegeMode
        cloudflared_launcher = $CloudflaredLauncher
        host = '127.0.0.1'
        port = $RuntimePort
        local_mcp_url = "http://127.0.0.1:$RuntimePort/mcp"
        tunnel_mode = $RuntimeTunnelMode
        public_url = $RuntimePublicUrl
        install_channel = $Channel
    }
    [IO.File]::WriteAllText($Path, ($manifest | ConvertTo-Json -Depth 3), $Utf8NoBom)
}

function Write-InstallResult {
    param(
        [string] $Path,
        [bool] $Success,
        [string] $Message,
        [string] $InstalledVersion,
        [string] $LocalMCPUrl,
        [string] $PublicMCPUrl,
        [string] $BearerToken,
        [string] $OAuthLoginPassword,
        [string] $HealthStatus,
        [string] $PrivilegeMode
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $safeMessage = $Message.Replace("`r", ' ').Replace("`n", ' ')
    $lines = @(
        '[AgentDock]',
        "Success=$($Success.ToString().ToLowerInvariant())",
        "Message=$safeMessage",
        "Version=$InstalledVersion",
        "LocalMCPUrl=$LocalMCPUrl",
        "PublicMCPUrl=$PublicMCPUrl",
        "BearerToken=$BearerToken",
        "OAuthPassword=$OAuthLoginPassword",
        "Health=$HealthStatus",
        "PrivilegeMode=$PrivilegeMode"
    )
    # Windows INI APIs read BOM-prefixed UTF-16 reliably, including localized errors.
    [IO.File]::WriteAllLines($Path, $lines, [Text.Encoding]::Unicode)
}

function Get-ProcessesByPath {
    param(
        [string] $ProcessName,
        [string] $BinaryPath
    )

    $normalizedBinaryPath = [IO.Path]::GetFullPath($BinaryPath)
    $matchingProcessIds = @()

    # Win32_Process exposes ExecutablePath reliably in installer contexts where
    # Get-Process.Path may be empty even for a process owned by the current user.
    try {
        $matchingProcessIds = @(Get-CimInstance Win32_Process -Filter "Name = '$ProcessName.exe'" -ErrorAction Stop |
            Where-Object {
                $_.ExecutablePath -and
                [string]::Equals(
                    [IO.Path]::GetFullPath($_.ExecutablePath),
                    $normalizedBinaryPath,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } |
            Select-Object -ExpandProperty ProcessId)
    } catch {
        $matchingProcessIds = @()
    }

    if ($matchingProcessIds.Count -eq 0) {
        $matchingProcessIds = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object {
            try {
                [string]::Equals(
                    [IO.Path]::GetFullPath($_.Path),
                    $normalizedBinaryPath,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } catch {
                $false
            }
        } | Select-Object -ExpandProperty Id)
    }

    return @($matchingProcessIds | Sort-Object -Unique | ForEach-Object {
        [pscustomobject]@{ Id = [int] $_ }
    })
}

function Get-AgentDockProcesses {
    param([string] $BinaryPath)
    return @(Get-ProcessesByPath -ProcessName 'agentdock' -BinaryPath $BinaryPath)
}

function Get-CloudflaredProcesses {
    param([string] $BinaryPath)
    return @(Get-ProcessesByPath -ProcessName 'cloudflared' -BinaryPath $BinaryPath)
}

function Get-AgentDockTrayProcesses {
    param([string] $BinaryPath)
    return @(Get-ProcessesByPath -ProcessName 'agentdock-tray' -BinaryPath $BinaryPath)
}

function Test-AgentDockTaskEligible {
    param(
        [string] $AgentDockValueName,
        [string] $CloudflaredValueName,
        [string] $TrayValueName
    )

    return $AgentDockValueName -eq 'AgentDock' -and
        $CloudflaredValueName -eq 'AgentDockCloudflared' -and
        $TrayValueName -eq 'AgentDockTray'
}

function Get-AgentDockTaskState {
    param(
        [string] $AgentDockValueName,
        [string] $CloudflaredValueName,
        [string] $TrayValueName
    )

    $state = [pscustomobject]@{
        Eligible = $false
        Exists = $false
        WasEnabled = $false
        WasRunning = $false
    }
    $state.Eligible = Test-AgentDockTaskEligible `
        -AgentDockValueName $AgentDockValueName `
        -CloudflaredValueName $CloudflaredValueName `
        -TrayValueName $TrayValueName
    if (-not $state.Eligible) {
        return $state
    }

    $task = Get-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return $state
    }
    $state.Exists = $true
    $state.WasEnabled = $task.State -ne 'Disabled'
    $state.WasRunning = $task.State -eq 'Running'
    return $state
}

function Get-CurrentTaskUser {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $groupSids = @($identity.Groups | ForEach-Object { $_.Value })
    return [pscustomobject]@{
        Sid = $identity.User.Value
        Name = $identity.Name
        CanElevate = $groupSids -contains 'S-1-5-32-544'
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-AgentDockTaskBackup {
    param([string] $BackupDirectory)

    New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    $task = Get-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction SilentlyContinue
    $state = [ordered]@{
        Exists = $null -ne $task
        WasEnabled = $false
        WasRunning = $false
    }
    if ($null -ne $task) {
        $state.WasEnabled = $task.State -ne 'Disabled'
        $state.WasRunning = $task.State -eq 'Running'
        [IO.File]::WriteAllText(
            (Join-Path $BackupDirectory 'task.xml'),
            (Export-ScheduledTask -TaskName 'AgentDock' -TaskPath '\'),
            [Text.Encoding]::Unicode
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $BackupDirectory 'state.json'),
        ($state | ConvertTo-Json),
        $Utf8NoBom
    )
}

function Remove-AgentDockScheduledTask {
    $task = Get-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return
    }
    Stop-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction SilentlyContinue | Out-Null
    Unregister-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -Confirm:$false -ErrorAction Stop
}

function Restore-AgentDockTaskBackup {
    param([string] $BackupDirectory)

    $statePath = Join-Path $BackupDirectory 'state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "AgentDock task backup state was not found: $statePath"
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Remove-AgentDockScheduledTask
    if (-not $state.Exists) {
        return
    }

    $xmlPath = Join-Path $BackupDirectory 'task.xml'
    if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
        throw "AgentDock task backup XML was not found: $xmlPath"
    }
    Register-ScheduledTask `
        -TaskName 'AgentDock' `
        -TaskPath '\' `
        -Xml (Get-Content -LiteralPath $xmlPath -Raw) `
        -Force | Out-Null
    if ($state.WasEnabled) {
        Enable-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction Stop | Out-Null
    } else {
        Disable-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction Stop | Out-Null
    }
    if ($state.WasRunning) {
        Start-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction Stop
    }
}

function Set-AgentDockTaskSecurity {
    param([string] $UserSid)

    # The task is created by an elevated helper, but it belongs to the current
    # desktop user. Grant that user full control so the normal tray can start,
    # stop and update its own task without remaining elevated.
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $registeredTask = $scheduler.GetFolder('\').GetTask('AgentDock')
    $taskSecurityDescriptor = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;$UserSid)"
    $registeredTask.SetSecurityDescriptor($taskSecurityDescriptor, 0)
}

function New-ElevatedAgentDockScheduledTask {
    param(
        [string] $LauncherPath,
        [string] $UserSid,
        [string] $UserName
    )

    if ([string]::IsNullOrWhiteSpace($LauncherPath) -or
        [string]::IsNullOrWhiteSpace($UserSid) -or
        [string]::IsNullOrWhiteSpace($UserName)) {
        throw 'Elevated AgentDock task configuration is incomplete.'
    }

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskArguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LauncherPath`""
    $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $taskArguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
    $principal = New-ScheduledTaskPrincipal `
        -UserId $UserSid `
        -LogonType Interactive `
        -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew
    $definition = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'AgentDock privileged core service for the current desktop user.'
    Register-ScheduledTask `
        -TaskName 'AgentDock' `
        -TaskPath '\' `
        -InputObject $definition `
        -Force | Out-Null
    Disable-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction Stop | Out-Null
    Set-AgentDockTaskSecurity -UserSid $UserSid
}

function Invoke-AgentDockTaskAdminAction {
    param(
        [ValidateSet('prepare-elevated', 'prepare-standard', 'restore', 'remove')]
        [string] $Action,
        [string] $BackupDirectory,
        [string] $LauncherPath,
        [string] $UserSid,
        [string] $UserName
    )

    if (-not (Test-IsAdministrator)) {
        throw 'Administrator permission is required for AgentDock task configuration.'
    }
    if ($Action -eq 'remove') {
        Remove-AgentDockScheduledTask
        return
    }
    if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
        throw 'AgentDock task backup directory is required.'
    }
    if ($Action -eq 'restore') {
        Restore-AgentDockTaskBackup -BackupDirectory $BackupDirectory
        return
    }

    Save-AgentDockTaskBackup -BackupDirectory $BackupDirectory
    Remove-AgentDockScheduledTask
    if ($Action -eq 'prepare-elevated') {
        try {
            New-ElevatedAgentDockScheduledTask `
                -LauncherPath $LauncherPath `
                -UserSid $UserSid `
                -UserName $UserName
        } catch {
            try {
                Restore-AgentDockTaskBackup -BackupDirectory $BackupDirectory
            } catch {
                Write-Warning "Unable to restore the previous AgentDock task: $($_.Exception.Message)"
            }
            throw
        }
    }
}

function Start-ElevatedAgentDockTaskAction {
    param(
        [ValidateSet('prepare-elevated', 'prepare-standard', 'restore', 'remove')]
        [string] $Action,
        [string] $BackupDirectory,
        [string] $LauncherPath,
        [pscustomobject] $TaskUser
    )

    $powerShellPath = Join-Path $PSHOME 'powershell.exe'
    $arguments =
        "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`"" +
        " -TaskAdminAction $Action"
    if (-not [string]::IsNullOrWhiteSpace($BackupDirectory)) {
        $arguments += " -TaskBackupDirectory `"$BackupDirectory`""
    }
    if (-not [string]::IsNullOrWhiteSpace($LauncherPath)) {
        $arguments += " -TaskLauncherPath `"$LauncherPath`""
    }
    if ($null -ne $TaskUser) {
        $arguments += " -TaskUserSid `"$($TaskUser.Sid)`" -TaskUserName `"$($TaskUser.Name)`""
    }

    try {
        $process = Start-Process `
            -FilePath $powerShellPath `
            -ArgumentList $arguments `
            -Verb RunAs `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
    } catch {
        throw "Administrator approval for AgentDock was not completed: $($_.Exception.Message)"
    }
    if ($process.ExitCode -ne 0) {
        throw "AgentDock administrator task action failed with exit code $($process.ExitCode)."
    }
}

function Enable-And-StartAgentDockTask {
    Enable-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction Stop
}

function Stop-ProcessesForUpgrade {
    param(
        [string] $ProcessName,
        [string] $BinaryPath
    )

    $processWasRunning = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $runningProcesses = @(Get-ProcessesByPath -ProcessName $ProcessName -BinaryPath $BinaryPath)
        if ($runningProcesses.Count -gt 0) {
            $processWasRunning = $true
        }
        foreach ($process in $runningProcesses) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        if ($runningProcesses.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    $remainingProcesses = @(Get-ProcessesByPath -ProcessName $ProcessName -BinaryPath $BinaryPath)
    if ($remainingProcesses.Count -gt 0) {
        throw "Unable to stop $ProcessName at $BinaryPath."
    }
    return $processWasRunning
}

function Stop-AgentDockForUpgrade {
    param([string] $BinaryPath)
    return Stop-ProcessesForUpgrade -ProcessName 'agentdock' -BinaryPath $BinaryPath
}

function Stop-CloudflaredForUpgrade {
    param([string] $BinaryPath)
    return Stop-ProcessesForUpgrade -ProcessName 'cloudflared' -BinaryPath $BinaryPath
}

function Stop-AgentDockTrayForUpgrade {
    param([string] $BinaryPath)
    return Stop-ProcessesForUpgrade -ProcessName 'agentdock-tray' -BinaryPath $BinaryPath
}

function Start-HiddenPowerShellScript {
    param([string] $ScriptPath)

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Launcher was not found: $ScriptPath"
    }
    $arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Start-AgentDockLauncher {
    param([string] $LauncherPath)
    Start-HiddenPowerShellScript -ScriptPath $LauncherPath
}

function Start-CloudflaredLauncher {
    param([string] $LauncherPath)
    Start-HiddenPowerShellScript -ScriptPath $LauncherPath
}

function Start-AgentDockTray {
    param([string] $BinaryPath)

    if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
        throw "AgentDock tray was not found: $BinaryPath"
    }
    Start-Process -FilePath $BinaryPath -WindowStyle Hidden | Out-Null
}

function Install-AgentDockBinary {
    param(
        [string] $SourceBinary,
        [string] $DestinationBinary
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        try {
            Copy-Item -LiteralPath $SourceBinary -Destination $DestinationBinary -Force
            return
        } catch {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Unable to replace $DestinationBinary after stopping AgentDock: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds 250
        }
    } while ($true)
}

function Test-CloudflaredBinary {
    param([string] $BinaryPath)

    if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
        return $false
    }
    try {
        & $BinaryPath --version | Out-Null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Install-CloudflaredBinary {
    param(
        [string] $DestinationBinary,
        [string] $Architecture,
        [string] $TempDirectory,
        [string] $SourceBinary = ''
    )

    $sourceOverride = $SourceBinary
    if ([string]::IsNullOrWhiteSpace($sourceOverride)) {
        $sourceOverride = [Environment]::GetEnvironmentVariable('AGENTDOCK_CLOUDFLARED_BINARY')
    }
    if (-not [string]::IsNullOrWhiteSpace($sourceOverride)) {
        if (-not (Test-CloudflaredBinary -BinaryPath $sourceOverride)) {
            throw "The supplied cloudflared binary is invalid: $sourceOverride"
        }
        $stagedPath = "$DestinationBinary.tmp.$PID"
        Copy-Item -LiteralPath $sourceOverride -Destination $stagedPath -Force
        Move-Item -LiteralPath $stagedPath -Destination $DestinationBinary -Force
        return
    }

    if (Test-CloudflaredBinary -BinaryPath $DestinationBinary) {
        return
    }

    $assetName = "cloudflared-windows-$Architecture.exe"
    $downloadPath = Join-Path $TempDirectory $assetName
    $downloadUrl = "$(Get-CloudflaredReleaseBaseUrl)/$assetName"
    Write-Host "Downloading cloudflared: $downloadUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $downloadPath
    if (-not (Test-CloudflaredBinary -BinaryPath $downloadPath)) {
        throw "Downloaded cloudflared executable is invalid: $downloadUrl"
    }
    $stagedPath = "$DestinationBinary.tmp.$PID"
    Copy-Item -LiteralPath $downloadPath -Destination $stagedPath -Force
    Move-Item -LiteralPath $stagedPath -Destination $DestinationBinary -Force
}

function Wait-AgentDockHealth {
    param([int] $HealthPort)

    $healthUrl = "http://127.0.0.1:$HealthPort/healthz"
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                return
            }
        } catch {
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "AgentDock was installed, but health check failed at $healthUrl"
}

function Wait-CloudflaredRunning {
    param([string] $BinaryPath)

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        if (@(Get-CloudflaredProcesses -BinaryPath $BinaryPath).Count -gt 0) {
            return
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "cloudflared did not stay running: $BinaryPath"
}

function Wait-QuickTunnelUrl {
    param([string[]] $LogPaths)

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        foreach ($logPath in $LogPaths) {
            try {
                if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                    $content = Get-Content -LiteralPath $logPath -Raw -ErrorAction Stop
                    $match = [Regex]::Match($content, 'https://[A-Za-z0-9-]+\.trycloudflare\.com')
                    if ($match.Success) {
                        return $match.Value
                    }
                }
            } catch {
            }
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "cloudflared started, but no temporary trycloudflare.com URL appeared in: $($LogPaths -join ', ')"
}

function Backup-FileState {
    param(
        [string] $Path,
        [string] $Name,
        [string] $BackupDirectory
    )

    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Managed runtime path must be a regular file: $Path"
        }
        Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupDirectory $Name) -Force
        New-Item -ItemType File -Path (Join-Path $BackupDirectory "$Name.present") -Force | Out-Null
    }
}

function Restore-FileState {
    param(
        [string] $Path,
        [string] $Name,
        [string] $BackupDirectory
    )

    $marker = Join-Path $BackupDirectory "$Name.present"
    $backup = Join-Path $BackupDirectory $Name
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        Copy-Item -LiteralPath $backup -Destination $Path -Force
        return
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Get-RunValue {
    param(
        [string] $RegistryPath,
        [string] $Name
    )

    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return $null
    }
    try {
        return Get-ItemPropertyValue -LiteralPath $RegistryPath -Name $Name -ErrorAction Stop
    } catch {
        return $null
    }
}

if ($TaskAdminAction -ne 'none') {
    Invoke-AgentDockTaskAdminAction `
        -Action $TaskAdminAction `
        -BackupDirectory $TaskBackupDirectory `
        -LauncherPath $TaskLauncherPath `
        -UserSid $TaskUserSid `
        -UserName $TaskUserName
    return
}

if ($Port -lt 1 -or $Port -gt 65535) {
    throw 'Port must be between 1 and 65535.'
}
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    throw 'InstallDir is required.'
}
$userHome = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrWhiteSpace($userHome)) {
    throw 'Unable to resolve the current user profile directory.'
}

$architecture = Get-AgentDockArchitecture
$assetName = "agentdock_windows_$architecture.zip"
$releaseBaseUrl = ''
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("agentdock-install-" + [Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $tempRoot $assetName
$checksumPath = "$archivePath.sha256"
$destinationBinary = Join-Path $InstallDir 'agentdock.exe'
$destinationTrayBinary = Join-Path $InstallDir 'agentdock-tray.exe'
$destinationTrayIcon = Join-Path $InstallDir 'agentdock.ico'
$cloudflaredBinary = Join-Path $InstallDir 'cloudflared.exe'
$binaryBackup = Join-Path $tempRoot 'agentdock.exe.previous'
$trayBackup = Join-Path $tempRoot 'agentdock-tray.exe.previous'
$trayIconBackup = Join-Path $tempRoot 'agentdock.ico.previous'
$cloudflaredBackup = Join-Path $tempRoot 'cloudflared.exe.previous'
$runtimeDir = Split-Path -Parent $InstallDir
$launcherPath = Join-Path $runtimeDir 'start-agentdock.ps1'
$cloudflaredLauncherPath = Join-Path $runtimeDir 'start-cloudflared.ps1'
$tokenPath = Join-Path $runtimeDir 'auth-token.dpapi'
$oauthPasswordPath = Join-Path $runtimeDir 'oauth-password.dpapi'
$oauthTokenSecretPath = Join-Path $runtimeDir 'oauth-token-secret.dpapi'
$serverUrlPath = Join-Path $runtimeDir 'server-url.txt'
$tunnelModePath = Join-Path $runtimeDir 'cloudflared-mode.txt'
$tunnelTokenPath = Join-Path $runtimeDir 'cloudflared-token.dpapi'
$runtimeManifestPath = Join-Path $runtimeDir 'runtime.json'
$cloudflaredStdoutLogPath = Join-Path $runtimeDir 'cloudflared.out.log'
$cloudflaredStderrLogPath = Join-Path $runtimeDir 'cloudflared.err.log'
$runtimeBackupDir = Join-Path $tempRoot 'runtime-backup'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = $StartupValueName
$cloudflaredRunValueName = $CloudflaredStartupValueName
$trayRunValueName = $TrayStartupValueName
$processWasRunning = $false
$trayProcessWasRunning = $false
$cloudflaredProcessWasRunning = $false
$agentDockStopAttempted = $false
$trayStopAttempted = $false
$cloudflaredStopAttempted = $false
$rollbackStateCaptured = $false
$binaryReplacementStarted = $false
$trayReplacementStarted = $false
$cloudflaredReplacementStarted = $false
$startupRegistrationChanged = $false
$trayStartupRegistrationChanged = $false
$tunnelStartupRegistrationChanged = $false
$previousRunValue = $null
$previousTrayRunValue = $null
$previousTunnelRunValue = $null
$taskUser = Get-CurrentTaskUser
$effectivePrivilegeMode = $CorePrivilegeMode
if ($effectivePrivilegeMode -eq 'elevated' -and -not $taskUser.CanElevate) {
    Write-Warning 'The current Windows account is not a local administrator. AgentDock will use standard user mode.'
    $effectivePrivilegeMode = 'standard'
}
$taskState = Get-AgentDockTaskState `
    -AgentDockValueName $runValueName `
    -CloudflaredValueName $cloudflaredRunValueName `
    -TrayValueName $trayRunValueName
if ($effectivePrivilegeMode -eq 'elevated' -and -not $taskState.Eligible) {
    throw 'Elevated AgentDock mode requires the default Windows startup names.'
}
$taskBackupDirectory = Join-Path $tempRoot 'scheduled-task-backup'
$taskTransactionPrepared = $false
$taskTransactionCommitted = $false
$taskRestored = $false
$resolvedTunnelMode = Resolve-TunnelMode -RequestedMode $TunnelMode -ModePath $tunnelModePath -StartupRequested ([bool] $RegisterStartup) -PublicAccessRequested ([bool] $ConfigurePublicAccess)
if ($resolvedTunnelMode -ne 'none' -or (Test-Path -LiteralPath $tunnelModePath -PathType Leaf)) {
    $RegisterStartup = $true
}

$managedRuntimeFiles = @(
    @{ Path = $launcherPath; Name = 'start-agentdock.ps1' },
    @{ Path = $cloudflaredLauncherPath; Name = 'start-cloudflared.ps1' },
    @{ Path = $tokenPath; Name = 'auth-token.dpapi' },
    @{ Path = $oauthPasswordPath; Name = 'oauth-password.dpapi' },
    @{ Path = $oauthTokenSecretPath; Name = 'oauth-token-secret.dpapi' },
    @{ Path = $serverUrlPath; Name = 'server-url.txt' },
    @{ Path = $tunnelModePath; Name = 'cloudflared-mode.txt' },
    @{ Path = $tunnelTokenPath; Name = 'cloudflared-token.dpapi' },
    @{ Path = $runtimeManifestPath; Name = 'runtime.json' }
)

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $runtimeBackupDir -Force | Out-Null
    foreach ($item in $managedRuntimeFiles) {
        Backup-FileState -Path $item.Path -Name $item.Name -BackupDirectory $runtimeBackupDir
    }
    $previousRunValue = Get-RunValue -RegistryPath $runKey -Name $runValueName
    $previousTrayRunValue = Get-RunValue -RegistryPath $runKey -Name $trayRunValueName
    $previousTunnelRunValue = Get-RunValue -RegistryPath $runKey -Name $cloudflaredRunValueName
    $rollbackStateCaptured = $true

    if (-not [string]::IsNullOrWhiteSpace($OfflineArchive)) {
        if (-not (Test-Path -LiteralPath $OfflineArchive -PathType Leaf)) {
            throw "Offline AgentDock archive was not found: $OfflineArchive"
        }
        if ([string]::IsNullOrWhiteSpace($OfflineChecksumFile) -or
            -not (Test-Path -LiteralPath $OfflineChecksumFile -PathType Leaf)) {
            throw "Offline AgentDock checksum file was not found: $OfflineChecksumFile"
        }
        Write-Host "Using bundled AgentDock payload: $OfflineArchive"
        Copy-Item -LiteralPath $OfflineArchive -Destination $archivePath -Force
        Copy-Item -LiteralPath $OfflineChecksumFile -Destination $checksumPath -Force
    } else {
        $releaseBaseUrl = Get-ReleaseBaseUrl -RequestedVersion $Version
        Invoke-WebRequest -UseBasicParsing -Uri "$releaseBaseUrl/$assetName" -OutFile $archivePath
        Invoke-WebRequest -UseBasicParsing -Uri "$releaseBaseUrl/$assetName.sha256" -OutFile $checksumPath
    }

    $expectedHash = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 mismatch for $assetName. Expected $expectedHash, got $actualHash."
    }

    $extractDir = Join-Path $tempRoot 'extract'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force
    $sourceBinary = Join-Path $extractDir 'agentdock.exe'
    if (-not (Test-Path -LiteralPath $sourceBinary -PathType Leaf)) {
        throw "Release archive does not contain agentdock.exe: $assetName"
    }
    $sourceTrayBinary = Join-Path $extractDir 'agentdock-tray.exe'
    $sourceTrayIcon = Join-Path $extractDir 'agentdock.ico'
    if (-not (Test-Path -LiteralPath $sourceTrayBinary -PathType Leaf)) {
        throw "Release archive does not contain agentdock-tray.exe: $assetName"
    }
    if (-not (Test-Path -LiteralPath $sourceTrayIcon -PathType Leaf)) {
        throw "Release archive does not contain agentdock.ico: $assetName"
    }
    $coreSkillBundle = Join-Path $extractDir 'share\agentdock\core-skills'
    $coreSkillManifest = Join-Path $coreSkillBundle 'manifest.json'
    if (-not (Test-Path -LiteralPath $coreSkillBundle -PathType Container) -or
        -not (Test-Path -LiteralPath $coreSkillManifest -PathType Leaf)) {
        throw "Release archive does not contain a valid core Skill Bundle: $assetName"
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $processWasRunning = @(Get-AgentDockProcesses -BinaryPath $destinationBinary).Count -gt 0
    if ($effectivePrivilegeMode -eq 'elevated' -or $taskState.Exists) {
        $taskAction = if ($effectivePrivilegeMode -eq 'elevated') { 'prepare-elevated' } else { 'prepare-standard' }
        if (-not $taskUser.CanElevate) {
            throw 'The existing AgentDock scheduled task requires administrator cleanup, but the current account cannot elevate.'
        }
        Start-ElevatedAgentDockTaskAction `
            -Action $taskAction `
            -BackupDirectory $taskBackupDirectory `
            -LauncherPath $launcherPath `
            -TaskUser $taskUser
        $taskTransactionPrepared = $true
        Write-Host "Prepared AgentDock scheduled task transaction: $taskAction"
    }
    $agentDockStopAttempted = $true
    [void] (Stop-AgentDockForUpgrade -BinaryPath $destinationBinary)
    if (Test-Path -LiteralPath $destinationBinary -PathType Leaf) {
        Copy-Item -LiteralPath $destinationBinary -Destination $binaryBackup -Force
    }

    $binaryReplacementStarted = $true
    Install-AgentDockBinary -SourceBinary $sourceBinary -DestinationBinary $destinationBinary

    $trayProcessWasRunning = @(Get-AgentDockTrayProcesses -BinaryPath $destinationTrayBinary).Count -gt 0
    $trayStopAttempted = $true
    [void] (Stop-AgentDockTrayForUpgrade -BinaryPath $destinationTrayBinary)
    if (Test-Path -LiteralPath $destinationTrayBinary -PathType Leaf) {
        Copy-Item -LiteralPath $destinationTrayBinary -Destination $trayBackup -Force
    }
    if (Test-Path -LiteralPath $destinationTrayIcon -PathType Leaf) {
        Copy-Item -LiteralPath $destinationTrayIcon -Destination $trayIconBackup -Force
    }
    $trayReplacementStarted = $true
    Install-AgentDockBinary -SourceBinary $sourceTrayBinary -DestinationBinary $destinationTrayBinary
    Copy-Item -LiteralPath $sourceTrayIcon -Destination $destinationTrayIcon -Force
    Add-UserPath -Directory $InstallDir

    $agentDockHome = Join-Path $userHome '.agentdock'
    $workspace = Join-Path $userHome 'AgentDock'
    foreach ($directory in @($agentDockHome, $workspace)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $publicUrl = ''
    if ($RegisterStartup) {
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null

        $existingAuthToken = Read-ProtectedText -Path $tokenPath -Entropy 'agentdock.startup.v1'
        if ([string]::IsNullOrWhiteSpace($AuthToken)) {
            $AuthToken = $existingAuthToken
        }
        if ([string]::IsNullOrWhiteSpace($AuthToken)) {
            $AuthToken = New-AgentDockToken
        }
        if (-not [string]::Equals($AuthToken, $existingAuthToken, [StringComparison]::Ordinal)) {
            Write-ProtectedText -Path $tokenPath -Value $AuthToken -Entropy 'agentdock.startup.v1'
        }

        if ($resolvedTunnelMode -ne 'none') {
            $existingOAuthPassword = Read-ProtectedText -Path $oauthPasswordPath -Entropy 'agentdock.oauth.password.v1'
            if ([string]::IsNullOrWhiteSpace($OAuthPassword)) {
                $OAuthPassword = [Environment]::GetEnvironmentVariable('AGENTDOCK_OAUTH_PASSWORD')
            }
            if ([string]::IsNullOrWhiteSpace($OAuthPassword)) {
                $OAuthPassword = $existingOAuthPassword
            }
            if ([string]::IsNullOrWhiteSpace($OAuthPassword)) {
                $OAuthPassword = New-AgentDockSecret -ByteCount 12
            }
            if ($OAuthPassword.Length -lt 12) {
                throw 'OAuth password must contain at least 12 characters.'
            }
            if (-not [string]::Equals($OAuthPassword, $existingOAuthPassword, [StringComparison]::Ordinal)) {
                Write-ProtectedText -Path $oauthPasswordPath -Value $OAuthPassword -Entropy 'agentdock.oauth.password.v1'
            }

            $existingOAuthTokenSecret = Read-ProtectedText -Path $oauthTokenSecretPath -Entropy 'agentdock.oauth.secret.v1'
            if ([string]::IsNullOrWhiteSpace($OAuthTokenSecret)) {
                $OAuthTokenSecret = [Environment]::GetEnvironmentVariable('AGENTDOCK_OAUTH_TOKEN_SECRET')
            }
            if ([string]::IsNullOrWhiteSpace($OAuthTokenSecret)) {
                $OAuthTokenSecret = $existingOAuthTokenSecret
            }
            if ([string]::IsNullOrWhiteSpace($OAuthTokenSecret)) {
                $OAuthTokenSecret = New-AgentDockSecret -ByteCount 32
            }
            if ([Text.Encoding]::UTF8.GetByteCount($OAuthTokenSecret) -lt 32) {
                throw 'OAuth token secret must contain at least 32 bytes.'
            }
            if (-not [string]::Equals($OAuthTokenSecret, $existingOAuthTokenSecret, [StringComparison]::Ordinal)) {
                Write-ProtectedText -Path $oauthTokenSecretPath -Value $OAuthTokenSecret -Entropy 'agentdock.oauth.secret.v1'
            }

            $existingServerUrl = Read-TextFile -Path $serverUrlPath
            if ([string]::IsNullOrWhiteSpace($ServerUrl)) {
                $ServerUrl = [Environment]::GetEnvironmentVariable('AGENTDOCK_SERVER_URL')
            }
            if ([string]::IsNullOrWhiteSpace($ServerUrl)) {
                $ServerUrl = $existingServerUrl
            }
            if ($resolvedTunnelMode -eq 'named') {
                if ([string]::IsNullOrWhiteSpace($ServerUrl)) {
                    $ServerUrl = Read-Host 'Fixed HTTPS public origin, for example https://agent.example.com'
                }
                $ServerUrl = Normalize-ServerUrl -Value $ServerUrl

                $existingTunnelToken = Read-ProtectedText -Path $tunnelTokenPath -Entropy 'agentdock.cloudflare.tunnel.v1'
                if ([string]::IsNullOrWhiteSpace($TunnelToken) -and -not [string]::IsNullOrWhiteSpace($TunnelTokenFile)) {
                    $TunnelToken = Read-SecretFile -Path $TunnelTokenFile
                }
                if ([string]::IsNullOrWhiteSpace($TunnelToken)) {
                    $TunnelToken = [Environment]::GetEnvironmentVariable('AGENTDOCK_CLOUDFLARE_TUNNEL_TOKEN')
                }
                if ([string]::IsNullOrWhiteSpace($TunnelToken)) {
                    $TunnelToken = $existingTunnelToken
                }
                if ([string]::IsNullOrWhiteSpace($TunnelToken)) {
                    $secureTunnelToken = Read-Host 'Cloudflare Tunnel Token' -AsSecureString
                    $credential = New-Object System.Management.Automation.PSCredential('token', $secureTunnelToken)
                    $TunnelToken = $credential.GetNetworkCredential().Password
                }
                if ([string]::IsNullOrWhiteSpace($TunnelToken)) {
                    throw 'A fixed Cloudflare hostname requires a Tunnel Token.'
                }
                if (-not [string]::Equals($TunnelToken, $existingTunnelToken, [StringComparison]::Ordinal)) {
                    Write-ProtectedText -Path $tunnelTokenPath -Value $TunnelToken -Entropy 'agentdock.cloudflare.tunnel.v1'
                }
            }
            Write-TextFile -Path $serverUrlPath -Value $ServerUrl
            Write-TextFile -Path $tunnelModePath -Value $resolvedTunnelMode
        }

        $escapedTokenPath = $tokenPath.Replace("'", "''")
        $escapedOAuthPasswordPath = $oauthPasswordPath.Replace("'", "''")
        $escapedOAuthTokenSecretPath = $oauthTokenSecretPath.Replace("'", "''")
        $escapedServerUrlPath = $serverUrlPath.Replace("'", "''")
        $escapedBinaryPath = $destinationBinary.Replace("'", "''")
        $launcher = @"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
function Read-ProtectedValue {
    param([string] `$Path, [string] `$Entropy)
    `$protectedBytes = [Convert]::FromBase64String([IO.File]::ReadAllText(`$Path).Trim())
    `$plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        `$protectedBytes,
        [Text.Encoding]::UTF8.GetBytes(`$Entropy),
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString(`$plainBytes)
}
`$env:AGENTDOCK_AUTH_TOKEN = Read-ProtectedValue -Path '$escapedTokenPath' -Entropy 'agentdock.startup.v1'
`$env:AGENTDOCK_HOST = '127.0.0.1'
`$env:AGENTDOCK_PORT = '$Port'
`$serverUrl = ''
if (Test-Path -LiteralPath '$escapedServerUrlPath' -PathType Leaf) {
    `$serverUrl = [IO.File]::ReadAllText('$escapedServerUrlPath').Trim()
}
if (-not [string]::IsNullOrWhiteSpace(`$serverUrl) -and
    (Test-Path -LiteralPath '$escapedOAuthPasswordPath' -PathType Leaf) -and
    (Test-Path -LiteralPath '$escapedOAuthTokenSecretPath' -PathType Leaf)) {
    `$env:AGENTDOCK_SERVER_URL = `$serverUrl
    `$env:AGENTDOCK_OAUTH_ENABLED = 'true'
    `$env:AGENTDOCK_OAUTH_PASSWORD = Read-ProtectedValue -Path '$escapedOAuthPasswordPath' -Entropy 'agentdock.oauth.password.v1'
    `$env:AGENTDOCK_OAUTH_TOKEN_SECRET = Read-ProtectedValue -Path '$escapedOAuthTokenSecretPath' -Entropy 'agentdock.oauth.secret.v1'
}
& '$escapedBinaryPath'
"@
        [IO.File]::WriteAllText($launcherPath, $launcher, $Utf8NoBom)

        New-Item -Path $runKey -Force | Out-Null
        if ($effectivePrivilegeMode -eq 'elevated') {
            Remove-ItemProperty -LiteralPath $runKey -Name $runValueName -ErrorAction SilentlyContinue
            Enable-And-StartAgentDockTask
        } else {
            $startupCommand = "powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`""
            New-ItemProperty -Path $runKey -Name $runValueName -Value $startupCommand -PropertyType String -Force | Out-Null
            Start-AgentDockLauncher -LauncherPath $launcherPath
        }
        $startupRegistrationChanged = $true
        $trayStartupCommand = "`"$destinationTrayBinary`""
        New-ItemProperty -Path $runKey -Name $trayRunValueName -Value $trayStartupCommand -PropertyType String -Force | Out-Null
        $trayStartupRegistrationChanged = $true
        Wait-AgentDockHealth -HealthPort $Port

        if ($resolvedTunnelMode -ne 'none') {
            $cloudflaredProcessWasRunning = @(Get-CloudflaredProcesses -BinaryPath $cloudflaredBinary).Count -gt 0
            $cloudflaredStopAttempted = $true
            [void] (Stop-CloudflaredForUpgrade -BinaryPath $cloudflaredBinary)
            if (Test-Path -LiteralPath $cloudflaredBinary -PathType Leaf) {
                Copy-Item -LiteralPath $cloudflaredBinary -Destination $cloudflaredBackup -Force
            }
            $cloudflaredReplacementStarted = $true
            Install-CloudflaredBinary `
                -DestinationBinary $cloudflaredBinary `
                -Architecture $architecture `
                -TempDirectory $tempRoot `
                -SourceBinary $OfflineCloudflaredBinary

            $escapedCloudflaredPath = $cloudflaredBinary.Replace("'", "''")
            $escapedTunnelModePath = $tunnelModePath.Replace("'", "''")
            $escapedTunnelTokenPath = $tunnelTokenPath.Replace("'", "''")
            $escapedCloudflaredStdoutLogPath = $cloudflaredStdoutLogPath.Replace("'", "''")
            $escapedCloudflaredStderrLogPath = $cloudflaredStderrLogPath.Replace("'", "''")
            $tunnelTarget = "http://127.0.0.1:$Port"
            $escapedTunnelTarget = $tunnelTarget.Replace("'", "''")
            $cloudflaredLauncher = @"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
function Read-ProtectedValue {
    param([string] `$Path, [string] `$Entropy)
    `$protectedBytes = [Convert]::FromBase64String([IO.File]::ReadAllText(`$Path).Trim())
    `$plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        `$protectedBytes,
        [Text.Encoding]::UTF8.GetBytes(`$Entropy),
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString(`$plainBytes)
}
`$mode = [IO.File]::ReadAllText('$escapedTunnelModePath').Trim()
`$arguments = @('tunnel', '--no-autoupdate')
if (`$mode -eq 'quick') {
    `$arguments += @('--url', '$escapedTunnelTarget')
}
if (`$mode -eq 'named') {
    `$env:TUNNEL_TOKEN = Read-ProtectedValue -Path '$escapedTunnelTokenPath' -Entropy 'agentdock.cloudflare.tunnel.v1'
    `$arguments += 'run'
}
if (@('quick', 'named') -notcontains `$mode) {
    throw "Unsupported cloudflared mode: `$mode"
}
`$startParameters = @{
    FilePath = '$escapedCloudflaredPath'
    ArgumentList = `$arguments
    WindowStyle = 'Hidden'
    RedirectStandardOutput = '$escapedCloudflaredStdoutLogPath'
    RedirectStandardError = '$escapedCloudflaredStderrLogPath'
    PassThru = `$true
    Wait = `$true
}
`$process = Start-Process @startParameters
exit `$process.ExitCode
"@
            [IO.File]::WriteAllText($cloudflaredLauncherPath, $cloudflaredLauncher, $Utf8NoBom)
            [IO.File]::WriteAllText($cloudflaredStdoutLogPath, '', $Utf8NoBom)
            [IO.File]::WriteAllText($cloudflaredStderrLogPath, '', $Utf8NoBom)

            $cloudflaredStartupCommand = "powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$cloudflaredLauncherPath`""
            New-ItemProperty -Path $runKey -Name $cloudflaredRunValueName -Value $cloudflaredStartupCommand -PropertyType String -Force | Out-Null
            $tunnelStartupRegistrationChanged = $true
            Start-CloudflaredLauncher -LauncherPath $cloudflaredLauncherPath

            if ($resolvedTunnelMode -eq 'quick') {
                $publicUrl = Wait-QuickTunnelUrl -LogPaths @($cloudflaredStdoutLogPath, $cloudflaredStderrLogPath)
                Write-TextFile -Path $serverUrlPath -Value $publicUrl
                if ($effectivePrivilegeMode -eq 'elevated') {
                    Stop-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                    Start-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction Stop
                } else {
                    [void] (Stop-AgentDockForUpgrade -BinaryPath $destinationBinary)
                    Start-AgentDockLauncher -LauncherPath $launcherPath
                }
                Wait-AgentDockHealth -HealthPort $Port
            } else {
                $publicUrl = $ServerUrl
                Wait-CloudflaredRunning -BinaryPath $cloudflaredBinary
            }
        } else {
            $cloudflaredProcessWasRunning = @(Get-CloudflaredProcesses -BinaryPath $cloudflaredBinary).Count -gt 0
            $cloudflaredStopAttempted = $true
            [void] (Stop-CloudflaredForUpgrade -BinaryPath $cloudflaredBinary)
            Remove-ItemProperty -LiteralPath $runKey -Name $cloudflaredRunValueName -ErrorAction SilentlyContinue
            $tunnelStartupRegistrationChanged = $true
            foreach ($path in @($cloudflaredLauncherPath, $tunnelModePath, $tunnelTokenPath, $serverUrlPath, $oauthPasswordPath, $oauthTokenSecretPath)) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $RegisterStartup) {
        Remove-ItemProperty -LiteralPath $runKey -Name $trayRunValueName -ErrorAction SilentlyContinue
        $trayStartupRegistrationChanged = $true
    }

    $mustRestartExistingProcess = (-not $RegisterStartup) -and $processWasRunning -and (Test-Path -LiteralPath $launcherPath -PathType Leaf)
    if ($mustRestartExistingProcess) {
        Start-AgentDockLauncher -LauncherPath $launcherPath
    }

    $localMCPUrl = "http://127.0.0.1:$Port/mcp"
    $publicMCPUrl = ''
    if (-not [string]::IsNullOrWhiteSpace($publicUrl)) {
        $publicMCPUrl = "$publicUrl/mcp"
    }
    Write-RuntimeManifest `
        -Path $runtimeManifestPath `
        -AgentDockBinary $destinationBinary `
        -TrayBinary $destinationTrayBinary `
        -AgentDockLauncher $launcherPath `
        -AgentDockTaskName $(if ($effectivePrivilegeMode -eq 'elevated') { 'AgentDock' } else { '' }) `
        -PrivilegeMode $effectivePrivilegeMode `
        -CloudflaredLauncher $cloudflaredLauncherPath `
        -RuntimePort $Port `
        -RuntimeTunnelMode $resolvedTunnelMode `
        -RuntimePublicUrl $publicUrl `
        -Channel $InstallChannel

    Write-Host 'Installing official core Skills...'
    & $destinationBinary skill bootstrap --bundle $coreSkillBundle
    if ($LASTEXITCODE -ne 0) {
        throw "Core Skill bootstrap failed with exit code $LASTEXITCODE."
    }

    if ($RegisterStartup -or $trayProcessWasRunning) {
        Start-AgentDockTray -BinaryPath $destinationTrayBinary
    }

    $healthStatus = 'not-started'
    if ($RegisterStartup) {
        $healthStatus = 'healthy'
    }
    Write-InstallResult `
        -Path $ResultFile `
        -Success $true `
        -Message 'AgentDock installation completed.' `
        -InstalledVersion $Version `
        -LocalMCPUrl $localMCPUrl `
        -PublicMCPUrl $publicMCPUrl `
        -BearerToken $AuthToken `
        -OAuthLoginPassword $OAuthPassword `
        -HealthStatus $healthStatus `
        -PrivilegeMode $effectivePrivilegeMode

    $taskTransactionCommitted = $taskTransactionPrepared

    Write-Host "AgentDock installed: $destinationBinary"
    Write-Host "Local MCP address: $localMCPUrl"
    Write-Host 'Open a new terminal if the updated user PATH is not visible yet.'
    if ($RegisterStartup) {
        Write-Host "Bearer Token: $AuthToken"
    }
    if ($resolvedTunnelMode -ne 'none') {
        Write-Host ''
        Write-Host 'AgentDock public installation complete'
        Write-Host "Public mode: $resolvedTunnelMode"
        Write-Host "Public address: $publicUrl"
        Write-Host "MCP address: $publicUrl/mcp"
        Write-Host "Bearer Token: $AuthToken"
        Write-Host "OAuth login password: $OAuthPassword"
        Write-Host 'Authentication: Bearer Token and OAuth are both enabled.'
        Write-Host "cloudflared stdout log: $cloudflaredStdoutLogPath"
        Write-Host "cloudflared stderr log: $cloudflaredStderrLogPath"
        if ($resolvedTunnelMode -eq 'quick') {
            Write-Host 'The temporary address changes after cloudflared restarts.'
            Write-Host 'Run the same installer command again to refresh the address; credentials are preserved.'
            Write-Host 'Then replace the MCP URL in the client and complete OAuth again.'
        } else {
            Write-Host "Cloudflare Public Hostname service target: http://127.0.0.1:$Port"
        }
    }
} catch {
    $installError = $_
    try {
        if ($trayStopAttempted -or $trayReplacementStarted -or $trayStartupRegistrationChanged) {
            [void] (Stop-AgentDockTrayForUpgrade -BinaryPath $destinationTrayBinary)
        }
        if ($cloudflaredStopAttempted -or $cloudflaredReplacementStarted -or $tunnelStartupRegistrationChanged) {
            [void] (Stop-CloudflaredForUpgrade -BinaryPath $cloudflaredBinary)
        }
        if ($effectivePrivilegeMode -eq 'elevated') {
            Stop-ScheduledTask -TaskName 'AgentDock' -TaskPath '\' -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
        if ($agentDockStopAttempted -or $binaryReplacementStarted -or $startupRegistrationChanged) {
            [void] (Stop-AgentDockForUpgrade -BinaryPath $destinationBinary)
        }

        if ($cloudflaredReplacementStarted) {
            $cloudflaredBackupExists = Test-Path -LiteralPath $cloudflaredBackup -PathType Leaf
            if ($cloudflaredBackupExists) {
                Copy-Item -LiteralPath $cloudflaredBackup -Destination $cloudflaredBinary -Force
            }
            if (-not $cloudflaredBackupExists) {
                Remove-Item -LiteralPath $cloudflaredBinary -Force -ErrorAction SilentlyContinue
            }
        }

        if ($trayReplacementStarted) {
            $trayBackupExists = Test-Path -LiteralPath $trayBackup -PathType Leaf
            if ($trayBackupExists) {
                Copy-Item -LiteralPath $trayBackup -Destination $destinationTrayBinary -Force
            }
            if (-not $trayBackupExists) {
                Remove-Item -LiteralPath $destinationTrayBinary -Force -ErrorAction SilentlyContinue
            }
            $trayIconBackupExists = Test-Path -LiteralPath $trayIconBackup -PathType Leaf
            if ($trayIconBackupExists) {
                Copy-Item -LiteralPath $trayIconBackup -Destination $destinationTrayIcon -Force
            }
            if (-not $trayIconBackupExists) {
                Remove-Item -LiteralPath $destinationTrayIcon -Force -ErrorAction SilentlyContinue
            }
        }

        if ($binaryReplacementStarted) {
            $backupExists = Test-Path -LiteralPath $binaryBackup -PathType Leaf
            if ($backupExists) {
                Copy-Item -LiteralPath $binaryBackup -Destination $destinationBinary -Force
            }
            if (-not $backupExists) {
                Remove-Item -LiteralPath $destinationBinary -Force -ErrorAction SilentlyContinue
            }
        }

        if ($rollbackStateCaptured) {
            foreach ($item in $managedRuntimeFiles) {
                Restore-FileState -Path $item.Path -Name $item.Name -BackupDirectory $runtimeBackupDir
            }

            New-Item -Path $runKey -Force | Out-Null
            if ($null -ne $previousRunValue) {
                New-ItemProperty -Path $runKey -Name $runValueName -Value $previousRunValue -PropertyType String -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $runKey -Name $runValueName -ErrorAction SilentlyContinue
            }
            if ($null -ne $previousTrayRunValue) {
                New-ItemProperty -Path $runKey -Name $trayRunValueName -Value $previousTrayRunValue -PropertyType String -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $runKey -Name $trayRunValueName -ErrorAction SilentlyContinue
            }
            if ($null -ne $previousTunnelRunValue) {
                New-ItemProperty -Path $runKey -Name $cloudflaredRunValueName -Value $previousTunnelRunValue -PropertyType String -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $runKey -Name $cloudflaredRunValueName -ErrorAction SilentlyContinue
            }
        }

        if ($taskTransactionPrepared -and -not $taskTransactionCommitted) {
            Start-ElevatedAgentDockTaskAction `
                -Action restore `
                -BackupDirectory $taskBackupDirectory `
                -LauncherPath '' `
                -TaskUser $taskUser
            $taskRestored = $true
        }

        $taskWillRestartAgentDock = $taskRestored -and $taskState.WasRunning
        if ($processWasRunning -and -not $taskWillRestartAgentDock -and
            (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
            Start-AgentDockLauncher -LauncherPath $launcherPath
        }
        if ($cloudflaredProcessWasRunning -and (Test-Path -LiteralPath $cloudflaredLauncherPath -PathType Leaf)) {
            Start-CloudflaredLauncher -LauncherPath $cloudflaredLauncherPath
        }
        if ($trayProcessWasRunning -and (Test-Path -LiteralPath $destinationTrayBinary -PathType Leaf)) {
            Start-AgentDockTray -BinaryPath $destinationTrayBinary
        }
    } catch {
        Write-Warning "AgentDock rollback failed: $($_.Exception.Message)"
    }
    Write-InstallResult `
        -Path $ResultFile `
        -Success $false `
        -Message $installError.Exception.Message `
        -InstalledVersion $Version `
        -LocalMCPUrl "http://127.0.0.1:$Port/mcp" `
        -PublicMCPUrl '' `
        -BearerToken '' `
        -OAuthLoginPassword '' `
        -HealthStatus 'failed' `
        -PrivilegeMode $effectivePrivilegeMode
    throw $installError
} finally {
    if ($DeleteTunnelTokenFile -and -not [string]::IsNullOrWhiteSpace($TunnelTokenFile)) {
        Remove-Item -LiteralPath $TunnelTokenFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
