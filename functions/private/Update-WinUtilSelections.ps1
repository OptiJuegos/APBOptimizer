function Update-WinUtilSelections {
    param(
        [Parameter(Mandatory)]
        [string[]]$flatJson,

        [switch]$Replace,

        [switch]$SkipUnknown
    )

    $nextSelections = @{
        selectedTweaks   = [System.Collections.Generic.List[string]]::new()
        selectedToggles  = [System.Collections.Generic.List[string]]::new()
    }

    # Expand legacy combined selections to their independent current entries.
    # Older exports represented exactly five tasks with one checkbox. Keep
    # those same five selections; newly added tasks remain opt-in.
    $flatJson = @($flatJson | ForEach-Object {
        if ($_ -eq 'WPFTweaksDisableTelemetryTasks') {
            @(
                'WPFToggleTaskCompatibilityAppraiser'
                'WPFToggleTaskProgramDataUpdater'
                'WPFToggleTaskConsolidator'
                'WPFToggleTaskUsbCeip'
                'WPFToggleTaskKernelCeip'
            )
        } elseif ($_ -eq 'WPFTweaksServices') {
            @('WPFTweaksServicesManual', 'WPFTweaksServicesDisabled')
        } else { $_ }
    })

    foreach ($cbkey in $flatJson) {

        $listName = switch -Regex ($cbkey) {
            '^WPFTweaks'  { 'selectedTweaks' }
            '^WPFToggle'  { 'selectedToggles' }
        }

        if (-not $listName) {
            if ($SkipUnknown) {
                $cbkey
                continue
            }
            throw "Unsupported selection key '$cbkey'."
        }

        $isKnownSelection = switch ($listName) {
            'selectedTweaks' {
                $null -ne $sync.configs.tweaks.PSObject.Properties[$cbkey]
            }
            'selectedToggles' {
                $null -ne $sync.configs.tweaks.PSObject.Properties[$cbkey]
            }
        }

        if (-not $isKnownSelection) {
            if ($SkipUnknown) {
                $cbkey
                continue
            }
            throw "Unknown selection key '$cbkey'."
        }

        # A replacement import can contain repeated identifiers. Keep a single
        # selection so each tweak or toggle runs at most once per Apply.
        if ($nextSelections[$listName] -notcontains $cbkey) {
            $nextSelections[$listName].Add($cbkey)
        }
    }

    $validSelectionCount = ($nextSelections.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    if ($SkipUnknown -and $validSelectionCount -eq 0) {
        return
    }

    if ($Replace) {
        foreach ($listName in $nextSelections.Keys) {
            $sync[$listName] = $nextSelections[$listName]
        }
        return
    }

    foreach ($listName in $nextSelections.Keys) {
        foreach ($cbkey in $nextSelections[$listName]) {
            # Appending, so the same entry can already be there: a preset and a config that both
            # name it would otherwise select it twice
            if ($sync.$listName -notcontains $cbkey) {
                $sync.$listName.Add($cbkey)
            }
        }
    }
}
