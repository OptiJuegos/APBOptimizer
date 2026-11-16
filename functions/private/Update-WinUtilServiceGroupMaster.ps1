function Update-WinUtilServiceGroupMaster {
    param([Parameter(Mandatory)][string]$GroupName)

    $master = $sync[$GroupName]
    if ($null -eq $master -or $master.Tag.Updating) { return }

    $available = 0
    $checked = 0
    foreach ($key in @($master.Tag.Children)) {
        $child = $sync[$key]
        if ($null -eq $child -or -not $child.IsEnabled) { continue }
        $available++
        if ($child.IsChecked -eq $true) { $checked++ }
    }

    # Null is a visual mixed state; IsThreeState stays false so the next user
    # click still means a binary bulk action.
    # A driver group whose installed drivers are all already disabled shows
    # that real state instead of an unchecked, apparently active header.
    $state = if ($available -eq 0) { [bool]$master.Tag.AllAlreadyDisabled }
             elseif ($checked -eq 0) { $false }
             elseif ($checked -eq $available) { $true }
             else { $null }
    $master.Tag.Updating = $true
    try {
        # If every driver is already disabled/protected/absent, allow clicking
        # the header to see an explanation rather than leaving an inert control.
        $master.IsEnabled = ($available -gt 0 -or [bool]$master.Tag.NoManageableDrivers)
        $master.IsChecked = $state
    } finally {
        $master.Tag.Updating = $false
    }
}
