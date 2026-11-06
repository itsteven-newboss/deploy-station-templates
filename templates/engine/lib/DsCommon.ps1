# Shared helpers for the Deploy Station deploy engine (docs/DESIGN.md section 11.3).
# Windows PowerShell 5.1 compatible. Keep this file ASCII: 5.1 reads BOM-less files as ANSI.

$script:DsWinSWPath = 'C:\deploy-station\tools\WinSW-x64.exe'

function Write-DsLog {
    param([string]$Message)
    Write-Host "[ds] $Message"
}

function Get-DsProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

# Strategies each OS's engine supports (docs/DESIGN.md D15). 'script' exists on both.
$script:DsStrategies = @{
    windows = @('iis-site', 'windows-service', 'script')
    linux   = @('systemd-service', 'nginx-site', 'script')
}

# The manifest as seen on one OS: the shared settings with that OS's section laid over them (D17).
function Get-DsEffectiveManifest {
    param($Manifest, [ValidateSet('windows', 'linux')][string]$Os)
    $effective = New-Object PSObject
    foreach ($property in $Manifest.PSObject.Properties) {
        if (@('windows', 'linux') -notcontains $property.Name) {
            $effective | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
        }
    }
    $override = Get-DsProperty $Manifest $Os
    if ($override) {
        foreach ($property in $override.PSObject.Properties) {
            $effective | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }
    return $effective
}

# Throws a readable error if the effective manifest cannot be deployed on this OS.
function Test-DsManifest {
    param($Manifest, [ValidateSet('windows', 'linux')][string]$Os)
    $name = Get-DsProperty $Manifest 'name'
    if (-not $name -or $name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "ds.json: 'name' is required (letters, digits, '.', '_' or '-')"
    }
    $strategy = Get-DsProperty $Manifest 'strategy'
    if ($script:DsStrategies[$Os] -notcontains $strategy) {
        throw "ds.json: strategy '$strategy' cannot run on $Os (use one of: $($script:DsStrategies[$Os] -join ', '), or set it in a `"$Os`" section)"
    }
    $require = {
        param($Section, [string[]]$Fields)
        $value = Get-DsProperty $Manifest $Section
        foreach ($field in $Fields) {
            if (-not (Get-DsProperty $value $field)) {
                throw "ds.json: $Section.$field is required for the $strategy strategy on $Os"
            }
        }
    }
    switch ($strategy) {
        'iis-site' { & $require 'iis' @('siteName') }
        'windows-service' { & $require 'service' @('serviceName', 'executable') }
        'systemd-service' { & $require 'service' @('serviceName', 'executable') }
        'nginx-site' { & $require 'nginx' @('listen') }
        'script' { & $require 'script' @('path') }
    }
}

function Read-DsManifest {
    param([string]$Path, [ValidateSet('windows', 'linux')][string]$Os = 'windows')
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "ds.json not found at $Path"
    }
    $manifest = Get-DsEffectiveManifest (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) $Os
    Test-DsManifest $manifest $Os
    return $manifest
}

# For packaging: the OSes this ds.json is meant for (its effective strategy belongs to that OS),
# each of which must validate. Throws if it targets no OS or an intended OS has errors.
function Get-DsManifestTargets {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "ds.json not found at $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $targets = @()
    foreach ($os in 'windows', 'linux') {
        $effective = Get-DsEffectiveManifest $raw $os
        if ($script:DsStrategies[$os] -contains (Get-DsProperty $effective 'strategy')) {
            Test-DsManifest $effective $os
            $targets += $os
        }
    }
    if ($targets.Count -eq 0) {
        throw "ds.json: 'strategy' must be one of $($script:DsStrategies.windows -join ', ') (Windows) or $($script:DsStrategies.linux -join ', ') (Ubuntu)"
    }
    return $targets
}

# What the app needs on the server (ds.json "prerequisites", D21): Windows features, then installers
# such as the ASP.NET Core Hosting Bundle. Installed before the release is copied; anything already
# present is skipped, so later deployments cost nothing.
function Install-DsPrerequisites {
    param($Manifest)
    $prerequisites = Get-DsProperty $Manifest 'prerequisites'
    if (-not $prerequisites) {
        return
    }
    $ProgressPreference = 'SilentlyContinue'

    $features = @(Get-DsProperty $prerequisites 'windowsFeatures' @())
    if ($features.Count -gt 0) {
        if (-not (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) {
            throw 'ds.json: windowsFeatures needs Windows Server (Install-WindowsFeature)'
        }
        $missing = @()
        foreach ($name in $features) {
            $feature = Get-WindowsFeature -Name $name
            if (-not $feature) {
                throw "ds.json: '$name' is not a Windows feature (see Get-WindowsFeature)"
            }
            if (-not $feature.Installed) {
                $missing += $name
            }
        }
        if ($missing.Count -gt 0) {
            Write-DsLog "Installing Windows features: $($missing -join ', ')"
            $result = Install-WindowsFeature -Name $missing
            if (-not $result.Success) {
                throw "Installing Windows features failed: $($missing -join ', ')"
            }
            if ("$($result.RestartNeeded)" -eq 'Yes') {
                Write-DsLog 'WARNING: Windows asks for a restart to finish installing the features'
            }
        }
    }

    $installed = $false
    foreach ($installer in @(Get-DsProperty $prerequisites 'installers' @())) {
        $name = Get-DsProperty $installer 'name' 'installer'
        $paths = @(Get-DsProperty $installer 'installedPath' @())
        $url = Get-DsProperty $installer 'url'
        # Pinned by SHA-512 or SHA-256, whichever the publisher lists (Microsoft: SHA-512, python.org: SHA-256).
        $algorithm = 'SHA512'
        $expected = Get-DsProperty $installer 'sha512'
        if (-not $expected) {
            $algorithm = 'SHA256'
            $expected = Get-DsProperty $installer 'sha256'
        }
        if ($paths.Count -eq 0 -or -not $url -or -not $expected) {
            throw "ds.json: installer '$name' needs url, sha512 or sha256, and installedPath"
        }
        if ($url -notmatch '^https://') {
            throw "ds.json: installer '$name' must be downloaded over https"
        }
        if (@($paths | Where-Object { -not (Test-Path -Path $_) }).Count -eq 0) {
            continue
        }
        $file = Join-Path $env:TEMP ('ds-' + [IO.Path]::GetFileName(([Uri]$url).AbsolutePath))
        Write-DsLog "Downloading $name"
        Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
        $actual = (Get-FileHash -LiteralPath $file -Algorithm $algorithm).Hash
        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $file -Force
            throw "Checksum mismatch for $name (expected $algorithm $expected, got $actual)"
        }
        Write-DsLog "Installing $name"
        $arguments = Get-DsProperty $installer 'arguments'
        $start = @{ FilePath = $file; Wait = $true; PassThru = $true }
        if ($arguments) {
            $start['ArgumentList'] = $arguments
        }
        $process = Start-Process @start
        Remove-Item -LiteralPath $file -Force
        # 3010: installed, a restart finishes the job
        if (@(0, 3010) -notcontains $process.ExitCode) {
            throw "Installing $name failed (exit code $($process.ExitCode))"
        }
        if ($process.ExitCode -eq 3010) {
            Write-DsLog "WARNING: $name asks for a restart to finish"
        }
        $installed = $true
    }
    if ($installed -and (Get-Service -Name W3SVC -ErrorAction SilentlyContinue)) {
        # IIS loads newly installed modules, such as the ASP.NET Core Module, only after a restart.
        Write-DsLog 'Restarting IIS to load what was installed'
        & net.exe stop was /y | Out-Null
        & net.exe start w3svc | Out-Null
    }
}

function Get-DsAppRoot {
    param($Manifest)
    $root = Get-DsProperty $Manifest 'appRoot'
    if (-not $root) {
        $root = Join-Path 'C:\apps' $Manifest.name
    }
    return $root
}

function ConvertTo-DsComparablePath {
    param([string]$Path)
    if (-not $Path) {
        return ''
    }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\').ToLowerInvariant()
}

function Get-DsJunctionTarget {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType -ne 'Junction') {
        throw "$Path exists but is not a junction"
    }
    return @($item.Target)[0]
}

function Set-DsJunction {
    param([string]$Path, [string]$Target)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.LinkType -ne 'Junction') {
            throw "$Path exists but is not a junction; refusing to replace it"
        }
        # Deleting the directory entry of a junction removes the link, never the files it points to.
        [System.IO.Directory]::Delete($Path, $false)
    }
    New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
}

function Copy-DsTree {
    param([string]$From, [string]$To)
    if (-not (Test-Path -LiteralPath $From)) {
        return
    }
    & robocopy $From $To /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
    # robocopy: 0-7 are success codes, 8 and above are failures.
    if ($LASTEXITCODE -ge 8) {
        throw "Copying $From to $To failed (robocopy exit code $LASTEXITCODE)"
    }
    $global:LASTEXITCODE = 0
}

function Wait-DsCondition {
    param([scriptblock]$Condition, [int]$TimeoutSeconds, [string]$Description)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (& $Condition)) {
        if ((Get-Date) -gt $deadline) {
            throw "Timed out after $TimeoutSeconds seconds waiting for $Description"
        }
        Start-Sleep -Milliseconds 500
    }
}

function Test-DsHttpHealth {
    param([string]$Url, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                return $true
            }
        } catch {
            Write-DsLog "Health check: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Initialize-DsPython {
    param($Manifest, [string]$ReleaseDir)
    $python = Get-DsProperty $Manifest 'python'
    if (-not $python) {
        return
    }
    $interpreter = Get-DsProperty $python 'interpreter' 'python'
    $requirements = Join-Path $ReleaseDir (Get-DsProperty $python 'requirements' 'requirements.txt')
    $wheelhouse = Join-Path $ReleaseDir (Get-DsProperty $python 'wheelhouse' 'wheels')
    $venv = Join-Path $ReleaseDir '.venv'
    Write-DsLog "Creating virtualenv with $interpreter"
    & $interpreter -m venv $venv
    if ($LASTEXITCODE -ne 0) {
        throw "Creating the virtualenv failed (exit code $LASTEXITCODE)"
    }
    Write-DsLog 'Installing Python packages offline from the package wheelhouse'
    & (Join-Path $venv 'Scripts\python.exe') -m pip install --no-index --find-links $wheelhouse -r $requirements
    if ($LASTEXITCODE -ne 0) {
        throw "pip install failed (exit code $LASTEXITCODE)"
    }
}

function Remove-DsOldReleases {
    param([string]$ReleasesDir, [int]$Keep, [string[]]$Protect)
    $protected = @($Protect | ForEach-Object { ConvertTo-DsComparablePath $_ })
    $kept = 0
    $releases = Get-ChildItem -LiteralPath $ReleasesDir -Directory | Sort-Object CreationTimeUtc -Descending
    foreach ($release in $releases) {
        if ($protected -contains (ConvertTo-DsComparablePath $release.FullName) -or $kept -lt $Keep) {
            $kept++
            continue
        }
        Write-DsLog "Removing old release $($release.Name)"
        Remove-Item -LiteralPath $release.FullName -Recurse -Force
    }
}

function Save-DsState {
    param([string]$AppRoot, [hashtable]$State)
    $State['updatedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    $State | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $AppRoot 'ds-state.json') -Encoding ASCII
}
