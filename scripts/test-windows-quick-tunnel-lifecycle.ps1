[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $InstallerPath,
    [Parameter(Mandatory = $true)]
    [string] $UninstallerPath,
    [Parameter(Mandatory = $true)]
    [string] $AgentDockArchive,
    [Parameter(Mandatory = $true)]
    [string] $AgentDockChecksumFile,
    [Parameter(Mandatory = $true)]
    [string] $FakeCloudflaredBinary
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

function Get-ProcessIdsByPath {
    param([string] $ProcessName, [string] $BinaryPath)

    if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
        return @()
    }
    $normalizedPath = [IO.Path]::GetFullPath($BinaryPath)
    return @(Get-CimInstance Win32_Process -Filter "Name = '$ProcessName.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            [string]::Equals(
                [IO.Path]::GetFullPath($_.ExecutablePath),
                $normalizedPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        } |
        Select-Object -ExpandProperty ProcessId)
}

function Stop-ProcessByPath {
    param([string] $ProcessName, [string] $BinaryPath)

    foreach ($processId in @(Get-ProcessIdsByPath -ProcessName $ProcessName -BinaryPath $BinaryPath)) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (@(Get-ProcessIdsByPath -ProcessName $ProcessName -BinaryPath $BinaryPath).Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Process did not stop within 15 seconds: $BinaryPath"
}

function Wait-TextFileValue {
    param([string] $Path, [string] $ExpectedValue, [int] $TimeoutSeconds = 45)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        try {
            if ((Test-Path -LiteralPath $Path -PathType Leaf) -and
                [string]::Equals(
                    [IO.File]::ReadAllText($Path).Trim(),
                    $ExpectedValue,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                return
            }
        } catch {
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    $actual = if (Test-Path -LiteralPath $Path -PathType Leaf) {
        [IO.File]::ReadAllText($Path).Trim()
    } else {
        '<missing>'
    }
    throw "Timed out waiting for $Path to become $ExpectedValue; actual: $actual"
}

function Wait-Healthy {
    param([string] $Url, [int] $TimeoutSeconds = 30)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                return
            }
        } catch {
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "AgentDock did not become healthy: $Url"
}

$testId = [Guid]::NewGuid().ToString('N')
$root = Join-Path $env:RUNNER_TEMP "agentdock-quick-lifecycle-$testId"
$installDir = Join-Path $root 'AgentDock\bin'
$runtimeDir = Split-Path -Parent $installDir
$agentDockBinary = Join-Path $installDir 'agentdock.exe'
$trayBinary = Join-Path $installDir 'agentdock-tray.exe'
$cloudflaredBinary = Join-Path $installDir 'cloudflared.exe'
$cloudflaredLauncher = Join-Path $runtimeDir 'start-cloudflared.ps1'
$urlSourcePath = Join-Path $installDir 'quick-url-source.txt'
$quickUrlPath = Join-Path $runtimeDir 'quick-tunnel-url.txt'
$serverUrlPath = Join-Path $runtimeDir 'server-url.txt'
$manifestPath = Join-Path $runtimeDir 'runtime.json'
$authPath = Join-Path $runtimeDir 'auth-token.dpapi'
$oauthPasswordPath = Join-Path $runtimeDir 'oauth-password.dpapi'
$oauthSecretPath = Join-Path $runtimeDir 'oauth-token-secret.dpapi'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupName = "AgentDockQuickLifecycle-$testId"
$cloudflaredStartupName = "AgentDockCloudflaredQuickLifecycle-$testId"
$trayStartupName = "AgentDockTrayQuickLifecycle-$testId"
$port = Get-FreeTcpPort
$healthUrl = "http://127.0.0.1:$port/healthz"
$firstUrl = 'https://first-agentdock-test.trycloudflare.com'
$secondUrl = 'https://second-agentdock-test.trycloudflare.com'
$oldUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$refreshLauncher = $null

try {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    [IO.File]::WriteAllText($urlSourcePath, $firstUrl, [Text.UTF8Encoding]::new($false))

    & $InstallerPath `
        -Version 'v0.0.0-test' `
        -OfflineArchive $AgentDockArchive `
        -OfflineChecksumFile $AgentDockChecksumFile `
        -OfflineCloudflaredBinary $FakeCloudflaredBinary `
        -InstallDir $installDir `
        -RegisterStartup `
        -TunnelMode quick `
        -CorePrivilegeMode standard `
        -Port $port `
        -AuthToken 'stable-quick-bearer-token' `
        -OAuthPassword 'stable-quick-oauth-password' `
        -OAuthTokenSecret 'stable-quick-oauth-secret-0123456789abcdef' `
        -StartupValueName $startupName `
        -CloudflaredStartupValueName $cloudflaredStartupName `
        -TrayStartupValueName $trayStartupName

    foreach ($path in @(
        $agentDockBinary,
        $trayBinary,
        $cloudflaredBinary,
        $cloudflaredLauncher,
        $quickUrlPath,
        $serverUrlPath,
        $manifestPath,
        $authPath,
        $oauthPasswordPath,
        $oauthSecretPath
    )) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Quick Tunnel install did not create expected file: $path"
        }
    }
    Wait-TextFileValue -Path $quickUrlPath -ExpectedValue $firstUrl
    Wait-TextFileValue -Path $serverUrlPath -ExpectedValue $firstUrl
    Wait-Healthy -Url $healthUrl

    $firstManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($firstManifest.tunnel_mode -ne 'quick' -or $firstManifest.public_url -ne $firstUrl) {
        throw "Initial runtime manifest did not contain the Quick Tunnel URL: $($firstManifest | ConvertTo-Json -Compress)"
    }
    $firstAgentDockIds = @(Get-ProcessIdsByPath -ProcessName 'agentdock' -BinaryPath $agentDockBinary)
    if ($firstAgentDockIds.Count -ne 1) {
        throw "Expected one AgentDock process after Quick Tunnel install; got $($firstAgentDockIds.Count)."
    }
    $firstAgentDockId = [int] $firstAgentDockIds[0]
    $authHash = (Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash
    $oauthPasswordHash = (Get-FileHash -LiteralPath $oauthPasswordPath -Algorithm SHA256).Hash
    $oauthSecretHash = (Get-FileHash -LiteralPath $oauthSecretPath -Algorithm SHA256).Hash

    [IO.File]::WriteAllText($urlSourcePath, $secondUrl, [Text.UTF8Encoding]::new($false))
    Stop-ProcessByPath -ProcessName 'cloudflared' -BinaryPath $cloudflaredBinary
    Start-Sleep -Milliseconds 750
    Remove-Item -LiteralPath $quickUrlPath -Force -ErrorAction SilentlyContinue
    $refreshLauncher = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-WindowStyle', 'Hidden',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$cloudflaredLauncher`""
        ) `
        -WindowStyle Hidden `
        -PassThru

    Wait-TextFileValue -Path $quickUrlPath -ExpectedValue $secondUrl
    Wait-TextFileValue -Path $serverUrlPath -ExpectedValue $secondUrl
    Wait-Healthy -Url $healthUrl

    $secondManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($secondManifest.public_url -ne $secondUrl) {
        throw "Runtime manifest was not refreshed: $($secondManifest | ConvertTo-Json -Compress)"
    }
    $secondAgentDockIds = @(Get-ProcessIdsByPath -ProcessName 'agentdock' -BinaryPath $agentDockBinary)
    if ($secondAgentDockIds.Count -ne 1) {
        throw "Expected one AgentDock process after Quick Tunnel refresh; got $($secondAgentDockIds.Count)."
    }
    if ([int] $secondAgentDockIds[0] -eq $firstAgentDockId) {
        throw 'AgentDock was not restarted after the Quick Tunnel URL changed.'
    }
    if ((Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash -ne $authHash -or
        (Get-FileHash -LiteralPath $oauthPasswordPath -Algorithm SHA256).Hash -ne $oauthPasswordHash -or
        (Get-FileHash -LiteralPath $oauthSecretPath -Algorithm SHA256).Hash -ne $oauthSecretHash) {
        throw 'Quick Tunnel refresh unexpectedly rotated existing credentials.'
    }

    Write-Host "Windows Quick Tunnel lifecycle passed: $firstUrl -> $secondUrl"

    & $UninstallerPath `
        -InstallDir $installDir `
        -StartupValueName $startupName `
        -CloudflaredStartupValueName $cloudflaredStartupName `
        -TrayStartupValueName $trayStartupName
    if (Test-Path -LiteralPath $installDir) {
        throw 'Quick Tunnel lifecycle uninstaller did not remove the install directory.'
    }
} catch {
    foreach ($name in @(
        'start-cloudflared.ps1',
        'cloudflared.out.log',
        'cloudflared.err.log',
        'quick-tunnel-url.txt',
        'server-url.txt',
        'runtime.json'
    )) {
        $path = Join-Path $runtimeDir $name
        Write-Host "----- diagnostic: $path -----"
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Get-Content -LiteralPath $path -Raw | Write-Host
        } else {
            Write-Host '<missing>'
        }
    }
    throw
} finally {
    if ($refreshLauncher -and -not $refreshLauncher.HasExited) {
        Stop-Process -Id $refreshLauncher.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-ProcessByPath -ProcessName 'agentdock-tray' -BinaryPath $trayBinary
    Stop-ProcessByPath -ProcessName 'cloudflared' -BinaryPath $cloudflaredBinary
    Stop-ProcessByPath -ProcessName 'agentdock' -BinaryPath $agentDockBinary
    foreach ($name in @($startupName, $cloudflaredStartupName, $trayStartupName)) {
        Remove-ItemProperty -LiteralPath $runKey -Name $name -ErrorAction SilentlyContinue
    }
    [Environment]::SetEnvironmentVariable('Path', $oldUserPath, 'User')
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
