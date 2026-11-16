function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    $tweaks = @($sync.selectedTweaks)

    if ($tweaks.count -eq 0) {
        Show-WinUtilMessage -Message "Please check the tweaks you wish to undo." -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    # AppX packages do not have an inverse action: Undo must not falsely report
    # that a bulk uninstall was reversed. Other selected tweaks are still undoable.
    if ($tweaks -contains 'WPFTweaksDeBloat') {
        $warning = if ($sync.Language -eq 'es') {
            'Eliminar apps de Microsoft Store no se puede deshacer automaticamente. Debes reinstalar las aplicaciones manualmente. Los otros ajustes seleccionados se pueden restaurar por separado.'
        } else {
            'Bulk Microsoft Store app removal has no automatic Undo. You must reinstall removed apps manually. Other selected tweaks can still be restored.'
        }
        Show-WinUtilMessage -Message $warning -Title 'APBOptimizer - MS Store Apps' -Button 'OK' -Icon 'Warning' | Out-Null
        $tweaks = @($tweaks | Where-Object { $_ -ne 'WPFTweaksDeBloat' })
        if ($tweaks.Count -eq 0) { return }
    }

    Start-WinUtilJob -Name "Undo tweaks" -Description "Undoing tweaks" -Parameters @{
        Tweaks = @($tweaks)
    } -ScriptBlock {
        param($Tweaks)

        $total = @($Tweaks).Count
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks requested: $total selected tweak(s)."

        for ($i = 0; $i -lt $total; $i++) {
            Step-WinUtilJob -Status "Undoing $($Tweaks[$i]) ($($i + 1)/$total)" -Percent ([int](($i / $total) * 100))
            Measure-WinUtilStep -Scope "Undo tweaks" -Name $Tweaks[$i] -ScriptBlock {
                Invoke-WinUtiltweaks $Tweaks[$i] -undo $true
            }
            Step-WinUtilJob -Percent ([int]((($i + 1) / $total) * 100))
        }
    }
}
