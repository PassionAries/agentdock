[CmdletBinding()]
param(
    [string] $InstallerPath = (Join-Path $PSScriptRoot 'install.ps1'),
    [string] $ManagerPath = (Join-Path $PSScriptRoot 'manage-windows.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    '$sddl'
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
    'New-ElevatedAgentDockScheduledTask',
    'New-ScheduledTaskPrincipal',
    '-RunLevel Highest',
    'Set-AgentDockTaskSecurity',
    'Start-ElevatedAgentDockTaskAction',
    'Restore-AgentDockTaskBackup',
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
function Start-Process {
    param(
        [string] $FilePath,
        [string] $ArgumentList,
        [string] $Verb,
        [string] $WindowStyle,
        [switch] $Wait,
        [switch] $PassThru
    )

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
    -LauncherPath 'C:\AgentDock\agentdock.exe' `
    -RuntimeRoot 'C:\AgentDock' `
    -TaskUser $taskUser
if ($result.Started -ne $false -or $result.ErrorMessage -notlike '*simulated RunAs rejection*') {
    throw "RunAs pre-start rejection was not returned as a recoverable result: $($result | Out-String)"
}

$script:mockStartProcessMode = 'helper-error'
$helperError = ''
try {
    [void] (Start-ElevatedAgentDockTaskAction `
        -Action prepare-elevated `
        -BackupDirectory 'C:\Temp\AgentDockBackup' `
        -LauncherPath 'C:\AgentDock\agentdock.exe' `
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
