# windows-service strategy: a Windows service whose executable lives under <appRoot>\current.
# Native service executables are registered directly. Programs that are not services (python.exe,
# node.exe, console apps) are wrapped with WinSW (service.wrapper = "winsw").
# Registers the service on first deployment; never changes the account of an existing service.

function Get-DsServiceSettings {
    param($Manifest, [string]$CurrentLink)
    $service = $Manifest.service
    $executable = $service.executable
    if (-not [System.IO.Path]::IsPathRooted($executable)) {
        $executable = Join-Path $CurrentLink $executable
    }
    return @{
        Name        = $service.serviceName
        DisplayName = (Get-DsProperty $service 'displayName' $service.serviceName)
        Executable  = $executable
        Arguments   = (Get-DsProperty $service 'arguments' '')
        StartupType = (Get-DsProperty $service 'startupType' 'Automatic')
        Wrapper     = (Get-DsProperty $service 'wrapper' 'none')
    }
}

function Stop-DsServiceApp {
    param($Manifest)
    $name = $Manifest.service.serviceName
    $service = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-DsLog "Service $name does not exist yet"
        return
    }
    if ($service.Status -ne 'Stopped') {
        Write-DsLog "Stopping service $name"
        Stop-Service -Name $name -Force
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    }
}

function Install-DsService {
    param([hashtable]$Settings, [string]$CurrentLink, [string]$AppRoot)
    if ($Settings.Wrapper -eq 'winsw') {
        if (-not (Test-Path -LiteralPath $script:DsWinSWPath)) {
            throw "WinSW not found at $($script:DsWinSWPath); run install-runner.ps1 with -InstallWinSW"
        }
        $serviceDir = Join-Path $AppRoot 'service'
        New-Item -ItemType Directory -Path $serviceDir -Force | Out-Null
        $wrapper = Join-Path $serviceDir "$($Settings.Name).exe"
        Copy-Item -LiteralPath $script:DsWinSWPath -Destination $wrapper -Force
        $e = { param($text) [System.Security.SecurityElement]::Escape([string]$text) }
        $xml = @(
            '<service>'
            "  <id>$(& $e $Settings.Name)</id>"
            "  <name>$(& $e $Settings.DisplayName)</name>"
            "  <description>Deployed by Deploy Station</description>"
            "  <executable>$(& $e $Settings.Executable)</executable>"
            "  <arguments>$(& $e $Settings.Arguments)</arguments>"
            "  <workingdirectory>$(& $e $CurrentLink)</workingdirectory>"
            '  <log mode="roll-by-size"><sizeThreshold>10240</sizeThreshold><keepFiles>5</keepFiles></log>'
            '  <onfailure action="restart" delay="10 sec"/>'
            '</service>'
        ) -join "`r`n"
        Set-Content -LiteralPath (Join-Path $serviceDir "$($Settings.Name).xml") -Value $xml -Encoding UTF8
        Write-DsLog "Registering service $($Settings.Name) through WinSW"
        & $wrapper install
        if ($LASTEXITCODE -ne 0) {
            throw "WinSW install failed (exit code $LASTEXITCODE)"
        }
        Set-Service -Name $Settings.Name -StartupType $Settings.StartupType
    } else {
        $binaryPath = '"' + $Settings.Executable + '"'
        if ($Settings.Arguments) {
            $binaryPath += ' ' + $Settings.Arguments
        }
        Write-DsLog "Registering service $($Settings.Name)"
        New-Service -Name $Settings.Name -BinaryPathName $binaryPath -DisplayName $Settings.DisplayName `
            -StartupType $Settings.StartupType | Out-Null
    }
}

function Start-DsServiceApp {
    param($Manifest, [string]$CurrentLink, [string]$AppRoot)
    $settings = Get-DsServiceSettings $Manifest $CurrentLink
    if (-not (Get-Service -Name $settings.Name -ErrorAction SilentlyContinue)) {
        Install-DsService $settings $CurrentLink $AppRoot
    }
    Start-Service -Name $settings.Name
    (Get-Service -Name $settings.Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
    Write-DsLog "Service $($settings.Name) running"
}

function Test-DsServiceStaysRunning {
    param($Manifest, [int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-Service -Name $Manifest.service.serviceName).Status -ne 'Running') {
            return $false
        }
        Start-Sleep -Seconds 1
    }
    return $true
}
