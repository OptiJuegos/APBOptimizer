#===========================================================================
# Tests - Environment Report
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Write-WinUtilLog.ps1")
    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilToggleStatus.ps1")
    . (Join-Path $script:repoRoot "functions\private\Invoke-WinUtilCurrentSystem.ps1")
    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilTweaksStateReport.ps1")
}









Describe "Get-WinUtilTweaksStateReport" {
    BeforeEach {
        $script:sync = [Hashtable]::Synchronized(@{
            configs = @{
                tweaks = [pscustomobject]@{
                    WPFTweaksApplied     = [pscustomobject]@{
                        category = "Essential Tweaks"
                        registry = @([pscustomobject]@{ Path = "HKCU:\Fake1"; Name = "Enabled"; Value = "1"; OriginalValue = "0"; DefaultState = "true" })
                    }
                    WPFTweaksNotApplied  = [pscustomobject]@{
                        category = "Essential Tweaks"
                        registry = @([pscustomobject]@{ Path = "HKCU:\Fake2"; Name = "Enabled"; Value = "1"; OriginalValue = "0"; DefaultState = "false" })
                    }
                    WPFToggleCustomize   = [pscustomobject]@{
                        category = "Customize Preferences"
                        Type     = "Toggle"
                        registry = @([pscustomobject]@{ Path = "HKCU:\Fake3"; Name = "Enabled"; Value = "1"; OriginalValue = "0"; DefaultState = "true" })
                    }
                    WPFTweaksAdvanced    = [pscustomobject]@{
                        category = "z__Advanced Tweaks - CAUTION"
                        registry = @([pscustomobject]@{ Path = "HKCU:\Fake4"; Name = "Enabled"; Value = "1"; OriginalValue = "0"; DefaultState = "false" })
                    }
                    WPFComboExample      = [pscustomobject]@{
                        category = "Customize Preferences"
                        Type     = "Combobox"
                    }
                    WPFButtonExample     = [pscustomobject]@{
                        category = "z__Advanced Tweaks - CAUTION"
                        Type     = "Button"
                    }
                    WPFScriptOnly        = [pscustomobject]@{
                        category = "Essential Tweaks"
                    }
                    WPFUnknownCategory   = [pscustomobject]@{
                        category = "Some Unmapped Category"
                        registry = @([pscustomobject]@{ Path = "HKCU:\Fake5"; Name = "Enabled"; Value = "1"; OriginalValue = "0"; DefaultState = "true" })
                    }
                }
            }
        })

        Mock Get-PSDrive { [pscustomobject]@{ Name = "HKU" } } -ParameterFilter { $Name -eq "HKU" }
        Mock New-PSDrive { }
        Mock Test-Path { $false }
        Mock Get-ItemProperty { $null }
        Mock Write-WinUtilLog { }
    }

    It "groups applied/not-applied tweaks and toggles by category" {
        $result = Get-WinUtilTweaksStateReport

        $result.collectionStatus | Should -Be "collected"
        $result.essentialTweaks.WPFTweaksApplied | Should -BeTrue
        $result.essentialTweaks.WPFTweaksNotApplied | Should -BeFalse
        $result.customizePreferences.WPFToggleCustomize | Should -BeTrue
        $result.advancedTweaks.WPFTweaksAdvanced | Should -BeFalse
        @($result.performancePlans.PSObject.Properties).Count | Should -Be 0
    }

    It "reads live toggle state instead of the cached UI state" {
        $script:sync.ToggleStatusCache = @{ WPFToggleCustomize = $true }
        Mock Test-Path { $Path -eq "HKCU:\Fake3" }
        Mock Get-ItemProperty { [pscustomobject]@{ Enabled = "0" } } -ParameterFilter {
            $Path -eq "HKCU:\Fake3"
        }

        $result = Get-WinUtilTweaksStateReport

        $result.customizePreferences.WPFToggleCustomize | Should -BeFalse
        $script:sync.ToggleStatusCache.WPFToggleCustomize | Should -BeTrue
        Should -Invoke -CommandName Get-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Path -eq "HKCU:\Fake3"
        }
    }

    It "reports collection as unavailable when a live registry read fails" {
        Mock Test-Path { $Path -eq "HKCU:\Fake3" }
        Mock Get-ItemProperty { Write-Error -Message "Registry access denied" -ErrorAction Stop } -ParameterFilter {
            $Path -eq "HKCU:\Fake3"
        }

        $result = Get-WinUtilTweaksStateReport

        $result.collectionStatus | Should -Be "unavailable"
        @($result.customizePreferences.PSObject.Properties).Count | Should -Be 0
    }

    It "reports collection as unavailable when a configured service cannot be read" {
        $script:sync.configs.tweaks | Add-Member -MemberType NoteProperty -Name WPFTweaksMissingService -Value ([pscustomobject]@{
            category = "Essential Tweaks"
            service = @([pscustomobject]@{ Name = "MissingService"; StartupType = "Disabled" })
        })
        Mock Get-Service { throw "Service access failed" } -ParameterFilter { $Name -eq "MissingService" }

        $result = Get-WinUtilTweaksStateReport

        $result.collectionStatus | Should -Be "unavailable"
        @($result.essentialTweaks.PSObject.Properties).Count | Should -Be 0
    }

    It "marks only the affected tweak false when a configured service is absent" {
        $script:sync.configs.tweaks | Add-Member -MemberType NoteProperty -Name WPFTweaksMissingService -Value ([pscustomobject]@{
            category = "Essential Tweaks"
            service = @([pscustomobject]@{ Name = "MissingService"; StartupType = "Disabled" })
        })
        Mock Get-Service {
            Write-Error -Message "Cannot find any service with service name 'MissingService'." `
                -Category ObjectNotFound -ErrorId NoServiceFoundForGivenName -ErrorAction Stop
        } -ParameterFilter { $Name -eq "MissingService" }

        $result = Get-WinUtilTweaksStateReport

        $result.collectionStatus | Should -Be "collected"
        $result.essentialTweaks.WPFTweaksApplied | Should -BeTrue
        $result.essentialTweaks.WPFTweaksMissingService | Should -BeFalse
    }

    It "lists combobox and script-only tweaks as not evaluable instead of silently dropping them" {
        $result = Get-WinUtilTweaksStateReport

        $result.notEvaluable | Should -Contain "WPFComboExample"
        $result.notEvaluable | Should -Contain "WPFScriptOnly"
    }

    It "excludes action buttons and unmapped categories entirely" {
        $result = Get-WinUtilTweaksStateReport

        $result.advancedTweaks.PSObject.Properties.Name | Should -Not -Contain "WPFButtonExample"
        $result.notEvaluable | Should -Not -Contain "WPFButtonExample"
        $result.notEvaluable | Should -Not -Contain "WPFUnknownCategory"
        ($result.essentialTweaks.PSObject.Properties.Name +
         $result.customizePreferences.PSObject.Properties.Name +
         $result.advancedTweaks.PSObject.Properties.Name +
         $result.performancePlans.PSObject.Properties.Name) | Should -Not -Contain "WPFUnknownCategory"
    }

    It "returns empty groups instead of throwing when Invoke-WinUtilCurrentSystem fails" {
        Mock Invoke-WinUtilCurrentSystem { throw "Registry access denied" }

        # Calling this directly (rather than via a wrapped scriptblock piped to Should -Not -Throw)
        # avoids a PowerShell scoping pitfall where an assignment inside such a scriptblock doesn't
        # reliably propagate to this scope - an uncaught exception here still fails the test anyway.
        $result = Get-WinUtilTweaksStateReport

        # Empty groups alone would be indistinguishable from a successful scan that found nothing
        # notable, so collectionStatus is what actually records that this run failed.
        $result.collectionStatus | Should -Be "unavailable"
        $result.essentialTweaks.PSObject.Properties.Name | Should -Not -Contain "WPFTweaksApplied"
        @($result.essentialTweaks.PSObject.Properties).Count | Should -Be 0
        @($result.customizePreferences.PSObject.Properties).Count | Should -Be 0
        @($result.advancedTweaks.PSObject.Properties).Count | Should -Be 0
        @($result.performancePlans.PSObject.Properties).Count | Should -Be 0
        $result.notEvaluable | Should -BeNullOrEmpty
    }
}
