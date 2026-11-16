function Get-WinUtilTweakHelpContent {
    param([Parameter(Mandatory)][string]$Key)

    $entryProperty = $sync.configs.tweaks.PSObject.Properties[$Key]
    if (-not $entryProperty) { throw "Unknown APBOptimizer tweak: $Key" }
    $entry = $entryProperty.Value
    $spanish = $sync.Language -eq 'es'
    $translation = if ($spanish -and $sync.configs.es) {
        $sync.configs.es.PSObject.Properties[$Key]
    } else { $null }
    $translated = if ($translation) { $translation.Value } else { $null }
    $title = if ($translated -and $translated.Content) { [string]$translated.Content } else { [string]$entry.Content }
    $summary = if ($translated -and $translated.Description) { [string]$translated.Description } else { [string]$entry.Description }
    if ([string]::IsNullOrWhiteSpace($summary)) {
        $summary = if ($spanish) { 'Este ajuste modifica la configuración de Windows.' } else { 'This tweak changes Windows settings.' }
    }

    $changes = [Collections.Generic.List[string]]::new()
    $undo = [Collections.Generic.List[string]]::new()
    if ($entry.ComboItems) {
        $choices = if ([string]$entry.ComboItems -match '\|') {
            @([string]$entry.ComboItems -split '\|')
        } else {
            @([string]$entry.ComboItems -split '\s+')
        }
        $changes.Add($(if ($spanish) { 'Opciones disponibles:' } else { 'Available options:' }))
        foreach ($choice in $choices) {
            if ($choice) { $changes.Add("  $choice") }
        }
    }
    if ($entry.registry) {
        $changes.Add($(if ($spanish) { 'Registro de Windows:' } else { 'Windows Registry:' }))
        $undo.Add($(if ($spanish) { 'Restauración del Registro:' } else { 'Registry restoration:' }))
        foreach ($r in @($entry.registry)) {
            $location = "$($r.Path)\$($r.Name)"
            if ($r.Values) {
                $changes.Add("  $location")
                foreach ($state in $r.Values.PSObject.Properties) {
                    $changes.Add("    $($state.Name): $($state.Value)")
                }
                $undo.Add("  $location")
            } else {
                $changes.Add("  $location = $($r.Value)")
                $original = if ($r.OriginalValue -eq '<RemoveEntry>') {
                    if ($spanish) { 'eliminar valor' } else { 'remove value' }
                } elseif ($null -ne $r.OriginalValue) { [string]$r.OriginalValue }
                else { if ($spanish) { 'sin valor anterior definido' } else { 'no previous value defined' } }
                $undo.Add("  $location = $original")
            }
        }
    }
    if ($entry.service) {
        $changes.Add($(if ($spanish) { 'Servicios:' } else { 'Services:' }))
        $undo.Add($(if ($spanish) { 'Inicio de servicios:' } else { 'Service startup:' }))
        foreach ($svc in @($entry.service)) {
            $changes.Add("  $($svc.Name): $($svc.StartupType)")
            if ($svc.OriginalType) { $undo.Add("  $($svc.Name): $($svc.OriginalType)") }
        }
    }
    if ($entry.InvokeScript) {
        $changes.Add($(if ($spanish) { 'Comandos adicionales (fragmento):' } else { 'Additional commands (excerpt):' }))
        $commands = @($entry.InvokeScript | ForEach-Object {
            $_ -split '\r?\n' | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^#' }
        })
        foreach ($command in @($commands | Select-Object -First 5)) {
            $line = $command.Trim()
            if ($line.Length -gt 115) { $line = $line.Substring(0, 112) + '...' }
            $changes.Add("  $line")
        }
        if ($commands.Count -gt 5) {
            $changes.Add($(if ($spanish) { "  (+$($commands.Count - 5) líneas)" } else { "  (+$($commands.Count - 5) lines)" }))
        }
    }
    if ($entry.UndoScript) {
        $undo.Add($(if ($spanish) { 'También ejecuta los comandos de reversión definidos por el ajuste.' } else { 'Also runs the reversal commands defined by this tweak.' }))
    }
    if (-not $changes.Count) {
        $changes.Add($(if ($spanish) { 'Ejecuta las acciones configuradas para este ajuste.' } else { 'Runs the actions configured for this tweak.' }))
    }
    if (-not $undo.Count) {
        $undo.Add($(if ($spanish) {
            'Este ajuste no define una restauración automática completa. Revisa los cambios antes de aplicarlo.'
        } else {
            'This tweak does not define a complete automatic reversal. Review its changes before applying.'
        }))
    } elseif ($entry.InvokeScript -and -not $entry.UndoScript) {
        $undo.Add($(if ($spanish) { 'Atención: algunos comandos adicionales podrían no revertirse.' } else { 'Note: some additional commands may not be reversed.' }))
    }

    return [pscustomobject]@{
        Key = $Key
        Title = $title
        Summary = $summary
        Changes = ($changes -join "`n")
        Undo = ($undo -join "`n")
        Documentation = [string]$entry.link
        Spanish = $spanish
    }
}

function Show-WinUtilTweakHelp {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][System.Windows.UIElement]$Anchor
    )

    $data = Get-WinUtilTweakHelpContent -Key $Key
    $sync.WPFTweakHelpPopup.IsOpen = $false
    $sync.WPFTweakHelpTitle.Text = $data.Title
    $sync.WPFTweakHelpSummary.Text = $data.Summary
    $sync.WPFTweakHelpChanges.Text = $data.Changes
    $sync.WPFTweakHelpUndo.Text = $data.Undo
    $sync.WPFTweakHelpSummaryHeader.Text = if ($data.Spanish) { 'Qué hace' } else { 'What it does' }
    $sync.WPFTweakHelpChangesHeader.Text = if ($data.Spanish) { 'Cómo funciona' } else { 'How it works' }
    $sync.WPFTweakHelpUndoHeader.Text = if ($data.Spanish) { 'Cómo se revierte' } else { 'How to undo it' }
    $sync.WPFTweakHelpClose.ToolTip = if ($data.Spanish) { 'Cerrar' } else { 'Close' }
    $sync.WPFTweakHelpDocs.Content = if ($data.Spanish) { 'Ver documentación original' } else { 'Original documentation' }
    $sync.WPFTweakHelpDocs.Tag = $data.Documentation
    $sync.WPFTweakHelpDocs.Visibility = if ([string]::IsNullOrWhiteSpace($data.Documentation)) { 'Collapsed' } else { 'Visible' }
    # Anchor to the full client area, not to the tiny (?) control. WPF's
    # PlacementMode.Center now positions the enlarged help card over APBOptimizer.
    $sync.WPFTweakHelpPopup.PlacementTarget = $sync.WPFMainGrid
    $sync.WPFTweakHelpPopup.IsOpen = $true
}
