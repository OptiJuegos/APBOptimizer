BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    Add-Type -AssemblyName PresentationFramework
    foreach ($relative in @(
        'private/Update-WinUtilSelections.ps1', 'private/Reset-WPFCheckBoxes.ps1',
        'private/Get-WinUtilEntryToolTip.ps1', 'private/Get-WinUtilToggleStatus.ps1',
        'private/Invoke-WinUtilTweaks.ps1', 'public/Invoke-WPFImpex.ps1',
        'public/Invoke-WPFSelectedCheckboxesUpdate.ps1', 'public/Invoke-WPFUIElements.ps1',
        'public/Invoke-WPFPresets.ps1', 'public/Invoke-WPFButton.ps1',
        'public/Invoke-WPFtweaksbutton.ps1', 'private/Start-WinUtilJob.ps1',
        'private/Step-WinUtilJob.ps1', 'private/Write-WinUtilLog.ps1',
        'private/Measure-WinUtilStep.ps1', 'private/Show-WinUtilMessage.ps1',
        'private/Write-WinUtilErrorRecord.ps1'
    )) { . (Join-Path $script:repoRoot ('functions/' + $relative)) }
}

Describe 'Tweaks UI state' {
BeforeEach {
    $script:sync = [hashtable]::Synchronized(@{
        configs = @{
            tweaks = [pscustomobject]@{
                WPFTweaksExample = [pscustomobject]@{ Content = 'Example'; Category = 'Test' }
                WPFToggleExample = [pscustomobject]@{ Content = 'Toggle'; Category = 'Test'; Type = 'Toggle' }
            }
            preset = [pscustomobject]@{ Standard = @('WPFTweaksExample') }
        }
        selectedTweaks = [Collections.Generic.List[string]]::new()
        selectedToggles = [Collections.Generic.List[string]]::new()
    })
    Mock Invoke-WinUtilTweaks { throw 'A selection operation must not apply tweaks.' }
    Mock Step-WinUtilJob { }
    Mock Write-WinUtilLog { }
    Mock Show-WinUtilMessage { }
    Mock Write-WinUtilErrorRecord { throw $ErrorRecord }
}

AfterEach {
    if ($script:sync.Form -is [Windows.Window]) { $script:sync.Form.Close() }
    Remove-Variable sync -Scope Script -ErrorAction SilentlyContinue
}

Describe 'Tweaks selection state' {
    It 'imports tweaks and toggles into their corresponding lists' {
        Update-WinUtilSelections @('WPFTweaksExample', 'WPFToggleExample')
        @($sync.selectedTweaks) | Should -Be @('WPFTweaksExample')
        @($sync.selectedToggles) | Should -Be @('WPFToggleExample')
    }
    It 'validates an entire replacement before changing the existing selection' {
        $sync.selectedTweaks.Add('WPFTweaksExample')
        { Update-WinUtilSelections @('WPFToggleExample', 'WPFInstallRetired') -Replace } | Should -Throw
        @($sync.selectedTweaks) | Should -Be @('WPFTweaksExample')
        $sync.selectedToggles.Count | Should -Be 0
    }
    It 'rejects unknown tweaks without losing the current selection' {
        $sync.selectedTweaks.Add('WPFTweaksExample')
        { Update-WinUtilSelections @('WPFTweaksUnknown') -Replace } | Should -Throw
        @($sync.selectedTweaks) | Should -Be @('WPFTweaksExample')
    }
    It 'reports retired preset keys and keeps supported keys' {
        @(Update-WinUtilSelections @('WPFInstallRetired', 'WPFTweaksExample') -SkipUnknown) | Should -Be @('WPFInstallRetired')
        @($sync.selectedTweaks) | Should -Be @('WPFTweaksExample')
    }
    It 'adds a checkbox once and removes it on deselection' {
        Invoke-WPFSelectedCheckboxesUpdate Add WPFTweaksExample
        Invoke-WPFSelectedCheckboxesUpdate Add WPFTweaksExample
        $sync.selectedTweaks.Count | Should -Be 1
        Invoke-WPFSelectedCheckboxesUpdate Remove WPFTweaksExample
        $sync.selectedTweaks.Count | Should -Be 0
    }
    It 'restores checkbox state from a preset without applying a tweak' {
        $sync.WPFTweaksExample = [Windows.Controls.CheckBox]::new()
        Invoke-WPFPresets Standard -checkboxfilterpattern 'WPFTweak*'
        $sync.WPFTweaksExample.IsChecked | Should -BeTrue
        Should -Invoke Invoke-WinUtilTweaks -Times 0 -Exactly
    }
}

Describe 'Local JSON import and export' {
    It 'round trips tweak and toggle selections through an actual JSON file' {
        Update-WinUtilSelections @('WPFTweaksExample', 'WPFToggleExample')
        $path = Join-Path $TestDrive 'roundtrip.json'
        Invoke-WPFImpex export -Config $path -ThrowOnError
        $sync.selectedTweaks.Clear()
        $sync.selectedToggles.Clear()
        Invoke-WPFImpex import -Config $path -ThrowOnError
        @($sync.selectedTweaks) | Should -Be @('WPFTweaksExample')
        @($sync.selectedToggles) | Should -Be @('WPFToggleExample')
    }
    It 'rejects unsupported JSON without replacing the current selection' {
        $sync.selectedTweaks.Add('WPFTweaksExample')
        $path = Join-Path $TestDrive 'invalid.json'
        '["WPFToggleExample", "WPFFeatureRetired"]' | Set-Content $path
        { Invoke-WPFImpex import -Config $path -ThrowOnError } | Should -Throw
        @($sync.selectedTweaks) | Should -Be @('WPFTweaksExample')
    }
    It 'restores a rendered toggle on import without executing its tweak' {
        $xml = [xml](Get-Content (Join-Path $script:repoRoot 'xaml/inputXML.xaml') -Raw -Encoding UTF8)
        $reader = [Xml.XmlNodeReader]::new($xml)
        try { $sync.Form = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
        Mock Get-WinUtilToggleStatus { $false }
        Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName tweakspanel -columncount 2
        $path = Join-Path $TestDrive 'toggle.json'
        '["WPFToggleExample"]' | Set-Content $path
        Invoke-WPFImpex import -Config $path -ThrowOnError
        $sync.WPFToggleExample.IsChecked | Should -BeTrue
        Should -Invoke Invoke-WinUtilTweaks -Times 0 -Exactly
        $sync.ImportInProgress | Should -BeNullOrEmpty
    }
    It 'applies an imported toggle when the GUI Apply button is clicked' {
        $path = Join-Path $TestDrive 'apply-toggle.json'
        '["WPFToggleExample"]' | Set-Content $path
        Invoke-WPFImpex import -Config $path -ThrowOnError
        Should -Invoke Invoke-WinUtilTweaks -Times 0 -Exactly

        Mock Invoke-WinUtilTweaks { }
        Mock Start-WinUtilJob { & $ScriptBlock @Parameters }
        Invoke-WPFButton WPFTweaksbutton
        Should -Invoke Invoke-WinUtilTweaks -Times 1 -Exactly -ParameterFilter { $CheckBox -eq 'WPFToggleExample' }
    }
}
}
