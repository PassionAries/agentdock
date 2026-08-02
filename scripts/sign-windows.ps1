[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $Path,
    [switch] $VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-TemporaryTrust {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [Parameter(Mandatory = $true)]
        [string] $StoreName
    )

    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        $StoreName,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
    )
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        $existing = $store.Certificates.Find(
            [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
            $Certificate.Thumbprint,
            $false
        )
        if ($existing.Count -gt 0) {
            return $false
        }
        $store.Add($Certificate)
        return $true
    } finally {
        $store.Close()
    }
}

function Remove-TemporaryTrust {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Thumbprint,
        [Parameter(Mandatory = $true)]
        [string] $StoreName
    )

    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        $StoreName,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
    )
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        $matches = $store.Certificates.Find(
            [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
            $Thumbprint,
            $false
        )
        foreach ($certificate in $matches) {
            $store.Remove($certificate)
        }
    } finally {
        $store.Close()
    }
}

$signTool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
    Sort-Object FullName |
    Select-Object -Last 1
if (-not $signTool) {
    throw 'signtool.exe was not found.'
}

$resolvedPaths = @($Path | ForEach-Object {
    (Resolve-Path -LiteralPath $_ -ErrorAction Stop).Path
})
$temporaryTrust = [System.Collections.Generic.List[object]]::new()

try {
    if (-not $VerifyOnly) {
        if ([string]::IsNullOrWhiteSpace($env:WINDOWS_SIGNING_CERT_BASE64)) {
            throw 'WINDOWS_SIGNING_CERT_BASE64 is required.'
        }
        if ([string]::IsNullOrWhiteSpace($env:WINDOWS_SIGNING_CERT_PASSWORD)) {
            throw 'WINDOWS_SIGNING_CERT_PASSWORD is required.'
        }

        $pfx = Join-Path $env:RUNNER_TEMP ("agentdock-signing-" + [Guid]::NewGuid().ToString('N') + '.pfx')
        [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:WINDOWS_SIGNING_CERT_BASE64))
        try {
            foreach ($item in $resolvedPaths) {
                & $signTool.FullName sign `
                    /fd SHA256 `
                    /f $pfx `
                    /p $env:WINDOWS_SIGNING_CERT_PASSWORD `
                    /tr http://timestamp.digicert.com `
                    /td SHA256 `
                    $item
                if ($LASTEXITCODE -ne 0) {
                    throw "signtool sign failed for $item with exit code $LASTEXITCODE."
                }
            }
        } finally {
            Remove-Item -LiteralPath $pfx -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($item in $resolvedPaths) {
        $initialSignature = Get-AuthenticodeSignature -LiteralPath $item
        if (-not $initialSignature.SignerCertificate) {
            throw "Authenticode signer certificate is missing for $item."
        }

        $signer = $initialSignature.SignerCertificate
        if ($signer.Subject -eq $signer.Issuer) {
            foreach ($storeName in @('Root', 'TrustedPublisher')) {
                if (Add-TemporaryTrust -Certificate $signer -StoreName $storeName) {
                    $temporaryTrust.Add([pscustomobject]@{
                        StoreName = $storeName
                        Thumbprint = $signer.Thumbprint
                    })
                }
            }
        }

        & $signTool.FullName verify /pa /all /v $item
        if ($LASTEXITCODE -ne 0) {
            throw "signtool verify failed for $item with exit code $LASTEXITCODE."
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $item
        if ($signature.Status -ne 'Valid') {
            throw "Authenticode signature is not valid for $item: $($signature.Status)"
        }
    }
} finally {
    foreach ($entry in @($temporaryTrust)) {
        Remove-TemporaryTrust -Thumbprint $entry.Thumbprint -StoreName $entry.StoreName
    }
}
