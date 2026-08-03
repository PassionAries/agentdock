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
[System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedInstaller,
    [ref] $tokens,
    [ref] $errors
) | Out-Null
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

Write-Host 'Windows installer validation passed.'
