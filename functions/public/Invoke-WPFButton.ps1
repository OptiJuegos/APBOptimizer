function Invoke-WPFButton {
    param([Parameter(Mandatory = $true)][string]$Button)

    if (-not $sync.ActiveJob) { Step-WinUtilJob -Hide }

    try {
        switch ($Button) {
            'WPFTab2BT'                { Invoke-WPFTab $Button }
            'WPFAdvancedTabBT'          { Invoke-WPFTab $Button }
            'WPFModeGuided'             { Select-WinUtilMode -Mode 'guided' }
            'WPFModeAdvanced'           { Select-WinUtilMode -Mode 'advanced' }
            'WPFGuidedYes'              { Submit-WinUtilGuidedAnswer -Answer $true }
            'WPFGuidedNo'               { Submit-WinUtilGuidedAnswer -Answer $false }
            'WPFGuidedBack'             { Step-WinUtilGuidedBack }
            'WPFGuidedSummaryBack'      { Show-WinUtilGuidedQuestion -Index (@(Get-WinUtilGuidedQuestions).Count - 1) }
            'WPFGuidedDoneAdvanced'     { Exit-WinUtilGuided }
            'WPFGuidedReview'           { Invoke-WinUtilGuidedReview }
            'WPFGuidedApply'            { Invoke-WinUtilGuidedApply }
            'WPFGuidedDoneHome'         { Show-WinUtilModeChooser }
            'WPFGuidedRestart'          { Restart-WinUtilComputer }
            'WPFGuidedCloseWindow'      { if ($sync.GuidedWindow) { $sync.GuidedWindow.Close() } }
            'WPFGuidedMinimizeWindow'   { if ($sync.GuidedWindow) { [Windows.SystemCommands]::MinimizeWindow($sync.GuidedWindow) } }
            'WPFDisableWindowsUpdate'   {
                $prompt = if ($sync.Language -eq 'es') {
                    'Modo agresivo: APBOptimizer intentará detener Windows Update y renombrar WaaSMedicSvc.dll y wuaueng.dll (archivos protegidos del sistema). Esto bloquea actualizaciones, incluidas las de seguridad, y puede afectar la reparación de Windows. La restauración podría requerir intervención manual. ¿Continuar?'
                } else { 'Aggressive mode: APBOptimizer will try to stop Windows Update and rename protected system files WaaSMedicSvc.dll and wuaueng.dll. This blocks updates, including security updates, and may affect Windows repair. Restoring may require manual recovery. Continue?' }
                if ((Show-WinUtilMessage -Title 'Windows Update' -Message $prompt -Button 'YesNo' -Icon 'Warning').ToString() -ne 'Yes') { return }
                Start-WinUtilJob -Name 'WindowsUpdate' -Description 'Disabling Windows Update' -ScriptBlock {
                    try { Set-WinUtilWindowsUpdate -Mode Disable }
                    finally { Update-WinUtilWindowsUpdateStatusUI }
                }
            }
            'WPFRestoreWindowsUpdate'   {
                $mode = 'Restore'
                if (Test-WinUtilWindowsUpdateRecoveryRequired) {
                    $message = if ($sync.Language -eq 'es') {
                        'Se detectaron DLL de Windows Update renombradas sin una copia original válida de APBOptimizer. La recuperación intentará devolver sus nombres usando los permisos del archivo _BAK, habilitar en modo Manual los servicios deshabilitados y retirar NoAutoUpdate=1. No puede garantizar que estos sean los ajustes originales. ¿Intentar la recuperación?'
                    } else {
                        'Windows Update DLLs were found renamed without a valid original APBOptimizer backup. Recovery will try to restore DLL names using their current _BAK file permissions, change disabled update services to Manual and remove NoAutoUpdate=1. Original settings cannot be guaranteed. Attempt recovery?'
                    }
                    if ((Show-WinUtilMessage -Title 'Windows Update Recovery' -Message $message -Button 'YesNo' -Icon 'Warning').ToString() -ne 'Yes') { return }
                    $mode = 'Recover'
                }
                Start-WinUtilJob -Name 'WindowsUpdate' -Description 'Restoring Windows Update' -Parameters @{ Mode = $mode } -ScriptBlock {
                    param($Mode)
                    try { Set-WinUtilWindowsUpdate -Mode $Mode }
                    finally { Update-WinUtilWindowsUpdateStatusUI }
                }
            }
            'WPFTweakHelpClose'         { $sync.WPFTweakHelpPopup.IsOpen = $false }
            'WPFTweakHelpDocs'          {
                $target = [string]$sync.WPFTweakHelpDocs.Tag
                $uri = $null
                if ([Uri]::TryCreate($target, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https') {
                    Start-Process -FilePath $uri.AbsoluteUri -ErrorAction Stop
                }
            }
            'WPFStandard'              { Invoke-WPFPresets 'Standard' -checkboxfilterpattern 'WPFTweak*' }
            'WPFMinimal'               { Invoke-WPFPresets 'Minimal' -checkboxfilterpattern 'WPFTweak*' }
            'WPFAdvanced'              { Invoke-WPFPresets 'Advanced' -checkboxfilterpattern 'WPFTweak*' }
            'WPFClearTweaksSelection'  { Invoke-WPFPresets -imported $true -checkboxfilterpattern 'WPFTweak*' }
            'WPFGetInstalledTweaks'    { Invoke-WPFGetInstalled -CheckBox 'tweaks' }
            'WPFTweaksbutton'          { Invoke-WPFtweaksbutton -IncludeToggles }
            'WPFUndoall'               { Invoke-WPFundoall }
            'WPFAddUltPerf'            {
                Start-WinUtilJob -Name 'Power' -Description 'Adding Ultimate Performance' -ScriptBlock {
                    Invoke-WPFUltimatePerformance -Enable
                }
            }
            'WPFRemoveUltPerf'         {
                Start-WinUtilJob -Name 'Power' -Description 'Restoring default power plans' -ScriptBlock {
                    Invoke-WPFUltimatePerformance
                }
            }
            'WPFCloseButton'           { $sync.Form.Close() }
            'WPFMinimizeButton'        { [Windows.SystemCommands]::MinimizeWindow($sync.Form) }
            'WPFMaximizeButton'        {
                if ($sync.Form.WindowState -eq [Windows.WindowState]::Normal) {
                    [Windows.SystemCommands]::MaximizeWindow($sync.Form)
                } else {
                    [Windows.SystemCommands]::RestoreWindow($sync.Form)
                }
            }
            # Settings, theme, font and search controls have their own event handlers.
            default { }
        }
    } catch {
        Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'UI' -Context "Button '$Button'"
    }
}
