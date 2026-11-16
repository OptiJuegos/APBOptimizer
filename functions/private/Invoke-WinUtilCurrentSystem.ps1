Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks which tweaks have already been applied.

    .EXAMPLE
        Invoke-WinUtilCurrentSystem -CheckBox "tweaks"

    #>

    param(
        $CheckBox,
        [switch]$BypassToggleStatusCache,
        [switch]$StopOnReadError
    )
    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}
        $readErrorAction = if ($StopOnReadError) { "Stop" } else { "SilentlyContinue" }

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $entryType = $entry.Type

            if ($entry.ScheduledTaskCleanup) {
                # Legacy hidden bulk tweak is kept for old exports only. Do not
                # implicitly select it when an individual task was disabled.
                if ($entry.ParentGroup) { return }
                try {
                    if (Get-WinUtilTelemetryTaskStatus) { Write-Output $Config }
                } catch {
                    if ($StopOnReadError) { throw }
                    Write-WinUtilLog -Level 'WARN' -Component 'Tasks' -Message "Cannot inspect optional telemetry task state: $($_.Exception.Message)"
                }
                return
            }

            # Standalone driver tweaks have no registry/service table in the
            # catalog. An empty $values list is not proof that the driver was
            # disabled; consult the same state reader used by grouped toggles.
            if ($entry.driver -and $entryType -ne 'Toggle') {
                if ((Get-WinUtilOptionalDriverInfo -Name $entry.driver.Name).Disabled) {
                    Write-Output $Config
                }
                return
            }

            if (($registryKeys -or $serviceKeys -or $entry.driver -or $entry.scheduledTask) -and $entryType -ne "Combobox") {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config `
                        -BypassCache:$BypassToggleStatusCache `
                        -StopOnReadError:$StopOnReadError)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path -ErrorAction $readErrorAction) {
                                if ($StopOnReadError) {
                                    $regstate = (Get-ItemProperty -Path $tweak.Path -ErrorAction Stop).$($tweak.Name)
                                } else {
                                    $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                                }
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        try {
                            $Service = Get-Service -Name $tweak.Name -ErrorAction $readErrorAction
                        } catch {
                            if ($StopOnReadError -and $_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName*") {
                                # A removed optional service means this tweak is not applied; it does
                                # not make the registry and service state for every other tweak unknown.
                                $values += $False
                                continue
                            }
                            throw
                        }

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        } elseif ($StopOnReadError) {
                            $values += $False
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            }
        }
    }
}
