[CmdletBinding()]
param(
    [string] $InstallerPath = (Join-Path $PSScriptRoot 'install.ps1')
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

foreach ($required in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'Get-AgentDockTaskState',
    'New-ElevatedAgentDockScheduledTask',
    'New-ScheduledTaskPrincipal',
    '-RunLevel Highest',
    'Set-AgentDockTaskSecurity',
    'Start-ElevatedAgentDockTaskAction',
    'Restore-AgentDockTaskBackup',
    'New-ItemProperty -Path $runKey -Name $runValueName',
    'New-ItemProperty -Path $runKey -Name $cloudflaredRunValueName',
    'Start-AgentDockLauncher -LauncherPath $launcherPath',
    'Start-CloudflaredLauncher -LauncherPath $cloudflaredLauncherPath',
    'cloudflared-windows-$Architecture.exe',
    'Wait-QuickTunnelUrl -LogPaths @($cloudflaredStdoutLogPath, $cloudflaredStderrLogPath)',
    'RedirectStandardOutput = ''$escapedCloudflaredStdoutLogPath''',
    'RedirectStandardError = ''$escapedCloudflaredStderrLogPath''',
    'Write-ProtectedText -Path $oauthPasswordPath',
    'Write-ProtectedText -Path $oauthTokenSecretPath',
    'Write-ProtectedText -Path $tunnelTokenPath',
    'Authentication: Bearer Token and OAuth are both enabled.',
    '& $destinationBinary skill bootstrap --bundle $coreSkillBundle',
    "GetEnvironmentVariable('AGENTDOCK_RELEASE_BASE_URL')"
)) {
    if (-not $content.Contains($required)) {
        throw "$InstallerPath is missing current-user startup logic: $required"
    }
}

Write-Host 'Windows installer validation passed.'
