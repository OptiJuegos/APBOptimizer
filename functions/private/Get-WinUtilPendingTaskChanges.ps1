function Get-WinUtilPendingTaskChanges {
    # Take a snapshot on the UI thread before passing it to the job. The
    # scheduler is modified only by the Apply worker, never by checkbox events.
    if ($null -eq $sync.PendingTaskSelections) { return @() }
    [System.Threading.Monitor]::Enter($sync.PendingTaskSelections.SyncRoot)
    try {
        return @($sync.PendingTaskSelections.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ Key = [string]$_.Key; Disable = [bool]$_.Value }
        })
    } finally {
        [System.Threading.Monitor]::Exit($sync.PendingTaskSelections.SyncRoot)
    }
}

function Invoke-WinUtilPendingTaskChanges {
    param([object[]]$Changes)
    foreach ($change in @($Changes)) {
        $key = [string]$change.Key
        $entry = $sync.configs.tweaks.PSObject.Properties[$key]
        if (-not $entry -or $entry.Value.ParentGroup -ne 'WPFTaskGroupTelemetry' -or
            -not $entry.Value.scheduledTask.Name) {
            throw "Invalid scheduled-task selection '$key'."
        }

        $desired = [bool]$change.Disable
        $actual = Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache -StopOnReadError
        if ($actual -ne $desired) {
            Invoke-WinUtilTweaks $key -undo (-not $desired)
        }

        # Verify even when the previous operation was a no-op. Do not discard
        # pending work or report success if scheduler access was denied.
        $verified = Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache -StopOnReadError
        if ($verified -ne $desired) {
            throw "Could not apply the selected scheduled-task state for '$key'."
        }
        if ($null -ne $sync.ToggleStatusCache) { $sync.ToggleStatusCache[$key] = $verified }
        if ($null -ne $sync.PendingTaskSelections) {
            [System.Threading.Monitor]::Enter($sync.PendingTaskSelections.SyncRoot)
            try {
                if ($sync.PendingTaskSelections.ContainsKey($key) -and
                    [bool]$sync.PendingTaskSelections[$key] -eq $desired) {
                    $sync.PendingTaskSelections.Remove($key)
                }
            } finally {
                [System.Threading.Monitor]::Exit($sync.PendingTaskSelections.SyncRoot)
            }
        }
    }
}
