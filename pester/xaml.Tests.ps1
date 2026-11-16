BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    Add-Type -AssemblyName PresentationFramework
    $script:xaml = [xml](Get-Content (Join-Path $script:repoRoot 'xaml/inputXML.xaml') -Raw -Encoding UTF8)
    $script:tweaks = Get-Content (Join-Path $script:repoRoot 'config/tweaks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($file in Get-ChildItem (Join-Path $script:repoRoot 'functions') -Recurse -Filter '*.ps1') { . $file.FullName }
}
Describe 'Tweaks WPF interface' {
    BeforeEach {
        $reader = [Xml.XmlNodeReader]::new($script:xaml)
        try { $script:window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
        $script:sync = [hashtable]::Synchronized(@{ Form = $script:window; configs = @{ tweaks = $script:tweaks } })
        Mock Get-WinUtilToggleStatus { $false }
        Mock Get-WinUtilRegistryComboState { throw 'Registry reads are isolated in this UI test.' }
        Mock Invoke-WinUtilTweaks { throw 'UI construction must not execute tweaks.' }
        Mock Set-WinUtilRegistryComboState { throw 'UI construction must not write registry values.' }
    }
    AfterEach { $script:window.Close() }
    It 'loads Tweaks and Advanced, with About in Settings, without showing the window' {
        $tabs = $window.FindName('WPFTabNav').Items
        $tabs.Count | Should -Be 2
        $tabs[0].Name | Should -Be 'WPFTab2'
        $tabs[1].Name | Should -Be 'WPFAdvancedTab'
        $tabs[1].Header | Should -Be 'Advanced'
        $window.FindName('WPFCreditsTab') | Should -BeNullOrEmpty
        $window.FindName('WPFCreditsTabBT') | Should -BeNullOrEmpty
        $window.FindName('AboutMenuItem').Header | Should -Be 'About'
        $window.IsVisible | Should -BeFalse
    }
    It 'contains the controls required for search, presets and apply/undo' {
        foreach ($name in @('SearchBar','WPFSearchBarContainer','WPFTab2BT','WPFAdvancedTabBT','WPFAdvancedTab','WPFDisableWindowsUpdate','WPFRestoreWindowsUpdate','WPFWindowsUpdateStatus','AboutMenuItem','tweakspanel','WPFstandard','WPFminimal','WPFAdvanced','WPFTweaksbutton','WPFUndoall','WPFClearTweaksSelection','WPFGetInstalledTweaks','WPFTweakHelpPopup','WPFTweakHelpTitle','WPFTweakHelpChanges','WPFTweakHelpUndo','WPFTweakHelpClose','WPFTweakHelpDocs')) {
            $window.FindName($name) | Should -Not -BeNullOrEmpty -Because "the Tweaks UI requires $name"
        }
    }
    It 'has unique named controls' {
        $duplicates = @($script:xaml.SelectNodes('//*[@Name and not(ancestor::*[local-name()="ControlTemplate" or local-name()="DataTemplate"])]') | Group-Object { $_.GetAttribute('Name') } | Where-Object Count -GT 1)
        $duplicates.Count | Should -Be 0
    }
    It 'renders every retained catalog control without applying any tweaks' {
        Invoke-WPFUIElements -configVariable $script:tweaks -targetGridName tweakspanel -columncount 2
        $pause = $sync.WPFTweaksPauseWindows2099
        $pause | Should -Not -BeNullOrEmpty
        $pause | Should -BeOfType [Windows.Controls.CheckBox]
        $window.FindName('WPFPauseWindows2099') | Should -BeNullOrEmpty
        foreach ($entry in $script:tweaks.PSObject.Properties) {
            if ($entry.Value.Type -ne 'Note') { $sync[$entry.Name] | Should -Not -BeNullOrEmpty -Because "$($entry.Name) must be rendered" }
        }
        Should -Invoke Invoke-WinUtilTweaks -Times 0 -Exactly
        Should -Invoke Set-WinUtilRegistryComboState -Times 0 -Exactly
    }
    It 'routes every catalog action button to an existing dispatcher case' {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repoRoot 'functions/public/Invoke-WPFButton.ps1'), [ref]$null, [ref]$null)
        $switches = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] }, $true)
        $cases = @($switches | ForEach-Object { $_.Clauses | ForEach-Object { $_.Item1.Value } })
        foreach ($entry in $script:tweaks.PSObject.Properties) {
            if ($entry.Value.Type -eq 'Button') { $cases | Should -Contain $entry.Name }
        }
    }
}
