function Get-WinUtilPendingGroupChanges {
    # Snapshot service/driver selections on the UI thread. Checkbox handlers
    # only edit this synchronized table, never touch Windows.
    if ($null -eq $sync.PendingGroupSelections) { return @() }
    [System.Threading.Monitor]::Enter($sync.PendingGroupSelections.SyncRoot)
    try {
        return @($sync.PendingGroupSelections.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ Key = [string]$_.Key; Disable = [bool]$_.Value }
        })
    } finally {
        [System.Threading.Monitor]::Exit($sync.PendingGroupSelections.SyncRoot)
    }
}

function Invoke-WinUtilPendingGroupChanges {
    param([object[]]$Changes)
    foreach ($change in @($Changes)) {
        $key = [string]$change.Key
        $property = $sync.configs.tweaks.PSObject.Properties[$key]
        if (-not $property -or $property.Value.ParentGroup -notin @('WPFServiceGroupDiagnostics', 'WPFServiceGroupUseless', 'WPFDriverGroupOptional')) {
            throw "Invalid service/driver group selection '$key'."
        }
        $entry = $property.Value
        if (-not $entry.driver.Name -and -not $entry.service) {
            throw "Invalid service/driver group member '$key'."
        }

        $desired = [bool]$change.Disable
        # One refused service must not abort the rest of the run. The failure is
        # logged and counted, and its pending entry stays queued for retry.
        try {
            $actual = Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache -StopOnReadError
            if ($actual -ne $desired) {
                Invoke-WinUtilTweaks -CheckBox $key -undo (-not $desired)
            }
            $verified = Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache -StopOnReadError
            if ($verified -ne $desired) {
                # Set-WinUtilService only warns, so name the state Windows kept.
                $detail = if ($entry.service) {
                    $observed = @($entry.service | ForEach-Object {
                        $service = Get-Service -Name $_.Name -ErrorAction SilentlyContinue
                        $startType = if ($service) { [string]$service.StartType } else { 'missing' }
                        $expected = if ($desired) { $_.StartupType } else { $_.OriginalType }
                        "$($_.Name) startup is $startType (expected $expected)"
                    }) -join '; '
                    " $observed."
                } else { '' }
                throw "Could not verify the selected service/driver state for '$key'.$detail"
            }
        } catch {
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Tweaks' -Context "Service/driver change $key"
            continue
        }
        if ($null -ne $sync.ToggleStatusCache) {
            $sync.ToggleStatusCache[$key] = $verified
        }
        if ($null -ne $sync.PendingGroupSelections) {
            [System.Threading.Monitor]::Enter($sync.PendingGroupSelections.SyncRoot)
            try {
                if ($sync.PendingGroupSelections.ContainsKey($key) -and
                    [bool]$sync.PendingGroupSelections[$key] -eq $desired) {
                    $sync.PendingGroupSelections.Remove($key)
                }
            } finally {
                [System.Threading.Monitor]::Exit($sync.PendingGroupSelections.SyncRoot)
            }
        }
    }
}
