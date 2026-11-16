BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:repoRoot 'functions/private/Initialize-WinUtilTabContent.ps1')
    . (Join-Path $script:repoRoot 'functions/public/Invoke-WPFUIElements.ps1')
    . (Join-Path $script:repoRoot 'functions/private/Reset-WPFCheckBoxes.ps1')
    function Write-WinUtilLog { param($Level, $Component, $Message) }
}
Describe 'Tweaks tab initialization' {
    BeforeEach {
        $script:sync = [hashtable]::Synchronized(@{ configs = @{ tweaks = [pscustomobject]@{} } })
        Mock Invoke-WPFUIElements { }
        Mock Reset-WPFCheckBoxes { }
    }
    It 'builds the tweaks controls once and restores their selections once' {
        Initialize-WinUtilTabContent Tweaks
        Initialize-WinUtilTabContent Tweaks
        $sync.InitializedTabs.Tweaks | Should -BeTrue
        Should -Invoke Invoke-WPFUIElements -Times 1 -Exactly -ParameterFilter { $targetGridName -eq 'tweakspanel' -and $columncount -eq 2 }
        Should -Invoke Reset-WPFCheckBoxes -Times 1 -Exactly
    }
    It 'does not initialize a removed tab' {
        Initialize-WinUtilTabContent Install
        Should -Invoke Invoke-WPFUIElements -Times 0 -Exactly
    }
    It 'allows initialization to retry after a rendering failure' {
        Mock Invoke-WPFUIElements { throw 'Render failed' }
        { Initialize-WinUtilTabContent Tweaks } | Should -Throw
        $sync.InitializedTabs.Tweaks | Should -BeFalse
    }
}
