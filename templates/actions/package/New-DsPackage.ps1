<#
.SYNOPSIS
    Builds a package: the built application plus _ds\ (both deploy engines, ds.json, version.txt),
    with its SHA-256 next to it (docs/DESIGN.md section 11.1). Runs on GitHub-hosted runners
    (PowerShell 7 on Linux or Windows) and on Windows PowerShell 5.1.

.PARAMETER Os
    any (default): a portable build, written as package.zip for Windows and Ubuntu servers alike.
    windows / linux: a build for one OS, written as package-windows.zip / package-linux.zip.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Manifest,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [ValidateSet('any', 'windows', 'linux')][string]$Os = 'any'
)

$ErrorActionPreference = 'Stop'
$engineDir = Join-Path $PSScriptRoot '../../engine'
. (Join-Path $engineDir 'lib/DsCommon.ps1')

if ($Version -notmatch '^\d+\.\d+\.\d+(-rc\.\d+)?$') {
    throw "Version must look like 1.5.0 or 1.5.0-rc.2 (got '$Version')"
}
if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw "Build output folder not found: $Source"
}
if (Test-Path -LiteralPath (Join-Path $Source '_ds')) {
    throw "The build output must not contain a _ds folder; Deploy Station adds it"
}
# Validate ds.json at build time, for every OS this package can land on, so a broken manifest
# never reaches a server.
if ($Os -eq 'any') {
    $targets = @(Get-DsManifestTargets $Manifest)
} else {
    Read-DsManifest $Manifest $Os | Out-Null
    $targets = @($Os)
}
$appName = (Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json).name
$fileName = if ($Os -eq 'any') { 'package.zip' } else { "package-$Os.zip" }
Write-Host "Packaging $appName $Version as $fileName (deployable on: $($targets -join ', '))"

if (Test-Path -LiteralPath $OutDir) {
    Remove-Item -LiteralPath $OutDir -Recurse -Force
}
$staging = Join-Path $OutDir 'staging'
New-Item -ItemType Directory -Path $staging -Force | Out-Null

Get-ChildItem -LiteralPath $Source -Force |
    Where-Object { @('.git', '.github') -notcontains $_.Name } |
    Copy-Item -Destination $staging -Recurse -Force

$dsDir = Join-Path $staging '_ds'
Copy-Item -LiteralPath $engineDir -Destination $dsDir -Recurse
Copy-Item -LiteralPath $Manifest -Destination (Join-Path $dsDir 'ds.json') -Force
Set-Content -LiteralPath (Join-Path $dsDir 'version.txt') -Value $Version -Encoding ASCII

$zip = Join-Path $OutDir $fileName
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
# Entries are written one by one so names always use '/', as the zip format requires; Windows
# PowerShell 5.1's CreateFromDirectory would write '\' instead.
$stagingRoot = (Resolve-Path -LiteralPath $staging).Path.TrimEnd('\', '/')
$archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem -LiteralPath $stagingRoot -Recurse -File -Force | ForEach-Object {
        $entryName = $_.FullName.Substring($stagingRoot.Length + 1).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $_.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $archive.Dispose()
}
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $OutDir "$fileName.sha256") -Value "$hash  $fileName" -Encoding ASCII
Remove-Item -LiteralPath $staging -Recurse -Force
Write-Host "$fileName sha256 $hash"
