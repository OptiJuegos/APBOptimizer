function Update-WinUtilServiceGroupState {
    <#

    .SYNOPSIS
        Re-reads grouped service startup types after a tweak run

    .DESCRIPTION
        Other tweaks (Telemetry, Services) change the same services, and a failed
        group change leaves Windows as it was. Without a refresh the cached baseline
        and the checkboxes keep showing the state from when the panel was built.
        Entries with a pending choice are left alone so a retry stays queued.

    #>
    param([string]$GroupName)

    if (-not $GroupName) {
        # Refresh every ServiceGroup in the catalog.
        foreach ($property in $sync.configs.tweaks.PSObject.Properties) {
            if ($property.Value.Type -eq 'ServiceGroup') {
                Update-WinUtilServiceGroupState -GroupName $property.Name
            }
        }
        return
    }

    $group = $sync.configs.tweaks.$GroupName
    if (-not $group -or $null -eq $sync.ToggleStatusCache) { return }

    $states = @{}
    foreach ($key in @($group.Children)) {
        if ($null -ne $sync.PendingGroupSelections -and $sync.PendingGroupSelections.ContainsKey($key)) { continue }
        # Missing services read as not disabled; their checkboxes are hidden.
        $states[$key] = [bool](Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache)
        $sync.ToggleStatusCache[$key] = $states[$key]
    }
    if ($states.Count -eq 0) { return }

    Invoke-WPFUIThread -Parameters @{ States = $states; GroupName = $GroupName } -ScriptBlock {
        param($States, $GroupName)
        foreach ($key in @($States.Keys)) {
            $checkbox = $sync[$key]
            if ($null -eq $checkbox -or $checkbox.IsChecked -eq $States[$key]) { continue }
            # Updating keeps the change handler from staging a phantom operation.
            $checkbox.Tag.Updating = $true
            try { $checkbox.IsChecked = $States[$key] }
            finally { $checkbox.Tag.Updating = $false }
            Invoke-WPFSelectedCheckboxesUpdate -type $(if ($States[$key]) { 'Add' } else { 'Remove' }) -checkboxName $key
        }
        Update-WinUtilServiceGroupMaster -GroupName $GroupName
    }
}
