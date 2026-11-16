BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    foreach ($file in @('Invoke-WPFButton', 'Invoke-WPFUltimatePerformance', 'Invoke-WPFOOSU')) {
        . (Join-Path $script:repoRoot "functions/public/$file.ps1")
    }
    . (Join-Path $script:repoRoot 'functions/private/Start-WinUtilJob.ps1')
    . (Join-Path $script:repoRoot 'functions/private/Step-WinUtilJob.ps1')
    . (Join-Path $script:repoRoot 'functions/private/Write-WinUtilErrorRecord.ps1')
}
Describe 'Retained tweak action buttons' {
    BeforeEach {
        $script:sync = [hashtable]::Synchronized(@{})
        Mock Step-WinUtilJob { }
        Mock Write-WinUtilErrorRecord { throw $ErrorRecord }
        Mock Invoke-WPFUltimatePerformance { }
        Mock Invoke-WPFOOSU { }
        Mock Start-WinUtilJob { & $ScriptBlock }
        Mock Start-Process { }
    }
    It 'queues adding the Ultimate Performance plan' {
        Invoke-WPFButton WPFAddUltPerf
        Should -Invoke Start-WinUtilJob -Times 1 -Exactly
        Should -Invoke Invoke-WPFUltimatePerformance -Times 1 -Exactly -ParameterFilter { $Enable }
    }
    It 'queues restoring the default power plans' {
        Invoke-WPFButton WPFRemoveUltPerf
        Should -Invoke Invoke-WPFUltimatePerformance -Times 1 -Exactly -ParameterFilter { -not $Enable }
    }
    It 'does not dispatch the removed OOSU button' {
        Invoke-WPFButton WPFOOSUbutton
        Should -Invoke Invoke-WPFOOSU -Times 0 -Exactly
    }
}
