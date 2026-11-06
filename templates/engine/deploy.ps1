<#
.SYNOPSIS
    Deploy Station deploy engine: installs one package version on this server.

.DESCRIPTION
    Runs on a Windows target server inside the tpl-deploy job, after the gatekeeper allowed it.
    0. Installs missing Windows features and installers listed in ds.json "prerequisites" (D21).
    1. Copies the package to <appRoot>\releases\<version> (reused if already there, e.g. rollback).
    2. Overlays server-held configuration from <appRoot>\config (secrets never leave the server).
    3. Stops the app, points <appRoot>\current at the new release, starts the app.
    4. Checks health. On failure, switches back to the previous release and fails the job.
    5. Keeps the newest releases (ds.json keepReleases, default 5) and removes older ones.
    Database migrations and other server changes are manual (docs/DESIGN.md D13).

.PARAMETER Version
    The package version, e.g. 1.5.0-rc.2.

.PARAMETER PackageDir
    The extracted package: the application files plus _ds\ (this engine and ds.json).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$PackageDir
)

$ErrorActionPreference = 'Stop'
foreach ($lib in 'DsCommon', 'DsIis', 'DsService', 'DsScript') {
    . (Join-Path $PSScriptRoot "lib\$lib.ps1")
}

$manifest = Read-DsManifest (Join-Path $PackageDir '_ds\ds.json')
$appRoot = Get-DsAppRoot $manifest
$releasesDir = Join-Path $appRoot 'releases'
$releaseDir = Join-Path $releasesDir $Version
$currentLink = Join-Path $appRoot 'current'
$configDir = Join-Path $appRoot 'config'
$health = Get-DsProperty $manifest 'health'
$healthUrl = Get-DsProperty $health 'url'
$healthTimeout = [int](Get-DsProperty $health 'timeoutSeconds' 60)
$keepReleases = [int](Get-DsProperty $manifest 'keepReleases' 5)

function Stop-DsApp {
    switch ($manifest.strategy) {
        'iis-site' { Stop-DsIisApp $manifest }
        'windows-service' { Stop-DsServiceApp $manifest }
        'script' { Invoke-DsScriptApp $manifest 'Stop' $currentLink $appRoot $Version }
    }
}

function Start-DsApp {
    switch ($manifest.strategy) {
        'iis-site' { Start-DsIisApp $manifest $currentLink $appRoot }
        'windows-service' { Start-DsServiceApp $manifest $currentLink $appRoot }
        'script' { Invoke-DsScriptApp $manifest 'Start' $currentLink $appRoot $Version }
    }
}

function Test-DsAppHealth {
    if ($healthUrl) {
        Write-DsLog "Checking $healthUrl (up to $healthTimeout seconds)"
        return (Test-DsHttpHealth $healthUrl $healthTimeout)
    }
    if ($manifest.strategy -eq 'windows-service') {
        Write-DsLog 'No health.url in ds.json; checking the service stays running for 10 seconds'
        return (Test-DsServiceStaysRunning $manifest 10)
    }
    Write-DsLog 'WARNING: no health.url in ds.json; health is not verified'
    return $true
}

Write-DsLog "Deploying $($manifest.name) $Version ($($manifest.strategy)) to $appRoot"
Install-DsPrerequisites $manifest
foreach ($dir in $appRoot, $releasesDir, $configDir) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
}

if (Test-Path -LiteralPath $releaseDir) {
    Write-DsLog "Release $Version is already on this server; reusing it"
} else {
    Copy-DsTree $PackageDir $releaseDir
    Initialize-DsPython $manifest $releaseDir
}
Copy-DsTree $configDir $releaseDir

$previousDir = Get-DsJunctionTarget $currentLink
if ($previousDir -and (ConvertTo-DsComparablePath $previousDir) -eq (ConvertTo-DsComparablePath $releaseDir)) {
    Write-DsLog "Release $Version is already current; restarting it"
    $previousDir = $null
}

Stop-DsApp
Set-DsJunction $currentLink $releaseDir
$healthy = $false
try {
    Start-DsApp
    $healthy = Test-DsAppHealth
} catch {
    Write-DsLog "Start failed: $($_.Exception.Message)"
}

if (-not $healthy) {
    if ($previousDir -and (Test-Path -LiteralPath $previousDir)) {
        $previousVersion = Split-Path $previousDir -Leaf
        Write-DsLog "Health check failed; switching back to $previousVersion"
        try { Stop-DsApp } catch { Write-DsLog "Stop failed: $($_.Exception.Message)" }
        Set-DsJunction $currentLink $previousDir
        Start-DsApp
        Save-DsState $appRoot @{ version = $previousVersion; failedVersion = $Version; autoRolledBack = $true }
        Write-Host "::error::$($manifest.name) $Version failed its health check; this server was rolled back to $previousVersion"
        throw "Health check failed for $Version; rolled back to $previousVersion"
    }
    Save-DsState $appRoot @{ version = $Version; failedVersion = $Version; autoRolledBack = $false }
    Write-Host "::error::$($manifest.name) $Version failed its health check and there is no previous release to switch back to"
    throw "Health check failed for $Version"
}

$previousVersion = $null
if ($previousDir) {
    $previousVersion = Split-Path $previousDir -Leaf
}
Save-DsState $appRoot @{ version = $Version; previousVersion = $previousVersion; autoRolledBack = $false }
Remove-DsOldReleases $releasesDir $keepReleases @($releaseDir, $previousDir)
Write-DsLog "Deployed $($manifest.name) $Version"
