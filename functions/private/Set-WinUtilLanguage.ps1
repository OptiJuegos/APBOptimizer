function Get-WinUtilSystemLanguage {
    param([string]$CultureName = [Globalization.CultureInfo]::CurrentUICulture.Name)

    # Windows UI culture, not the keyboard layout or the region.
    if ([string]$CultureName -match '^es(?:-|$)') { return 'es' }
    return 'en'
}

function Initialize-WinUtilLanguage {
    # Keep fork preferences independent from the original WinUtil's data.
    $configFolder = if ($sync.LanguageConfigDir) { $sync.LanguageConfigDir } else {
        Join-Path $env:LOCALAPPDATA 'APBOptimizer'
    }
    $sync.LanguageSettingsPath = Join-Path $configFolder 'settings.json'
    $choice = 'auto'
    try {
        $settingsToRead = $sync.LanguageSettingsPath
        # Preserve the previous name's language preference on the first launch.
        # An explicit test/config directory must never read from real AppData.
        if (-not $sync.LanguageConfigDir -and -not (Test-Path -LiteralPath $settingsToRead)) {
            $legacySettings = Join-Path (Join-Path $env:LOCALAPPDATA 'OptiUtil') 'settings.json'
            if (Test-Path -LiteralPath $legacySettings) {
                $settingsToRead = $legacySettings
            }
        }
        if (Test-Path -LiteralPath $settingsToRead) {
            $stored = Get-Content -LiteralPath $settingsToRead -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($stored.language -in @('auto', 'es', 'en')) {
                $choice = [string]$stored.language
            }
        }
    } catch {
        Write-Warning "Could not read APBOptimizer language preference: $($_.Exception.Message)"
    }
    $sync.preferences.language = $choice
    $sync.Language = if ($choice -eq 'auto') { Get-WinUtilSystemLanguage } else { $choice }
}

function Get-WinUtilLocalizedEntry {
    param([Parameter(Mandatory)][string]$Key)
    if ($sync.Language -ne 'es' -or $null -eq $sync.configs.es) { return $null }
    return $sync.configs.es.PSObject.Properties[$Key].Value
}

function Get-WinUtilLocalizedCategory {
    param([Parameter(Mandatory)][string]$Category)
    if ($sync.Language -eq 'es' -and $null -ne $sync.configs.es) {
        $translated = $sync.configs.es.Categories.PSObject.Properties[$Category]
        if ($translated -and $translated.Value) { return [string]$translated.Value }
    }
    return $Category
}

function Update-WinUtilLanguageUI {
    if ($null -eq $sync.Form) { return }
    if ($null -eq $sync.LanguageOriginalUI) { $sync.LanguageOriginalUI = @{} }
    $translations = $sync.configs.localization
    if ($null -eq $translations) { return }
    $english = $translations.en
    $spanish = $translations.es
    $keys = @($english.PSObject.Properties.Name) + @($spanish.PSObject.Properties.Name) | Select-Object -Unique

    foreach ($name in $keys) {
        $control = $sync[$name]
        if ($null -eq $control) { continue }
        $fields = @{}
        foreach ($culture in @($english, $spanish)) {
            $translatedControl = $culture.PSObject.Properties[$name]
            if ($null -eq $translatedControl) { continue }
            foreach ($field in $translatedControl.Value.PSObject.Properties.Name) { $fields[$field] = $true }
        }
        foreach ($field in $fields.Keys) {
            $originalKey = "$name/$field"
            if (-not $sync.LanguageOriginalUI.ContainsKey($originalKey)) {
                $sync.LanguageOriginalUI[$originalKey] = $control.$field
            }
            $translation = $translations.$($sync.Language).PSObject.Properties[$name]
            $value = if ($translation -and $translation.Value.PSObject.Properties[$field]) {
                $translation.Value.$field
            } else { $sync.LanguageOriginalUI[$originalKey] }
            # Fix legacy text decoded as ANSI by Windows PowerShell 5.1.
            # XAML objects and correctly decoded JSON are left untouched.
            $control.$field = Convert-WinUtilTextEncoding -Text $value
        }
    }
    if ($null -ne $sync.WPFLanguageSelector) {
        $sync.LanguageSelectorChanging = $true
        try {
            foreach ($option in $sync.WPFLanguageSelector.Items) {
                if ($option.Tag -eq 'auto') {
                    $option.Content = if ($sync.Language -eq 'es') { 'Automático (Windows)' } else { 'Automatic (Windows)' }
                }
                if ($option.Tag -eq $sync.preferences.language) {
                    $sync.WPFLanguageSelector.SelectedItem = $option
                }
            }
        } finally { $sync.LanguageSelectorChanging = $false }
    }
}

function Set-WinUtilLanguage {
    param(
        [Parameter(Mandatory)][ValidateSet('auto', 'es', 'en')][string]$Language,
        [switch]$SkipSave
    )

    $previous = $sync.Language
    $sync.preferences.language = $Language
    $sync.Language = if ($Language -eq 'auto') { Get-WinUtilSystemLanguage } else { $Language }

    if (-not $SkipSave) {
        try {
            $parent = Split-Path -Parent $sync.LanguageSettingsPath
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            @{ language = $Language } | ConvertTo-Json -Compress |
                Set-Content -LiteralPath $sync.LanguageSettingsPath -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Warning "Could not save APBOptimizer language preference: $($_.Exception.Message)"
        }
    }

    Update-WinUtilLanguageUI
    if ($sync.currentTab -eq 'Advanced') {
        Update-WinUtilWindowsUpdateStatusUI
    }

    # Rebuild only the localized labels, never the underlying tweak configuration.
    # Imported/selected checkboxes are restored while toggle handlers are in import
    # mode, so changing language cannot modify services or registry values.
    if ($previous -ne $sync.Language -and $sync.InitializedTabs -and $sync.InitializedTabs['Tweaks']) {
        $wasImporting = $sync.ImportInProgress
        $sync.ImportInProgress = $true
        try {
            Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName 'tweakspanel' -columncount 2
            Reset-WPFCheckBoxes -doToggles $true
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        } finally { $sync.ImportInProgress = $wasImporting }
    }
}
