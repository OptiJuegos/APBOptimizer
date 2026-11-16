Function Get-WinUtilToggleStatus {
    param(
        $ToggleSwitch,
        [switch]$BypassCache,
        [switch]$StopOnReadError
    )

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry
    $ToggleSwitchServices = $sync.configs.tweaks.$ToggleSwitch.service
    $ToggleSwitchDriver = $sync.configs.tweaks.$ToggleSwitch.driver
    $ToggleSwitchTask = $sync.configs.tweaks.$ToggleSwitch.scheduledTask

    if (-not $BypassCache) {
        if ($null -eq $sync.ToggleStatusCache) {
            $sync.ToggleStatusCache = @{}
        }

        if ($sync.ToggleStatusCache.ContainsKey($ToggleSwitch)) {
            return [bool]$sync.ToggleStatusCache[$ToggleSwitch]
        }
    }

    $readErrorAction = if ($StopOnReadError) { "Stop" } else { "Continue" }

    if ($ToggleSwitchTask) {
        try {
            $info = Get-WinUtilTelemetryTaskInfo -Name $ToggleSwitchTask.Name
            $disabled = [bool]$info.Disabled
        } catch {
            if ($StopOnReadError) { throw }
            Write-WinUtilLog -Level 'WARN' -Component 'Tasks' -Message "Cannot read task '$($ToggleSwitchTask.Name)': $($_.Exception.Message)"
            $disabled = $false
        }
        if (-not $BypassCache) { $sync.ToggleStatusCache[$ToggleSwitch] = $disabled }
        return $disabled
    }

    if ($ToggleSwitchDriver) {
        $info = Get-WinUtilOptionalDriverInfo -Name $ToggleSwitchDriver.Name
        $enabled = [bool]$info.Disabled
        if (-not $BypassCache) { $sync.ToggleStatusCache[$ToggleSwitch] = $enabled }
        return $enabled
    }

    # The grouped service switches use the same Toggle selection/export system,
    # but their state is a service startup type instead of a registry value.
    if ($ToggleSwitchServices -and -not $ToggleSwitchReg) {
        $enabled = $true
        foreach ($serviceEntry in $ToggleSwitchServices) {
            $service = Get-Service -Name $serviceEntry.Name -ErrorAction $(if ($StopOnReadError) { 'Stop' } else { 'SilentlyContinue' })
            if ($null -eq $service -or [string]$service.StartType -ne [string]$serviceEntry.StartupType) {
                $enabled = $false
                break
            }
        }
        if (-not $BypassCache) { $sync.ToggleStatusCache[$ToggleSwitch] = $enabled }
        return $enabled
    }

    if ($ToggleSwitchReg.Path -match '^HKU:' -and
        -not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -ErrorAction $readErrorAction | Out-Null
    }

    foreach ($regentry in $ToggleSwitchReg) {

        if (Test-Path $regentry.Path -ErrorAction $readErrorAction) {
            $regstate = (Get-ItemProperty -Path $regentry.Path -ErrorAction $readErrorAction).$($regentry.Name)
        } else {
            $regstate = $null
        }

        if ($null -eq $regstate) {
            switch ([string]$regentry.DefaultState) {
                "true"  { $regstate = $regentry.Value }
                "false" { $regstate = $regentry.OriginalValue }
            }
        }

        if ($regstate -ne $regentry.Value) {
            if (-not $BypassCache) {
                $sync.ToggleStatusCache[$ToggleSwitch] = $false
            }
            return $false
        }
    }

    if (-not $BypassCache) {
        $sync.ToggleStatusCache[$ToggleSwitch] = $true
    }
    return $true
}
