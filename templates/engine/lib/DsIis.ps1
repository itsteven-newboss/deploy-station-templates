# iis-site strategy: one IIS site and app pool whose physical path is the <appRoot>\current junction.
# Creates the site and app pool on first deployment; never changes bindings or certificates of an
# existing site (those stay manual).

function Get-DsIisSettings {
    param($Manifest)
    $iis = $Manifest.iis
    return @{
        Site     = $iis.siteName
        Pool     = (Get-DsProperty $iis 'appPoolName' $iis.siteName)
        # '' = No Managed Code (ASP.NET Core, Python, Node); 'v4.0' for ASP.NET on .NET Framework
        Runtime  = (Get-DsProperty $iis 'managedRuntimeVersion' '')
        Bindings = @(Get-DsProperty $iis 'bindings' @())
    }
}

function Stop-DsIisApp {
    param($Manifest)
    Import-Module WebAdministration -ErrorAction Stop
    $settings = Get-DsIisSettings $Manifest
    if (-not (Test-Path "IIS:\AppPools\$($settings.Pool)")) {
        Write-DsLog "App pool $($settings.Pool) does not exist yet"
        return
    }
    if ((Get-WebAppPoolState -Name $settings.Pool).Value -ne 'Stopped') {
        Write-DsLog "Stopping app pool $($settings.Pool)"
        Stop-WebAppPool -Name $settings.Pool
        Wait-DsCondition { (Get-WebAppPoolState -Name $settings.Pool).Value -eq 'Stopped' } 60 "app pool $($settings.Pool) to stop"
    }
}

function Start-DsIisApp {
    param($Manifest, [string]$CurrentLink, [string]$AppRoot)
    Import-Module WebAdministration -ErrorAction Stop
    $settings = Get-DsIisSettings $Manifest
    $poolPath = "IIS:\AppPools\$($settings.Pool)"
    if (-not (Test-Path $poolPath)) {
        Write-DsLog "Creating app pool $($settings.Pool)"
        New-WebAppPool -Name $settings.Pool | Out-Null
        Set-ItemProperty $poolPath -Name managedRuntimeVersion -Value $settings.Runtime
        # The pool identity needs read access to the release folders (inherited by new releases).
        & icacls $AppRoot /grant "IIS AppPool\$($settings.Pool):(OI)(CI)RX" /Q | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Granting IIS AppPool\$($settings.Pool) access to $AppRoot failed"
        }
    }

    $sitePath = "IIS:\Sites\$($settings.Site)"
    if (-not (Test-Path $sitePath)) {
        if ($settings.Bindings.Count -eq 0) {
            throw "ds.json: iis.bindings is required to create site $($settings.Site)"
        }
        Write-DsLog "Creating site $($settings.Site)"
        $first = $settings.Bindings[0]
        $parameters = @{
            Name            = $settings.Site
            PhysicalPath    = $CurrentLink
            ApplicationPool = $settings.Pool
            Port            = [int]$first.port
            HostHeader      = (Get-DsProperty $first 'hostName' '')
            IPAddress       = (Get-DsProperty $first 'ipAddress' '*')
        }
        if ((Get-DsProperty $first 'protocol' 'http') -eq 'https') {
            $parameters['Ssl'] = $true
        }
        New-Website @parameters | Out-Null
        foreach ($binding in ($settings.Bindings | Select-Object -Skip 1)) {
            New-WebBinding -Name $settings.Site -Protocol (Get-DsProperty $binding 'protocol' 'http') `
                -Port ([int]$binding.port) -HostHeader (Get-DsProperty $binding 'hostName' '') `
                -IPAddress (Get-DsProperty $binding 'ipAddress' '*')
        }
    } else {
        $physicalPath = (Get-ItemProperty $sitePath -Name physicalPath)
        if ((ConvertTo-DsComparablePath $physicalPath) -ne (ConvertTo-DsComparablePath $CurrentLink)) {
            Write-DsLog "Pointing site $($settings.Site) at $CurrentLink (was $physicalPath)"
            Set-ItemProperty $sitePath -Name physicalPath -Value $CurrentLink
        }
        $sitePool = (Get-ItemProperty $sitePath -Name applicationPool)
        if ($sitePool -ne $settings.Pool) {
            Write-DsLog "WARNING: site $($settings.Site) uses app pool '$sitePool', not '$($settings.Pool)' from ds.json"
        }
    }

    if ((Get-WebAppPoolState -Name $settings.Pool).Value -ne 'Started') {
        Start-WebAppPool -Name $settings.Pool
    }
    if ((Get-WebsiteState -Name $settings.Site).Value -ne 'Started') {
        Start-Website -Name $settings.Site
    }
    Write-DsLog "Site $($settings.Site) started"
}
