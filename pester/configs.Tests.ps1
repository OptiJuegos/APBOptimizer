#===========================================================================
# Tests - Config Files
#===========================================================================

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$configRoot = Join-Path $PSScriptRoot "..\config"
$functionRoot = Join-Path $repoRoot "functions"
$xamlPath = Join-Path $repoRoot "xaml\inputXML.xaml"
$mainScriptPath = Join-Path $repoRoot "scripts\main.ps1"
$buttonScriptPath = Join-Path $repoRoot "functions\public\Invoke-WPFButton.ps1"
$configCases = @(
    Get-ChildItem -Path $configRoot -Filter *.json | ForEach-Object {
        @{
            Name = $_.Name
            Path = $_.FullName
        }
    }
)

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $script:configRoot = Join-Path $script:repoRoot "config"
    $script:functionRoot = Join-Path $script:repoRoot "functions"
    $script:xamlPath = Join-Path $script:repoRoot "xaml\inputXML.xaml"
    $script:mainScriptPath = Join-Path $script:repoRoot "scripts\main.ps1"
    $script:buttonScriptPath = Join-Path $script:repoRoot "functions\public\Invoke-WPFButton.ps1"

function script:Get-WinUtilConfigObject {
    param([string]$Name)

    Get-Content -Path (Join-Path $script:configRoot "$Name.json") -Raw | ConvertFrom-Json
}

function script:Test-WinUtilHasProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return @($Object.PSObject.Properties.Name) -contains $Name
}

function script:Test-WinUtilHasNonEmptyProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-WinUtilHasProperty -Object $Object -Name $Name)) {
        return $false
    }

    $value = $Object.$Name
    if ($null -eq $value) {
        return $false
    }

    if ($value -is [string]) {
        return -not [string]::IsNullOrWhiteSpace($value)
    }

    if ($value -is [array]) {
        return @($value).Count -gt 0
    }

    return -not [string]::IsNullOrWhiteSpace([string]$value)
}

function script:Get-WinUtilMissingRequiredFields {
    param(
        [Parameter(Mandatory)]
        [string]$EntryName,

        [Parameter(Mandatory)]
        [psobject]$Entry,

        [Parameter(Mandatory)]
        [string[]]$RequiredFields
    )

    foreach ($field in $RequiredFields) {
        if (-not (Test-WinUtilHasNonEmptyProperty -Object $Entry -Name $field)) {
            "$EntryName missing $field"
        }
    }
}

function script:Get-WinUtilTopLevelFunctionNames {
    Get-ChildItem -Path $script:functionRoot -Filter *.ps1 -Recurse | ForEach-Object {
        $tokens = $null
        $syntaxErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$syntaxErrors)
        if ($syntaxErrors.Count -ne 0) {
            throw ($syntaxErrors | Out-String)
        }

        $ast.EndBlock.Statements |
            Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } |
            ForEach-Object { $_.Name }
    } | Sort-Object -Unique
}

function script:Get-WinUtilButtonSwitchNames {
    $buttonSource = Get-Content -Path $script:buttonScriptPath -Raw
    [regex]::Matches($buttonSource, '["''](WPF[A-Za-z0-9_]+)["'']\s*\{') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
}
}

Describe "Config files" {
    foreach ($configCase in $configCases) {
        It "imports $($configCase.Name) with no JSON errors" -TestCases $configCase {
            param([string]$Name, [string]$Path)

            try {
                Get-Content -Path $Path -Raw | ConvertFrom-Json | Out-Null
            } catch {
                throw "Failed to import ${Name}: $_"
            }
        }
    }
}



Describe "Tweaks config" {
    $testCase = @{ Path = (Join-Path $configRoot "tweaks.json") }

    It "contains undo metadata for registry and service actions" -TestCases $testCase {
        param([string]$Path)

        $tweaks = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $invalidTweaks = New-Object System.Collections.Generic.List[string]

        foreach ($tweak in $tweaks.PSObject.Properties) {
            foreach ($registryEntry in @($tweak.Value.registry)) {
                if ($null -eq $registryEntry) { continue }

                if ($registryEntry.Values) {
                    if ($registryEntry.PSObject.Properties.Name -notcontains "DefaultValue" -or
                        [string]::IsNullOrWhiteSpace([string]$registryEntry.DefaultValue)) {
                        $invalidTweaks.Add("$($tweak.Name),registry")
                    }
                    continue
                }

                if ($registryEntry.PSObject.Properties.Name -notcontains "OriginalValue" -or
                    [string]::IsNullOrWhiteSpace([string]$registryEntry.OriginalValue)) {
                    $invalidTweaks.Add("$($tweak.Name),registry")
                }
            }

            foreach ($serviceEntry in @($tweak.Value.service)) {
                if ($null -eq $serviceEntry) { continue }

                if ($serviceEntry.PSObject.Properties.Name -notcontains "OriginalType" -or
                    [string]::IsNullOrWhiteSpace([string]$serviceEntry.OriginalType)) {
                    $invalidTweaks.Add("$($tweak.Name),service")
                }
            }
        }

        if ($invalidTweaks.Count -gt 0) {
            throw ($invalidTweaks -join "`n")
        }
    }

    It "keeps the location service disabled" -TestCases $testCase {
        param([string]$Path)

        $tweaks = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $locationServices = @($tweaks.WPFTweaksLocation.service | Where-Object Name -eq "lfsvc")

        $locationServices | Should -HaveCount 1
        $locationServices[0].StartupType | Should -Be "Disabled"
    }

    $icaclsPrincipalCases = @(
        @{
            Path          = (Join-Path $configRoot "tweaks.json")
            Tweak         = "WPFTweaksDisableStoreSearch"
            Sid           = '*S-1-1-0'
            ExpectedCount = 2
        }
        @{
            Path          = (Join-Path $configRoot "tweaks.json")
            Tweak         = "WPFTweaksRazerBlock"
            Sid           = '*S-1-1-0'
            ExpectedCount = 2
        }
        @{
            Path          = (Join-Path $configRoot "tweaks.json")
            Tweak         = "WPFTweaksRemoveOneDrive"
            Sid           = '*S-1-5-32-544'
            ExpectedCount = 2
        }
    )

    It "identifies the <Tweak> icacls principal by SID" -TestCases $icaclsPrincipalCases {
        param([string]$Path, [string]$Tweak, [string]$Sid, [int]$ExpectedCount)

        $tweaks = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $scripts = (@($tweaks.$Tweak.InvokeScript) + @($tweaks.$Tweak.UndoScript)) -join "`n"
        $sidCount = ([regex]::Matches($scripts, [regex]::Escape($Sid))).Count

        $sidCount | Should -Be $ExpectedCount -Because "$Tweak must pass $Sid to icacls at every call site instead of a localized account name"
    }
}

Describe "Preset config" {
    It "references existing config entries or supported actions" {
        $preset = Get-WinUtilConfigObject -Name "preset"
        $tweaks = Get-WinUtilConfigObject -Name "tweaks"

        $validReferences = @(
            $tweaks.PSObject.Properties.Name
            Get-WinUtilButtonSwitchNames
        ) | Sort-Object -Unique

        $invalidReferences = New-Object System.Collections.Generic.List[string]
        foreach ($presetEntry in $preset.PSObject.Properties) {
            foreach ($reference in @($presetEntry.Value)) {
                if ($validReferences -notcontains $reference) {
                    $invalidReferences.Add("$($presetEntry.Name) references missing item $reference")
                }
            }
        }

        if ($invalidReferences.Count -gt 0) {
            throw ($invalidReferences -join "`n")
        }
    }
}



Describe "UI-rendered config entries" {


    It "contains required DNS fields with parseable IP addresses" {
        $dns = Get-WinUtilConfigObject -Name "dns"
        $requiredFields = @("Primary", "Secondary", "Primary6", "Secondary6")
        $invalidEntries = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $dns.PSObject.Properties) {
            foreach ($missingField in (Get-WinUtilMissingRequiredFields -EntryName $entry.Name -Entry $entry.Value -RequiredFields $requiredFields)) {
                $invalidEntries.Add($missingField)
            }

            foreach ($field in $requiredFields) {
                if (-not (Test-WinUtilHasNonEmptyProperty -Object $entry.Value -Name $field)) {
                    continue
                }

                try {
                    [System.Net.IPAddress]::Parse([string]$entry.Value.$field) | Out-Null
                } catch {
                    $invalidEntries.Add("$($entry.Name) $field is not a parseable IP address")
                }
            }
        }

        if ($invalidEntries.Count -gt 0) {
            throw ($invalidEntries -join "`n")
        }
    }

    It "exposes every configured DNS provider in the DNS combobox" {
        $dns = Get-WinUtilConfigObject -Name "dns"
        $tweaks = Get-WinUtilConfigObject -Name "tweaks"
        $comboItems = @($tweaks.WPFchangedns.ComboItems -split " ")
        $missingProviders = @($dns.PSObject.Properties.Name | Where-Object { $comboItems -notcontains $_ })

        if ($missingProviders.Count -gt 0) {
            throw "WPFchangedns missing providers: $($missingProviders -join ', ')"
        }
    }



    It "contains required tweak fields and valid action metadata" {
        $tweaks = Get-WinUtilConfigObject -Name "tweaks"
        $requiredFields = @("Content", "category", "panel", "link")
        $allowedTypes = @("Button", "Combobox", "Toggle", "ToggleButton", "ServiceGroup", "DriverGroup", "TaskGroup")
        $allowedServiceStartupTypes = @("Automatic", "AutomaticDelayedStart", "Disabled", "Manual")
        $supportedButtons = Get-WinUtilButtonSwitchNames
        $invalidEntries = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $tweaks.PSObject.Properties) {
            foreach ($missingField in (Get-WinUtilMissingRequiredFields -EntryName $entry.Name -Entry $entry.Value -RequiredFields $requiredFields)) {
                $invalidEntries.Add($missingField)
            }

            if ($entry.Value.Type -and $allowedTypes -notcontains $entry.Value.Type) {
                $invalidEntries.Add("$($entry.Name) has unsupported Type '$($entry.Value.Type)'")
            }

            if ($entry.Value.Type -eq "Button") {
                if ($supportedButtons -notcontains $entry.Name) {
                    $invalidEntries.Add("$($entry.Name) is not handled by Invoke-WPFButton")
                }
            } elseif ($entry.Value.Type -eq "Combobox") {
                if (-not (Test-WinUtilHasNonEmptyProperty -Object $entry.Value -Name "ComboItems")) {
                    $invalidEntries.Add("$($entry.Name) combobox missing ComboItems")
                }
                $statefulRegistry = @($entry.Value.registry | Where-Object Values)
                if ($statefulRegistry.Count -gt 0) {
                    $comboItems = if ($entry.Value.ComboItems -is [string]) {
                        if ($entry.Value.ComboItems.Contains("|")) {
                            @($entry.Value.ComboItems -split "\|")
                        } else {
                            @($entry.Value.ComboItems -split " ")
                        }
                    } else {
                        @($entry.Value.ComboItems)
                    }
                    if ($statefulRegistry.Count -ne @($entry.Value.registry).Count) {
                        $invalidEntries.Add("$($entry.Name) registry states must all use Values")
                    } else {
                    foreach ($setting in $statefulRegistry) {
                        if (Compare-Object $comboItems @($setting.Values.PSObject.Properties.Name)) {
                            $invalidEntries.Add("$($entry.Name) ComboItems and registry states do not match")
                        }
                    }
                    }
                }
            } elseif ($entry.Value.Type -in @('ServiceGroup', 'DriverGroup', 'TaskGroup')) {
                if (-not $entry.Value.Children -or @($entry.Value.Children).Count -eq 0) {
                    $invalidEntries.Add("$($entry.Name) service group has no children")
                } else {
                    foreach ($childKey in @($entry.Value.Children)) {
                        $childConfig = $tweaks.PSObject.Properties[$childKey]
                        if (-not $childConfig -or $childConfig.Value.ParentGroup -ne $entry.Name -or $childConfig.Value.Type -ne 'Toggle' -or
                            ($entry.Value.Type -eq 'DriverGroup' -and -not $childConfig.Value.driver.Name) -or
                            ($entry.Value.Type -eq 'TaskGroup' -and -not $childConfig.Value.scheduledTask.Name)) {
                            $invalidEntries.Add("$($entry.Name) invalid service child $childKey")
                        }
                    }
                }
            } else {
                if (-not (Test-WinUtilHasNonEmptyProperty -Object $entry.Value -Name "Description")) {
                    $invalidEntries.Add("$($entry.Name) missing Description")
                }

                if (-not $entry.Value.registry -and -not $entry.Value.service -and -not $entry.Value.InvokeScript -and -not $entry.Value.appx) {
                    $invalidEntries.Add("$($entry.Name) missing registry, service, InvokeScript, or appx action")
                }
            }

            foreach ($registryEntry in @($entry.Value.registry)) {
                if ($null -eq $registryEntry) { continue }

                $requiredRegistryFields = if ($entry.Value.Type -eq "Combobox" -and $statefulRegistry.Count -gt 0) {
                    @("Path", "Name", "Type", "DefaultValue", "Values")
                } else {
                    @("Path", "Name", "Type", "Value", "OriginalValue")
                }
                foreach ($missingField in (Get-WinUtilMissingRequiredFields -EntryName "$($entry.Name),registry" -Entry $registryEntry -RequiredFields $requiredRegistryFields)) {
                    $invalidEntries.Add($missingField)
                }
            }

            foreach ($serviceEntry in @($entry.Value.service)) {
                if ($null -eq $serviceEntry) { continue }

                foreach ($missingField in (Get-WinUtilMissingRequiredFields -EntryName "$($entry.Name),service" -Entry $serviceEntry -RequiredFields @("Name", "StartupType", "OriginalType"))) {
                    $invalidEntries.Add($missingField)
                }

                foreach ($startupTypeField in @("StartupType", "OriginalType")) {
                    if ((Test-WinUtilHasNonEmptyProperty -Object $serviceEntry -Name $startupTypeField) -and
                        $allowedServiceStartupTypes -notcontains $serviceEntry.$startupTypeField) {
                        $invalidEntries.Add("$($entry.Name),service has unsupported $startupTypeField '$($serviceEntry.$startupTypeField)'")
                    }
                }
            }
        }

        if ($invalidEntries.Count -gt 0) {
            throw ($invalidEntries -join "`n")
        }
    }

    It "defines theme resources required by XAML rendering" {
        $themes = Get-WinUtilConfigObject -Name "themes"
        $invalidEntries = New-Object System.Collections.Generic.List[string]

        foreach ($themeName in @("shared", "Light", "Dark")) {
            if (-not (Test-WinUtilHasProperty -Object $themes -Name $themeName)) {
                $invalidEntries.Add("themes.json missing $themeName")
                continue
            }

            foreach ($property in $themes.$themeName.PSObject.Properties) {
                if ([string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $invalidEntries.Add("$themeName.$($property.Name) is blank")
                }
            }
        }

        $lightKeys = @($themes.Light.PSObject.Properties.Name)
        $darkKeys = @($themes.Dark.PSObject.Properties.Name)
        foreach ($key in $lightKeys) {
            if ($darkKeys -notcontains $key) {
                $invalidEntries.Add("Dark theme missing $key")
            }
        }
        foreach ($key in $darkKeys) {
            if ($lightKeys -notcontains $key) {
                $invalidEntries.Add("Light theme missing $key")
            }
        }

        $xamlText = Get-Content -Path $script:xamlPath -Raw
        $dynamicResourceNames = @(
            [regex]::Matches($xamlText, '\{DynamicResource\s+([^\}\s]+)') |
                ForEach-Object { $_.Groups[1].Value }
        ) | Sort-Object -Unique
        $xamlDefinedResourceNames = @(
            [regex]::Matches($xamlText, 'x:Key="([^"]+)"') |
                ForEach-Object { $_.Groups[1].Value }
        ) | Sort-Object -Unique
        $themeResourceNames = @(
            $themes.shared.PSObject.Properties.Name
            $themes.Light.PSObject.Properties.Name
            $themes.Dark.PSObject.Properties.Name
            "CBorderColor"
            "CButtonBackgroundMouseoverColor"
        ) | Sort-Object -Unique

        foreach ($resourceName in $dynamicResourceNames) {
            if ($xamlDefinedResourceNames -notcontains $resourceName -and $themeResourceNames -notcontains $resourceName) {
                $invalidEntries.Add("XAML DynamicResource '$resourceName' is not defined in themes.json or XAML resources")
            }
        }

        if ($invalidEntries.Count -gt 0) {
            throw ($invalidEntries -join "`n")
        }
    }
}

Describe "Embedded config scripts" {
    It "parse as PowerShell scriptblocks" {
        $invalidScripts = New-Object System.Collections.Generic.List[string]

        foreach ($configFile in (Get-ChildItem -Path $script:configRoot -Filter *.json)) {
            $config = Get-Content -Path $configFile.FullName -Raw | ConvertFrom-Json
            foreach ($entry in $config.PSObject.Properties) {
                foreach ($field in @("InvokeScript", "UndoScript")) {
                    if (-not (Test-WinUtilHasProperty -Object $entry.Value -Name $field)) {
                        continue
                    }

                    $index = 0
                    foreach ($scriptText in @($entry.Value.$field)) {
                        $index++
                        if ([string]::IsNullOrWhiteSpace([string]$scriptText)) {
                            continue
                        }

                        try {
                            [scriptblock]::Create([string]$scriptText) | Out-Null
                        } catch {
                            $invalidScripts.Add("$($configFile.Name):$($entry.Name).$field[$index] $($psitem.Exception.Message)")
                        }
                    }
                }
            }
        }

        if ($invalidScripts.Count -gt 0) {
            throw ($invalidScripts -join "`n")
        }
    }
}
