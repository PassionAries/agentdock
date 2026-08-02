[CmdletBinding()]
param(
    [string] $InstallerPath = '',
    [string] $Version = 'latest',
    [string] $ReleaseBaseUrl = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $InstallerPath) {
    $InstallerPath = Join-Path $PSScriptRoot 'install.ps1'
}
$resolvedInstaller = Resolve-Path -LiteralPath $InstallerPath

$userName = 'adocke2e' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$passwordText = 'AgentDock-E2E-' + [Guid]::NewGuid().ToString('N') + 'Aa1!'
$password = ConvertTo-SecureString $passwordText -AsPlainText -Force
$credential = [PSCredential]::new(".\$userName", $password)
$testScriptDir = Join-Path $env:PUBLIC ('agentdock-installer-e2e-' + [Guid]::NewGuid().ToString('N'))
$stdoutPath = Join-Path $env:RUNNER_TEMP 'agentdock-installer-e2e.stdout.log'
$stderrPath = Join-Path $env:RUNNER_TEMP 'agentdock-installer-e2e.stderr.log'
$contextResultPath = Join-Path $env:PUBLIC ('agentdock-setup-context-' + [Guid]::NewGuid().ToString('N') + '.ini')
$contextInstallDir = Join-Path $env:PUBLIC ('agentdock-setup-context-' + [Guid]::NewGuid().ToString('N') + '\bin')
$contextStdoutPath = Join-Path $env:RUNNER_TEMP 'agentdock-setup-context.stdout.log'
$contextStderrPath = Join-Path $env:RUNNER_TEMP 'agentdock-setup-context.stderr.log'

try {
    New-LocalUser `
        -Name $userName `
        -Password $password `
        -PasswordNeverExpires `
        -UserMayNotChangePassword | Out-Null

    # New-LocalUser 默认只创建普通本地账户；子进程还会再次验证自身不是管理员。
    New-Item -ItemType Directory -Path $testScriptDir -Force | Out-Null
    Copy-Item -LiteralPath $resolvedInstaller -Destination (Join-Path $testScriptDir 'install.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'test-install-windows-e2e.ps1') -Destination $testScriptDir -Force

    $testScript = Join-Path $testScriptDir 'test-install-windows-e2e.ps1'
    $installerScript = Join-Path $testScriptDir 'install.ps1'
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$testScript`" -InstallerPath `"$installerScript`" -Version $Version"
    if ($ReleaseBaseUrl) {
        $arguments += " -ReleaseBaseUrl `"$ReleaseBaseUrl`""
    }
    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -Credential $credential `
        -LoadUserProfile `
        -WorkingDirectory $env:SystemRoot `
        -ArgumentList $arguments `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -Wait `
        -PassThru

    if (Test-Path -LiteralPath $stdoutPath) {
        Get-Content -LiteralPath $stdoutPath
    }
    if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -LiteralPath $stderrPath | Write-Host
    }
    if ($process.ExitCode -ne 0) {
        throw "Windows installer E2E failed as standard user with exit code $($process.ExitCode)."
    }

    # Setup must never continue when an over-the-shoulder administrator or any
    # other account owns the process instead of the signed-in desktop user.
    $contextArguments =
        "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installerScript`"" +
        " -InstallChannel setup -InstallDir `"$contextInstallDir`"" +
        " -ResultFile `"$contextResultPath`""
    $contextProcess = Start-Process `
        -FilePath 'powershell.exe' `
        -Credential $credential `
        -LoadUserProfile `
        -WorkingDirectory $env:SystemRoot `
        -ArgumentList $contextArguments `
        -RedirectStandardOutput $contextStdoutPath `
        -RedirectStandardError $contextStderrPath `
        -Wait `
        -PassThru

    if ($contextProcess.ExitCode -eq 0) {
        throw 'Setup user-context guard unexpectedly allowed a different process user.'
    }
    if (-not (Test-Path -LiteralPath $contextResultPath -PathType Leaf)) {
        throw 'Setup user-context guard did not write its structured result.'
    }
    $contextCode = Get-Content -LiteralPath $contextResultPath |
        Where-Object { $_ -like 'Code=*' } |
        Select-Object -First 1
    if ($contextCode -ne 'Code=setup-elevated-context') {
        throw "Unexpected Setup user-context result: $contextCode"
    }
    if (Test-Path -LiteralPath $contextInstallDir) {
        throw 'Setup user-context guard wrote installation files before rejecting the wrong account.'
    }
    Write-Host 'AgentDock Setup user-context guard passed.'
}
finally {
    Remove-LocalUser -Name $userName -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testScriptDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stdoutPath, $stderrPath, $contextResultPath, $contextStdoutPath, $contextStderrPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Split-Path -Parent $contextInstallDir) -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'AgentDock Windows standard-user E2E passed.'
