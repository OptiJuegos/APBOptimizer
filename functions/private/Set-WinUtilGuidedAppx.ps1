function Get-WinUtilGuidedAppxPresentation {
    param($Package, [hashtable]$StartNames)

    $name = [string]$Package.Name
    $iconPath = ''
    try {
        $manifestPath = Join-Path $Package.InstallLocation 'AppxManifest.xml'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop
            foreach ($application in $manifest.SelectNodes("//*[local-name()='Application']")) {
                $appId = "$($Package.PackageFamilyName)!$($application.Id)"
                $visual = $application.SelectSingleNode("./*[local-name()='VisualElements']")
                $visualName = if ($visual) { [string]$visual.DisplayName } else { '' }
                if ($StartNames.ContainsKey($appId)) { $name = [string]$StartNames[$appId] }
                elseif ($visualName -and $visualName -notlike 'ms-resource:*') { $name = $visualName }
                $logo = if ($visual) { [string]$visual.Square44x44Logo } else { '' }
                if ($logo) {
                    $candidate = Join-Path $Package.InstallLocation $logo
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $iconPath = $candidate }
                    else {
                        $directory = Split-Path $candidate -Parent
                        if (Test-Path -LiteralPath $directory -PathType Container) {
                            $base = [IO.Path]::GetFileNameWithoutExtension($candidate)
                            $variant = Get-ChildItem -LiteralPath $directory -Filter "$base.*.png" -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
                            if ($variant) { $iconPath = $variant.FullName }
                        }
                    }
                }
                break
            }
            if ($name -eq [string]$Package.Name) {
                $displayName = [string]$manifest.Package.Properties.DisplayName
                if ($displayName -and $displayName -notlike 'ms-resource:*') { $name = $displayName }
            }
        }
    } catch {
        Write-WinUtilLog -Component 'GuidedAppx' -Level 'WARN' -Message "Cannot read presentation for $($Package.Name): $($_.Exception.Message)"
    }
    if ($name -eq [string]$Package.Name -and $Package.PackageFamilyName) {
        $prefix = "$($Package.PackageFamilyName)!"
        $appId = @($StartNames.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object | Select-Object -First 1)
        if ($appId.Count) { $name = [string]$StartNames[$appId[0]] }
    }
    if ($name -eq 'Microsoft.XboxSpeechToTextOverlay') { $name = 'Xbox Speech to Text Overlay' }
    if (-not $iconPath -and $Package.InstallLocation -and (Test-Path -LiteralPath $Package.InstallLocation -PathType Container)) {
        $executables = @(Get-ChildItem -LiteralPath $Package.InstallLocation -Filter '*.exe' -File -ErrorAction SilentlyContinue)
        if ($executables.Count -eq 1) { $iconPath = $executables[0].FullName }
    }
    [pscustomobject]@{
        Label = $name
        Icon = Get-WinUtilStartupIcon $iconPath
    }
}

function Get-WinUtilGuidedAppxEntries {
    param([switch]$NoPresentation)
    # Only expose consumer packages; keep Windows system apps, dependencies and runtimes untouched.
    $microsoftApps = @(
        'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather',
        'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.Microsoft3DViewer',
        'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MixedReality.Portal', 'Microsoft.OutlookForWindows',
        'Microsoft.People', 'Microsoft.PowerAutomateDesktop', 'Microsoft.SkypeApp',
        'Microsoft.Todos', 'Microsoft.WindowsAlarms', 'Microsoft.WindowsCamera',
        'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps',
        'Microsoft.WindowsSoundRecorder', 'Microsoft.YourPhone',
        'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo',
        'Microsoft.Windows.Photos', 'Microsoft.WindowsNotepad', 'Microsoft.Paint',
        'Microsoft.ScreenSketch', 'Microsoft.WindowsCalculator',
        'Microsoft.GamingApp', 'Microsoft.XboxApp', 'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxSpeechToTextOverlay', 'MicrosoftTeams', 'MSTeams',
        'microsoft.windowscommunicationsapps'
    )
    $packages = @(Get-AppxPackage -ErrorAction Stop)
    $startNames = @{}
    if (-not $NoPresentation -and (Get-Command Get-StartApps -ErrorAction SilentlyContinue)) {
        try { Get-StartApps -ErrorAction Stop | ForEach-Object { $startNames[[string]$_.AppID] = [string]$_.Name } }
        catch { Write-WinUtilLog -Component 'GuidedAppx' -Level 'WARN' -Message "Cannot read Start app names: $($_.Exception.Message)" }
    }
    foreach ($package in $packages) {
        if (-not $package.PackageFullName -or -not $package.Name -or
            $package.NonRemovable -or $package.IsFramework -or $package.IsResourcePackage -or
            [string]$package.SignatureKind -eq 'System' -or
            [string]$package.InstallLocation -match '(?i)\\Windows\\SystemApps\\') { continue }

        $name = [string]$package.Name
        if ($name -in @('NVIDIACorp.NVIDIAControlPanel', 'AdvancedMicroDevicesInc-2.AMDRadeonSoftware',
                      'AppUp.IntelGraphicsExperience', 'AppUp.IntelGraphicsControlPanel')) { continue }
        if (($name -match '^(?i:Microsoft|MicrosoftWindows|Windows|microsoft\.)' -or $name -eq 'MSTeams') -and
            $name -cnotin $microsoftApps) { continue }

        $presentation = if (-not $NoPresentation) { Get-WinUtilGuidedAppxPresentation -Package $package -StartNames $startNames } else { $null }

        [pscustomobject]@{
            Id = [string]$package.PackageFullName
            Name = $name
            Label = if ($presentation) { $presentation.Label } else { $name }
            Icon = if ($presentation) { $presentation.Icon } else { $null }
            Publisher = [string]$package.Publisher
            Version = [string]$package.Version
        }
    }
}

function Get-WinUtilGuidedAppxOptions {
    foreach ($entry in @($sync.GuidedAppxEntries)) {
        if (-not $entry) { continue }
        [pscustomobject]@{
            Id = [string]$entry.Id
            Default = $false
            Label = [pscustomobject]@{ en=$entry.Label; es=$entry.Label }
            Detail = [pscustomobject]@{ en="$($entry.Name) · $($entry.Version)"; es="$($entry.Name) · $($entry.Version)" }
            AppxEntry = $entry
            Actions = @()
            Reversible = $false
        }
    }
}

function Request-WinUtilGuidedAppx {
    if ($sync.GuidedAppxLoading -or $sync.GuidedAppxCacheLoaded -or $sync.ActiveJob) { return }
    $sync.GuidedAppxLoading = $true
    $sync.GuidedAppxError = ''
    $token = [guid]::NewGuid().ToString()
    $sync.GuidedAppxScanToken = $token
    Start-WinUtilJob -Name 'GuidedAppxScan' -Description 'Reading installed Store apps' -Parameters @{ Token=$token } -ScriptBlock {
        param($Token)
        $entries = @()
        $errorText = ''
        try {
            $entries = @(Get-WinUtilGuidedAppxEntries | Sort-Object Name,Id)
        } catch {
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'GuidedAppx' -Context 'Read installed Store apps'
            $errorText = 'No se pudo leer la lista de aplicaciones. Revisa el registro.'
        }
        Invoke-WPFUIThread -Parameters @{ Entries=$entries; ErrorText=$errorText; Token=$Token } -ScriptBlock {
            param($Entries,$ErrorText,$Token)
            if ($sync.GuidedAppxScanToken -ne $Token) { return }
            $sync.GuidedAppxEntries = @($Entries)
            $sync.GuidedAppxError = $ErrorText
            $sync.GuidedAppxCacheLoaded = $true
            $sync.GuidedAppxLoading = $false
            if ($sync.GuidedWindow -and $sync.GuidedPanel -eq 'Wizard' -and $sync.GuidedState -and
                @(Get-WinUtilGuidedQuestions)[$sync.GuidedState.Index].DataSource -eq 'AppxPackages') {
                Show-WinUtilGuidedQuestion -Index $sync.GuidedState.Index
            }
        }
    }
    if ($sync.GuidedAppxLoading -and $sync.ActiveJob -ne 'GuidedAppxScan') {
        $sync.GuidedAppxLoading = $false
        $sync.GuidedAppxError = 'No se pudo iniciar la lectura de aplicaciones.'
    }
}

function Invoke-WinUtilGuidedAppxRemoval {
    param([Parameter(Mandatory)][object[]]$Changes)

    $eligible = @(Get-WinUtilGuidedAppxEntries -NoPresentation)
    foreach ($change in $Changes) {
        $installed = @($eligible | Where-Object { $_.Id -ceq [string]$change.Id -and $_.Name -ceq [string]$change.Name })
        if ($installed.Count -ne 1) {
            Write-WinUtilLog -Level 'WARN' -Component 'GuidedAppx' -Message "Package no longer eligible: $($change.Name)"
            continue
        }
        Remove-AppxPackage -Package ([string]$change.Id) -ErrorAction Stop
        Write-WinUtilLog -Component 'GuidedAppx' -Message "Removed current-user package: $($change.Name)"
    }
}
