function Invoke-WPFTab {
    param(
        [Parameter(Mandatory = $true)][string]$ClickedTab,
        [switch]$Yield
    )

    # Keep an explicit mapping. Upstream's positional six-tab navigation is gone.
    $tabName = switch ($ClickedTab) {
        'WPFTab2BT' { 'Tweaks' }
        'WPFAdvancedTabBT' { 'Advanced' }
        default { return }
    }
    $targetTab = switch ($tabName) {
        'Tweaks' { $sync.WPFTab2 }
        'Advanced' { $sync.WPFAdvancedTab }
    }
    if ($null -eq $targetTab) {
        throw "The $tabName tab is missing from the interface."
    }

    $sync.WPFTabNav.SelectedItem = $targetTab
    $sync.WPFTab2BT.IsChecked = ($tabName -eq 'Tweaks')
    $sync.WPFAdvancedTabBT.IsChecked = ($tabName -eq 'Advanced')
    $sync.currentTab = $tabName

    if ($tabName -eq 'Tweaks') {
        $wasInitialized = ($null -ne $sync.InitializedTabs -and [bool]$sync.InitializedTabs['Tweaks'])
        Initialize-WinUtilTabContent -TabName 'Tweaks' -Yield:$Yield
        $sync.WPFSearchBarContainer.Visibility = [System.Windows.Visibility]::Visible
        $sync.SearchBarClearButton.Visibility = if ($sync.SearchBar.Text) { 'Visible' } else { 'Collapsed' }
        if ($wasInitialized -and $sync.SearchBar.Text) {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
    } else {
        $sync.WPFSearchBarContainer.Visibility = [System.Windows.Visibility]::Collapsed
        $sync.SearchBarClearButton.Visibility = [System.Windows.Visibility]::Collapsed
        if ($tabName -eq 'Advanced') {
            Update-WinUtilWindowsUpdateStatusUI
        }
    }
}
