[CmdletBinding()]
param(
    [string] $InstallerPath = '',
    [string] $ManagerPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $InstallerPath = Join-Path $PSScriptRoot 'install.ps1'
}
if ([string]::IsNullOrWhiteSpace($ManagerPath)) {
    $ManagerPath = Join-Path $PSScriptRoot 'manage-windows.ps1'
}

$resolvedInstaller = Resolve-Path -LiteralPath $InstallerPath
$tokens = $null
$errors = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedInstaller,
    [ref] $tokens,
    [ref] $errors
)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw "$InstallerPath contains PowerShell syntax errors"
}

$resolvedManager = Resolve-Path -LiteralPath $ManagerPath
$managerTokens = $null
$managerErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedManager,
    [ref] $managerTokens,
    [ref] $managerErrors
) | Out-Null
if ($managerErrors.Count -gt 0) {
    $managerErrors | ForEach-Object { Write-Error $_.Message }
    throw "$ManagerPath contains PowerShell syntax errors"
}
$managerBytes = [IO.File]::ReadAllBytes($resolvedManager)
if ($managerBytes.Length -lt 3 -or
    $managerBytes[0] -ne 0xEF -or
    $managerBytes[1] -ne 0xBB -or
    $managerBytes[2] -ne 0xBF) {
    throw "$ManagerPath must use UTF-8 with BOM for Windows PowerShell 5.1"
}

$content = Get-Content -LiteralPath $resolvedInstaller -Raw
$bytes = [IO.File]::ReadAllBytes($resolvedInstaller)
for ($index = 0; $index -lt $bytes.Length; $index++) {
    if ($bytes[$index] -gt 127) {
        throw "$InstallerPath must remain ASCII for Windows PowerShell 5.1; non-ASCII byte at offset $index"
    }
}
foreach ($line in ($content -split "`n")) {
    $trimmed = $line.Trim()
    foreach ($keyword in @('else', 'elseif', 'catch', 'finally')) {
        if ($trimmed -eq $keyword -or $trimmed.StartsWith("$keyword ")) {
            throw "$InstallerPath must keep $keyword on the same line as the preceding closing brace: $line"
        }
    }
}

foreach ($forbidden in @(
    'Set-PrivateAcl',
    'Get-Acl',
    'Set-Acl',
    'icacls.exe',
    '$icaclsArguments',
    '$AclSelfTest',
    '$sddl',
    'CanElevate',
    'Invoke-AgentDockTaskAdminAction',
    'New-ElevatedAgentDockScheduledTask',
    '--installer-admin-action',
    '-TaskAdminAction'
)) {
    if ($content.Contains($forbidden)) {
        throw "$InstallerPath still contains removed privileged startup or ACL code: $forbidden"
    }
}
if ($content.Contains('current account cannot elevate')) {
    throw "$InstallerPath must request UAC for old scheduled-task cleanup instead of rejecting a standard user early"
}

foreach ($required in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'Get-AgentDockTaskState',
    'Get-InteractiveDesktopUser',
    'Start-ElevatedAgentDockTaskAction',
    '--task-admin $Action',
    '--backup-directory',
    '--launcher-path',
    '--runtime-root',
    '--user-sid',
    '--user-name',
    '-AdminLauncherPath $sourceTrayBinary',
    '-LauncherPath $destinationTrayBinary',
    '$effectivePrivilegeMode -eq ''elevated'' -and -not $taskState.Exists',
    '$installWarningCode = ''elevated-mode-fallback''',
    'WarningCode=$WarningCode',
    '-WarningCode $installWarningCode',
    'Administrator approval for AgentDock rollback was not completed',
    'setup-elevated-context',
    'Start Setup normally under the signed-in account',
    'New-ItemProperty -Path $runKey -Name $runValueName',
    'New-ItemProperty -Path $runKey -Name $cloudflaredRunValueName',
    'Start-AgentDockLauncher -LauncherPath $launcherPath',
    'Start-CloudflaredLauncher -LauncherPath $cloudflaredLauncherPath',
    'Release archive does not contain manage-windows.ps1',
    'Initialize-OAuthCredentials',
    'named-server-url.txt',
    'cloudflared-windows-$Architecture.exe',
    'Wait-QuickTunnelUrl -LogPaths @($cloudflaredStdoutLogPath, $cloudflaredStderrLogPath)',
    'Wait-QuickTunnelReady -Path $quickTunnelUrlPath -ExpectedUrl $publicUrl',
    'quick-tunnel-url.txt',
    'Restart-AgentDockForQuickTunnel',
    'Update-RuntimePublicUrl -PublicUrl `$publicUrl',
    'Write-TextAtomically -Path ''$escapedServerUrlPath'' -Value `$publicUrl',
    'Write-TextAtomically -Path ''$escapedQuickTunnelUrlPath'' -Value `$publicUrl',
    'RedirectStandardOutput = ''$escapedCloudflaredStdoutLogPath''',
    'RedirectStandardError = ''$escapedCloudflaredStderrLogPath''',
    'Write-ProtectedText -Path $PasswordPath',
    'Write-ProtectedText -Path $TokenSecretPath',
    'Write-ProtectedText -Path $tunnelTokenPath',
    'Authentication: Bearer Token and OAuth are both enabled.',
    '$coreSkillOutput = @(& $destinationBinary skill bootstrap --bundle $coreSkillBundle 2>&1)',
    '-ErrorCode $installErrorCode',
    "GetEnvironmentVariable('AGENTDOCK_RELEASE_BASE_URL')"
)) {
    if (-not $content.Contains($required)) {
        throw "$InstallerPath is missing current-user startup logic: $required"
    }
}

$currentTaskUserFunction = $installerAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-CurrentTaskUser'
}, $true)
if ($null -eq $currentTaskUserFunction) {
    throw "$InstallerPath does not define Get-CurrentTaskUser"
}
$identityProbeAssertions = @'
$taskUser = Get-CurrentTaskUser
if ($taskUser.PSObject.Properties.Name -contains 'CanElevate') {
    throw 'Get-CurrentTaskUser must not pre-classify a filtered UAC token as unable to elevate'
}
if ([string]::IsNullOrWhiteSpace($taskUser.Sid) -or [string]::IsNullOrWhiteSpace($taskUser.Name)) {
    throw 'Get-CurrentTaskUser must return the signed-in Windows SID and name'
}
'@
$identityProbe = [scriptblock]::Create(
    $currentTaskUserFunction.Extent.Text + "`r`n" + $identityProbeAssertions
)
& $identityProbe

$elevationFunction = $installerAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Start-ElevatedAgentDockTaskAction'
}, $true)
if ($null -eq $elevationFunction) {
    throw "$InstallerPath does not define Start-ElevatedAgentDockTaskAction"
}

$elevationProbePreamble = @'
$script:mockStartProcessMode = 'reject'
$script:mockStartProcessFilePath = ''
$script:mockStartProcessArguments = ''
function Start-Process {
    param(
        [string] $FilePath,
        [string] $ArgumentList,
        [string] $Verb,
        [string] $WindowStyle,
        [switch] $Wait,
        [switch] $PassThru
    )

    $script:mockStartProcessFilePath = $FilePath
    $script:mockStartProcessArguments = $ArgumentList
    if ($script:mockStartProcessMode -eq 'reject') {
        throw 'simulated RunAs rejection'
    }
    return [pscustomobject]@{ ExitCode = 23 }
}
'@
$elevationProbeAssertions = @'
$taskUser = [pscustomobject]@{
    Sid = 'S-1-5-21-test'
    Name = 'TEST\AgentDock'
}
$result = Start-ElevatedAgentDockTaskAction `
    -Action prepare-elevated `
    -BackupDirectory 'C:\Temp\AgentDockBackup' `
    -AdminLauncherPath 'C:\AgentDock\agentdock-tray.exe' `
    -LauncherPath 'C:\AgentDock\agentdock-tray.exe' `
    -RuntimeRoot 'C:\AgentDock' `
    -TaskUser $taskUser
if ($result.Started -ne $false -or $result.ErrorMessage -notlike '*simulated RunAs rejection*') {
    throw "RunAs pre-start rejection was not returned as a recoverable result: $($result | Out-String)"
}
if ($script:mockStartProcessFilePath -notlike '*agentdock-tray.exe' -or
    $script:mockStartProcessArguments -notlike '*--task-admin prepare-elevated*' -or
    $script:mockStartProcessArguments -like '*--script*') {
    throw "UAC must elevate the fixed AgentDock task helper instead of PowerShell: $script:mockStartProcessFilePath $script:mockStartProcessArguments"
}

$script:mockStartProcessMode = 'helper-error'
$helperError = ''
try {
    [void] (Start-ElevatedAgentDockTaskAction `
        -Action prepare-elevated `
        -BackupDirectory 'C:\Temp\AgentDockBackup' `
        -AdminLauncherPath 'C:\AgentDock\agentdock-tray.exe' `
        -LauncherPath 'C:\AgentDock\agentdock-tray.exe' `
        -RuntimeRoot 'C:\AgentDock' `
        -TaskUser $taskUser)
} catch {
    $helperError = $_.Exception.Message
}
if ($helperError -notlike '*administrator task action failed with exit code 23*') {
    throw "Elevated helper failure must remain fatal, actual error: $helperError"
}
'@
$elevationProbe = [scriptblock]::Create(
    $elevationProbePreamble + "`r`n" + $elevationFunction.Extent.Text + "`r`n" + $elevationProbeAssertions
)
& $elevationProbe

$repoRoot = Split-Path -Parent $PSScriptRoot
$taskAdminSourcePath = Join-Path $repoRoot 'desktop\windows\control-panel\Services\TaskAdminService.cs'
$appSourcePath = Join-Path $repoRoot 'desktop\windows\control-panel\App.xaml.cs'
$runtimeSourcePath = Join-Path $repoRoot 'desktop\windows\control-panel\Services\RuntimeService.cs'
$taskAdminSource = Get-Content -LiteralPath $taskAdminSourcePath -Raw
$appSource = Get-Content -LiteralPath $appSourcePath -Raw
$runtimeSource = Get-Content -LiteralPath $runtimeSourcePath -Raw
foreach ($required in @(
    'Type.GetTypeFromProgID("Schedule.Service")',
    'EnsureSameWindowsUser(request.UserSid)',
    'RegisterTaskDefinition(',
    'SetSecurityDescriptor(',
    '--run-core-task --runtime-root',
    'prepare-elevated',
    'prepare-standard',
    'restore',
    'remove',
    'set-enabled'
)) {
    if (-not $taskAdminSource.Contains($required)) {
        throw "$taskAdminSourcePath is missing native task administration behavior: $required"
    }
}
foreach ($required in @('--task-admin', 'TaskAdminService.Run(e.Args)', '--run-core-task')) {
    if (-not $appSource.Contains($required)) {
        throw "$appSourcePath is missing AgentDock background helper behavior: $required"
    }
}
foreach ($required in @('RunElevatedCoreTaskAsync', 'CreateNoWindow = true', 'WindowStyle = ProcessWindowStyle.Hidden', 'service', 'launch-core')) {
    if (-not $runtimeSource.Contains($required)) {
        throw "$runtimeSourcePath is missing no-console elevated core behavior: $required"
    }
}
foreach ($forbidden in @('--installer-admin-action', '--script', 'powershell.exe')) {
    if ($taskAdminSource.Contains($forbidden) -or $appSource.Contains($forbidden)) {
        throw "AgentDock elevated helper must not expose arbitrary PowerShell execution: $forbidden"
    }
}

$setupCodePath = Join-Path $repoRoot 'packaging\windows\includes\code.iss'
$setupMessagesPath = Join-Path $repoRoot 'packaging\windows\includes\messages.iss'
$setupCode = Get-Content -LiteralPath $setupCodePath -Raw
$setupMessages = Get-Content -LiteralPath $setupMessagesPath -Raw
foreach ($required in @(
    "GetIniString('AgentDock', 'WarningCode', '', ResultFilePath)",
    "InstallWarningCode = 'elevated-mode-fallback'",
    "GetLocalizedMessage('ElevatedModeFallbackNotice')"
)) {
    if (-not $setupCode.Contains($required)) {
        throw "$setupCodePath is missing elevation fallback presentation: $required"
    }
}
foreach ($required in @(
    'english.ElevatedModeFallbackNotice=',
    'chinesesimplified.ElevatedModeFallbackNotice='
)) {
    if (-not $setupMessages.Contains($required)) {
        throw "$setupMessagesPath is missing elevation fallback message: $required"
    }
}

Write-Host 'Windows installer validation passed.'
