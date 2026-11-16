function Reset-WPFCheckBoxes {
    <#

    .SYNOPSIS
        Set WinUtil checkboxes to match $sync.selected values.
        Should only need to be run if $sync.selected updated outside of UI (i.e. presets or import)

    .PARAMETER doToggles
        Whether or not to set UI toggles. WARNING: they will trigger if altered

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"
        Used to make reset blazingly fast.
    #>

    param (
        [Parameter(position=0)]
        [bool]$doToggles = $false,

        [Parameter(position=1)]
        [string]$checkboxfilterpattern = "**"
    )
    $selectedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.selectedTweaks), [StringComparer]::OrdinalIgnoreCase)

    # A synchronized Hashtable protects individual operations, not enumeration. Materialize the
    # snapshot under its lock, then release it before handlers run and mutate $sync.
    [System.Threading.Monitor]::Enter($sync.SyncRoot)
    try {
        $syncEntries = @($sync.GetEnumerator())
    } finally {
        [System.Threading.Monitor]::Exit($sync.SyncRoot)
    }
    foreach ($syncEntry in $syncEntries) {
        if ($syncEntry.Value -is [System.Windows.Controls.CheckBox] -and $syncEntry.Name -notlike "WPFToggle*" -and $syncEntry.Name -notlike "WPFServiceGroup*" -and $syncEntry.Name -notlike "WPFDriverGroup*" -and $syncEntry.Name -notlike "WPFTaskGroup*" -and $syncEntry.Name -like $checkboxfilterpattern) {
            $checkboxName = $syncEntry.Key
            $sync.$checkboxName.IsChecked = $selectedSet.Contains($checkboxName)
        }
    }

    if($doToggles) {
        # Restore toggle switch states from imported config.
        # Only act on toggles that are explicitly listed in the import - toggles absent
        # from the export file were not part of the saved config and should keep whatever
        # state the live system already has (set during UI initialisation via Get-WinUtilToggleStatus).
        $importedToggles = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.selectedToggles), [StringComparer]::OrdinalIgnoreCase)
        [System.Threading.Monitor]::Enter($sync.SyncRoot)
        try {
            $toggleEntries = @($sync.GetEnumerator())
        } finally {
            [System.Threading.Monitor]::Exit($sync.SyncRoot)
        }
        foreach ($toggle in $toggleEntries) {
            if ($toggle.Key -like "WPFToggle*" -and $toggle.Value -is [System.Windows.Controls.CheckBox] -and $importedToggles.Contains($toggle.Key)) {
                $sync[$toggle.Key].IsChecked = $true
                $parentGroup = [string]$sync.configs.tweaks.$($toggle.Key).ParentGroup
                if ($parentGroup -in @('WPFTaskGroupTelemetry', 'WPFServiceGroupDiagnostics', 'WPFServiceGroupUseless', 'WPFDriverGroupOptional') -and $sync.Form -and
                    $sync[$toggle.Key].IsEnabled -and $sync[$toggle.Key].Visibility -eq [System.Windows.Visibility]::Visible) {
                    $pendingName = if ($parentGroup -eq 'WPFTaskGroupTelemetry') {
                        'PendingTaskSelections'
                    } else {
                        'PendingGroupSelections'
                    }
                    if ($null -eq $sync[$pendingName]) {
                        $sync[$pendingName] = [hashtable]::Synchronized(@{})
                    }
                    # Import stages Apply; language redraws preserve explicit
                    # pending restores and must not create phantom operations.
                    if (-not $sync[$pendingName].ContainsKey($toggle.Key)) {
                        $actual = Get-WinUtilToggleStatus -ToggleSwitch $toggle.Key
                        if (-not $actual) { $sync[$pendingName][$toggle.Key] = $true }
                    }
                }
            }
            # Toggles not present in the import are intentionally left untouched;
            # their current UI state already reflects the real system state.
        }
    }
}
