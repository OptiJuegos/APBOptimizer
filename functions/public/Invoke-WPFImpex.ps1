function Invoke-WPFImpex {
    <#
    .SYNOPSIS
        Imports/exports ONLY APBOptimizer tweaks and toggles. This function
        never copies or invokes the original WinUtil URL.
    #>
    param(
        [ValidateSet('import', 'export')]
        [string]$type,
        [string]$Config = '',
        [switch]$Merge,
        [switch]$ThrowOnError
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Config)) {
            Add-Type -AssemblyName System.Windows.Forms
            if ($type -eq 'export') {
                $dialog = [System.Windows.Forms.SaveFileDialog]::new()
            } else {
                $dialog = [System.Windows.Forms.OpenFileDialog]::new()
            }
            $dialog.Filter = 'JSON (*.json)|*.json'
            $dialog.DefaultExt = 'json'
            $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $Config = $dialog.FileName
        }

        if ($Config -match '^https?://') {
            throw 'APBOptimizer solamente acepta archivos locales para importar o exportar.'
        }

        if ($type -eq 'export') {
            $chosen = @($sync.selectedTweaks) + @($sync.selectedToggles) | Select-Object -Unique
            if ($chosen.Count -eq 0) {
                if ($sync.Form) {
                    Show-WinUtilMessage -Title 'APBOptimizer' -Message 'Primero selecciona algun tweak.' -Icon 'Warning' -Button 'OK' | Out-Null
                }
                return
            }
            ConvertTo-Json -InputObject @($chosen) -Depth 8 |
                Set-Content -LiteralPath $Config -Encoding UTF8
            return
        }

        $imported = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $imported = @($imported)
        if ($imported.Count -eq 0 -or $null -eq $imported[0]) {
            throw 'El JSON esta vacio. Se esperaba una lista de identificadores de tweaks.'
        }

        $valid = @()
        foreach ($item in $imported) {
            if ($item -isnot [string] -or $item -notmatch '^WPF(Tweaks|Toggle)') {
                throw "APBOptimizer no admite esta seleccion: $item"
            }
            $valid += $item
        }
        $parameters = @{}
        if (-not $Merge) { $parameters.Replace = $true }
        Update-WinUtilSelections -flatJson $valid @parameters
        if ($sync.Form) {
            $previousImportState = $sync.ImportInProgress
            try {
                $sync.ImportInProgress = $true
                Reset-WPFCheckBoxes -doToggles $true
            } finally {
                $sync.ImportInProgress = $previousImportState
            }
        }
    }
    catch {
        if ($ThrowOnError) { throw }
        if ($sync.Form) {
            Show-WinUtilMessage -Title 'APBOptimizer' -Message "No se pudo importar/exportar: $($_.Exception.Message)" -Icon 'Warning' -Button 'OK' | Out-Null
        } else {
            throw
        }
    }
}
