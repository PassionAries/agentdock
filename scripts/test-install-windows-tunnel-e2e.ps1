[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $InstallerUrl,
    [Parameter(Mandatory = $true)]
    [string] $UninstallerUrl,
    [Parameter(Mandatory = $true)]
    [string] $ReleaseZipUrl,
    [Parameter(Mandatory = $true)]
    [string] $CloudflaredUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([Net.IPEndPoint] $listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Get-RunValue {
    param([string] $RegistryPath, [string] $Name)
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return $null
    }
    try {
        return Get-ItemPropertyValue -LiteralPath $RegistryPath -Name $Name -ErrorAction Stop
    } catch {
        return $null
    }
}

function Restore-RunValue {
    param([string] $RegistryPath, [string] $Name, $Value)
    New-Item -Path $RegistryPath -Force | Out-Null
    if ($null -eq $Value) {
        Remove-ItemProperty -LiteralPath $RegistryPath -Name $Name -ErrorAction SilentlyContinue
    } else {
        New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType String -Force | Out-Null
    }
}

function Stop-ProcessByPath {
    param([string] $ProcessName, [string] $BinaryPath)
    $normalizedPath = [IO.Path]::GetFullPath($BinaryPath)
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object {
        try {
            [string]::Equals(
                [IO.Path]::GetFullPath($_.Path),
                $normalizedPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        } catch {
            $false
        }
    } | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Read-DpapiText {
    param([string] $Path, [string] $Entropy)
    Add-Type -AssemblyName System.Security
    $protectedBytes = [Convert]::FromBase64String([IO.File]::ReadAllText($Path).Trim())
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        [Text.Encoding]::UTF8.GetBytes($Entropy),
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($plainBytes)
}

function Assert-File {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing expected file: $Path"
    }
}

$testId = [Guid]::NewGuid().ToString('N')
$root = Join-Path ([IO.Path]::GetTempPath()) ("agentdock-win-tunnel-e2e-$testId")
$runValueName = "AgentDockTunnelE2E-$testId"
$cloudflaredRunValueName = "AgentDockCloudflaredTunnelE2E-$testId"
$releaseDir = Join-Path $root 'release'
$installDir = Join-Path $root 'AgentDock\bin'
$runtimeDir = Split-Path -Parent $installDir
$installer = Join-Path $root 'install.ps1'
$uninstaller = Join-Path $root 'uninstall-windows.ps1'
$fakeCloudflared = Join-Path $root 'fake-cloudflared.exe'
$releaseZip = Join-Path $releaseDir 'agentdock_windows_amd64.zip'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$userHome = [Environment]::GetFolderPath('UserProfile')
$stateDir = Join-Path $userHome '.agentdock'
$workDir = Join-Path $userHome 'AgentDock'
$stateExisted = Test-Path -LiteralPath $stateDir
$workExisted = Test-Path -LiteralPath $workDir
$oldUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$oldAgentDockRun = Get-RunValue -RegistryPath $runKey -Name $runValueName
$oldCloudflaredRun = Get-RunValue -RegistryPath $runKey -Name $cloudflaredRunValueName
$realAgentDockRun = Get-RunValue -RegistryPath $runKey -Name 'AgentDock'
$realCloudflaredRun = Get-RunValue -RegistryPath $runKey -Name 'AgentDockCloudflared'
$httpServer = $null

try {
    New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri $InstallerUrl -OutFile $installer
    Invoke-WebRequest -UseBasicParsing -Uri $UninstallerUrl -OutFile $uninstaller
    Invoke-WebRequest -UseBasicParsing -Uri $ReleaseZipUrl -OutFile $releaseZip
    Invoke-WebRequest -UseBasicParsing -Uri $CloudflaredUrl -OutFile $fakeCloudflared

    $zipHash = (Get-FileHash -LiteralPath $releaseZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumText = "$zipHash  agentdock_windows_amd64.zip`n"
    [IO.File]::WriteAllText("$releaseZip.sha256", $checksumText, (New-Object System.Text.UTF8Encoding($false)))

    $python = (Get-Command python -ErrorAction Stop).Source
    $httpPort = Get-FreeTcpPort
    $httpServer = Start-Process -FilePath $python `
        -ArgumentList @('-m', 'http.server', "$httpPort", '--bind', '127.0.0.1') `
        -WorkingDirectory $releaseDir -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 700
    $probe = [Net.Sockets.TcpClient]::new()
    try {
        $probe.Connect('127.0.0.1', $httpPort)
    } finally {
        $probe.Dispose()
    }

    $agentPort = Get-FreeTcpPort
    $env:AGENTDOCK_RELEASE_BASE_URL = "http://127.0.0.1:$httpPort"
    $env:AGENTDOCK_CLOUDFLARED_BINARY = $fakeCloudflared

    & $installer `
        -InstallDir $installDir `
        -RegisterStartup `
        -TunnelMode quick `
        -Port $agentPort `
        -AuthToken 'windows-e2e-bearer' `
        -OAuthPassword 'windows-e2e-oauth-password' `
        -OAuthTokenSecret '0123456789abcdef0123456789abcdef' `
        -StartupValueName $runValueName `
        -CloudflaredStartupValueName $cloudflaredRunValueName

    $serverUrlPath = Join-Path $runtimeDir 'server-url.txt'
    $modePath = Join-Path $runtimeDir 'cloudflared-mode.txt'
    $authPath = Join-Path $runtimeDir 'auth-token.dpapi'
    $oauthPasswordPath = Join-Path $runtimeDir 'oauth-password.dpapi'
    $oauthSecretPath = Join-Path $runtimeDir 'oauth-token-secret.dpapi'
    foreach ($path in @(
        (Join-Path $installDir 'agentdock.exe'),
        (Join-Path $installDir 'cloudflared.exe'),
        (Join-Path $runtimeDir 'start-agentdock.ps1'),
        (Join-Path $runtimeDir 'start-cloudflared.ps1'),
        (Join-Path $runtimeDir 'cloudflared.out.log'),
        (Join-Path $runtimeDir 'cloudflared.err.log'),
        $serverUrlPath,
        $modePath,
        $authPath,
        $oauthPasswordPath,
        $oauthSecretPath
    )) {
        Assert-File -Path $path
    }

    if ((Get-Content -LiteralPath $serverUrlPath -Raw).Trim() -ne 'https://windows-e2e.trycloudflare.com') {
        throw 'Quick Tunnel URL was not written back.'
    }
    if ((Get-Content -LiteralPath $modePath -Raw).Trim() -ne 'quick') {
        throw 'Tunnel mode was not persisted.'
    }
    if ((Read-DpapiText -Path $authPath -Entropy 'agentdock.startup.v1') -ne 'windows-e2e-bearer') {
        throw 'Bearer DPAPI round trip failed.'
    }
    if ((Read-DpapiText -Path $oauthPasswordPath -Entropy 'agentdock.oauth.password.v1') -ne 'windows-e2e-oauth-password') {
        throw 'OAuth password DPAPI round trip failed.'
    }
    if ((Read-DpapiText -Path $oauthSecretPath -Entropy 'agentdock.oauth.secret.v1') -ne '0123456789abcdef0123456789abcdef') {
        throw 'OAuth secret DPAPI round trip failed.'
    }

    $health = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$agentPort/healthz" -TimeoutSec 5
    if ($health.StatusCode -ne 200) {
        throw 'AgentDock health check failed after Quick Tunnel setup.'
    }

    $runAgentDock = Get-RunValue -RegistryPath $runKey -Name $runValueName
    $runCloudflared = Get-RunValue -RegistryPath $runKey -Name $cloudflaredRunValueName
    if (-not $runAgentDock.Contains((Join-Path $runtimeDir 'start-agentdock.ps1'))) {
        throw 'AgentDock startup entry is incorrect.'
    }
    if (-not $runCloudflared.Contains((Join-Path $runtimeDir 'start-cloudflared.ps1'))) {
        throw 'cloudflared startup entry is incorrect.'
    }

    $authHash = (Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash
    $oauthPasswordHash = (Get-FileHash -LiteralPath $oauthPasswordPath -Algorithm SHA256).Hash
    $oauthSecretHash = (Get-FileHash -LiteralPath $oauthSecretPath -Algorithm SHA256).Hash

    # A real rerun reuses the managed cloudflared binary rather than the test-only source override.
    Remove-Item Env:AGENTDOCK_CLOUDFLARED_BINARY -ErrorAction SilentlyContinue
    & $installer `
        -InstallDir $installDir `
        -Port $agentPort `
        -StartupValueName $runValueName `
        -CloudflaredStartupValueName $cloudflaredRunValueName

    if ((Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash -ne $authHash) {
        throw 'Bearer credential changed during refresh.'
    }
    if ((Get-FileHash -LiteralPath $oauthPasswordPath -Algorithm SHA256).Hash -ne $oauthPasswordHash) {
        throw 'OAuth password changed during refresh.'
    }
    if ((Get-FileHash -LiteralPath $oauthSecretPath -Algorithm SHA256).Hash -ne $oauthSecretHash) {
        throw 'OAuth secret changed during refresh.'
    }
    if ((Get-Content -LiteralPath $serverUrlPath -Raw).Trim() -ne 'https://windows-e2e.trycloudflare.com') {
        throw 'Quick Tunnel URL refresh failed.'
    }

    Write-Host 'Windows Quick Tunnel install and in-place refresh passed.'
    & $uninstaller `
        -InstallDir $installDir `
        -StartupValueName $runValueName `
        -CloudflaredStartupValueName $cloudflaredRunValueName
    if (Test-Path -LiteralPath $installDir) {
        throw 'Windows uninstaller did not remove the test install directory.'
    }
} catch {
    Write-Warning "Windows Tunnel E2E failed: $($_.Exception.Message)"
    foreach ($name in @(
        'start-cloudflared.ps1',
        'cloudflared.out.log',
        'cloudflared.err.log',
        'cloudflared-mode.txt',
        'server-url.txt'
    )) {
        $diagnosticPath = Join-Path $runtimeDir $name
        Write-Host "--- diagnostic: $name ---"
        if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
            Get-Content -LiteralPath $diagnosticPath -Raw
        } else {
            Write-Host 'missing'
        }
    }
    Get-Process agentdock, cloudflared -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.Path -like "$root*"
        } catch {
            $false
        }
    } | Select-Object ProcessName, Id, Path | Format-Table -AutoSize
    throw
} finally {
    Remove-Item Env:AGENTDOCK_RELEASE_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:AGENTDOCK_CLOUDFLARED_BINARY -ErrorAction SilentlyContinue
    Stop-ProcessByPath -ProcessName 'cloudflared' -BinaryPath (Join-Path $installDir 'cloudflared.exe')
    Stop-ProcessByPath -ProcessName 'agentdock' -BinaryPath (Join-Path $installDir 'agentdock.exe')
    Restore-RunValue -RegistryPath $runKey -Name $runValueName -Value $oldAgentDockRun
    Restore-RunValue -RegistryPath $runKey -Name $cloudflaredRunValueName -Value $oldCloudflaredRun
    Restore-RunValue -RegistryPath $runKey -Name 'AgentDock' -Value $realAgentDockRun
    Restore-RunValue -RegistryPath $runKey -Name 'AgentDockCloudflared' -Value $realCloudflaredRun
    [Environment]::SetEnvironmentVariable('Path', $oldUserPath, 'User')
    if ($httpServer -and -not $httpServer.HasExited) {
        Stop-Process -Id $httpServer.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $stateExisted -and (Test-Path -LiteralPath $stateDir)) {
        Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $workExisted -and (Test-Path -LiteralPath $workDir)) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
