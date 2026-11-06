<#
.SYNOPSIS
    Downloads the package for this server from the release v<Version> of the current repository:
    package-windows.zip when the release has one, otherwise the portable package.zip. Verifies its
    SHA-256 and extracts it. Runs on Windows target servers (Windows PowerShell 5.1); the Ubuntu
    counterpart is get-ds-package.sh. Writes the extracted folder to the step output "package-dir".
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$OutDir
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not $env:DS_GITHUB_TOKEN) {
    throw 'DS_GITHUB_TOKEN is not set'
}
$headers = @{ Authorization = "Bearer $env:DS_GITHUB_TOKEN"; 'X-GitHub-Api-Version' = '2022-11-28' }
$api = "$env:GITHUB_API_URL/repos/$env:GITHUB_REPOSITORY"
$release = Invoke-RestMethod -Uri "$api/releases/tags/v$Version" -Headers $headers -UserAgent 'deploy-station'

if (Test-Path -LiteralPath $OutDir) {
    Remove-Item -LiteralPath $OutDir -Recurse -Force
}
New-Item -ItemType Directory -Path $OutDir | Out-Null
$package = $null
foreach ($candidate in 'package-windows.zip', 'package.zip') {
    $names = @($release.assets | ForEach-Object { $_.name })
    if ($names -contains $candidate -and $names -contains "$candidate.sha256") {
        $package = $candidate
        break
    }
}
if (-not $package) {
    throw "Release v$Version has no package-windows.zip or package.zip (with its .sha256)"
}
foreach ($name in $package, "$package.sha256") {
    $asset = $release.assets | Where-Object { $_.name -eq $name }
    # Windows PowerShell drops the Authorization header when it follows the redirect to GitHub's
    # storage, which the signed storage URL requires.
    Invoke-WebRequest -Uri $asset.url -Headers ($headers + @{ Accept = 'application/octet-stream' }) `
        -UserAgent 'deploy-station' -OutFile (Join-Path $OutDir $name) -UseBasicParsing
}

$zip = Join-Path $OutDir $package
$expected = ((Get-Content -LiteralPath (Join-Path $OutDir "$package.sha256") -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expected -ne $actual) {
    throw "$package checksum mismatch: release says $expected, downloaded file is $actual"
}
Write-Host "$package v$Version verified ($actual)"

$packageDir = Join-Path $OutDir 'package'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $packageDir)
if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "package-dir=$packageDir" -Encoding ASCII
}
