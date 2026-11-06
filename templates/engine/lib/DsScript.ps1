# script strategy: the package's own PowerShell script stops and starts the app.
# The script is called with -Action Stop (from the release being replaced) and -Action Start
# (from the new release), plus -AppRoot, -ReleaseDir and -Version.

function Invoke-DsScriptApp {
    param($Manifest, [string]$Action, [string]$CurrentLink, [string]$AppRoot, [string]$Version)
    $script = Join-Path $CurrentLink $Manifest.script.path
    if (-not (Test-Path -LiteralPath $script)) {
        if ($Action -eq 'Stop') {
            Write-DsLog 'No previous release to stop'
            return
        }
        throw "Custom deploy script not found: $script"
    }
    Write-DsLog "Running $($Manifest.script.path) -Action $Action"
    & $script -Action $Action -AppRoot $AppRoot -ReleaseDir $CurrentLink -Version $Version
}
