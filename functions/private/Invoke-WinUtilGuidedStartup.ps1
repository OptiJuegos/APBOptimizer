function Request-WinUtilGuidedStartupApps {
    param([switch]$Refresh)
    if ($sync.StartupAppsLoading -or ($sync.StartupAppsCacheLoaded -and -not $Refresh)) { return }
    if ($sync.ActiveJob) { return }
    $sync.StartupAppsLoading = $true
    $sync.StartupAppsError = ''
    $token = [guid]::NewGuid().ToString()
    $sync.StartupAppsScanToken = $token
    Start-WinUtilJob -Name 'StartupAppsScan' -Description 'Reading startup applications' -Parameters @{ Token=$token } -ScriptBlock {
        param($Token)
        $entries = @(); $errorText = ''
        try {
            $entries = @(Get-WinUtilStartupEntries | Sort-Object Name,Scope,Id)
            if ($script:WinUtilStartupReadIncomplete) { $errorText = 'Algunas entradas no se pudieron leer. Revisa el registro para más detalles.' }
        } catch {
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'StartupApps' -Context 'Read startup applications'
            $errorText = 'No se pudo leer la lista completa. Revisa el registro para más detalles.'
        }
        Invoke-WPFUIThread -Parameters @{ Entries=$entries; ErrorText=$errorText; Token=$Token } -ScriptBlock {
            param($Entries,$ErrorText,$Token)
            if ($sync.StartupAppsScanToken -ne $Token) { return }
            $sync.StartupAppsEntries = @($Entries)
            $sync.StartupAppsError = $ErrorText
            $sync.StartupAppsCacheLoaded = $true
            $sync.StartupAppsLoading = $false
            if ($sync.GuidedWindow -and $sync.GuidedPanel -eq 'Wizard' -and $sync.GuidedState -and
                @(Get-WinUtilGuidedQuestions)[$sync.GuidedState.Index].DataSource -eq 'StartupApps') {
                Show-WinUtilGuidedQuestion -Index $sync.GuidedState.Index
            }
        }
    }
    if ($sync.StartupAppsLoading -and $sync.ActiveJob -ne 'StartupAppsScan') {
        $sync.StartupAppsLoading = $false
        $sync.StartupAppsError = 'No se pudo iniciar la lectura. Vuelve a abrir el modo guiado para volver a intentarlo.'
    }
}

function Get-WinUtilGuidedStartupOptions {
    param([switch]$IncludeUnavailable)
    foreach ($entry in @($sync.StartupAppsEntries)) {
        if (-not $entry -or (-not $IncludeUnavailable -and -not $entry.CanChange)) { continue }
        $state = if (-not $entry.Known) { 'Estado no disponible' } elseif ($entry.PolicyLocked) { 'Administrada por una directiva' }
        $detail = @($entry.DisplayPublisher, $state, $entry.Scope) | Where-Object { $_ }
        [pscustomobject]@{
            Id = [string]$entry.Id; Default = [bool]$entry.Enabled
            Label = [pscustomobject]@{ en=$entry.Name; es=$entry.Name }
            Detail = [pscustomobject]@{ en=($detail -join ' · '); es=($detail -join ' · ') }
            StartupEntry = $entry; Actions = @(); Reboot = $false
        }
    }
}

function Get-WinUtilPendingStartupChanges {
    if ($sync.PendingStartupChanges) { return @($sync.PendingStartupChanges.Values) }
    return @()
}
