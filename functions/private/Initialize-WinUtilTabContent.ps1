function Initialize-WinUtilTabContent {
    param(
        [Parameter(Mandatory = $true)][string]$TabName,
        [switch]$Yield
    )

    if ($TabName -ne 'Tweaks') { return }

    if ($null -eq $sync.InitializedTabs) { $sync.InitializedTabs = @{} }
    if ($sync.InitializedTabs['Tweaks']) { return }

    $sync.InitializedTabs['Tweaks'] = $true
    $loadClock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName 'tweakspanel' -columncount 2 -Yield:$Yield
        Reset-WPFCheckBoxes -doToggles $true
    } catch {
        $sync.InitializedTabs['Tweaks'] = $false
        throw
    } finally {
        $loadClock.Stop()
        Write-WinUtilLog -Level 'DEBUG' -Component 'UI' -Message "First Tweaks panel initialized in $($loadClock.ElapsedMilliseconds) ms."
    }
}
