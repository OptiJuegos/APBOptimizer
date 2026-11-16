function Get-WinUtilOptionalDriverNames {
    # Explicit allowlist. Never accept an arbitrary kernel driver name.
    return @('Telemetry', 'PEAUTH', 'tcpipreg', 'IntelPMT', 'AppLockerFltr', 'GpuEnergyDrv', 'IObitUnlocker', 'UCPD')
}

function Get-WinUtilUcpdTask {
    # UCPD's scheduled task can reconfigure the driver on logon. Only manage
    # this one exact task, not the other AppxDeploymentClient tasks.
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'Task Scheduler PowerShell support is unavailable; UCPD startup cannot be managed safely.'
    }
    return Get-ScheduledTask -ErrorAction Stop |
        Where-Object {
            $_.TaskName -eq 'UCPD velocity' -and
            $_.TaskPath -eq '\Microsoft\Windows\AppxDeploymentClient\'
        } | Select-Object -First 1
}

function Get-WinUtilOptionalDriverBackup {
    param([Parameter(Mandatory)][string]$Name)
    $saved = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OptiUtil\DriverStartupBackup' -Name $Name -ErrorAction SilentlyContinue
    if (-not $saved) { return $null }
    $serialized = [string]$saved.$Name
    if ([string]::IsNullOrWhiteSpace($serialized)) { return $null }
    $backup = ConvertFrom-Json -InputObject $serialized -ErrorAction Stop
    if ($backup.Version -ne 1 -or $backup.Name -ne $Name -or
        $backup.Start -notin $(if ($Name -eq 'UCPD') { @(1, 2, 3) } else { @(2, 3) }) -or
        ($Name -eq 'UCPD' -and
            (@($backup.PSObject.Properties.Name) -notcontains 'TaskPresent' -or
             @($backup.PSObject.Properties.Name) -notcontains 'TaskEnabled'))) {
        throw "Unrecognized saved driver configuration for $Name. No changes were made."
    }
    return $backup
}

function Get-WinUtilOptionalDriverInfo {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notin (Get-WinUtilOptionalDriverNames)) { throw "Driver $Name is not approved for optional management." }
    $info = [pscustomobject]@{
        Name = $Name; Present = $false; CanChange = $false; Disabled = $false
        Managed = $false; Start = $null; Type = $null; ImagePath = ''; Reason = 'Not installed'
    }
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    $entry = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $entry -or $null -eq $entry.Start -or $null -eq $entry.Type) { return $info }
    $info.Present = $true
    $info.Start = [int]$entry.Start
    $info.Type = [int]$entry.Type
    $info.ImagePath = [string]$entry.ImagePath
    # Disabled is the actual driver startup state. Even if APBOptimizer cannot
    # restore an unmanaged Start=4 driver, it must show as already disabled
    # rather than an unchecked (apparently active) switch.
    $info.Disabled = ($info.Start -eq 4)

    if ($info.Type -notin @(1, 2)) { $info.Reason = 'Not a kernel or file-system driver'; return $info }
    if ($info.Start -eq 0 -or ($info.Start -eq 1 -and $Name -ne 'UCPD')) {
        $info.Reason = 'Boot/System startup: protected'
        return $info
    }
    if ($Name -eq 'UCPD' -and ($info.Type -ne 2 -or $info.ImagePath -notmatch '(?i)(^|[\\/])UCPD\.sys$')) {
        $info.Reason = 'UCPD driver identity does not match the expected UCPD.sys filter driver'
        return $info
    }
    if ($Name -eq 'AppLockerFltr' -and ($info.Type -ne 2 -or $info.ImagePath -notmatch '(?i)(^|[\\/])AppLockerFltr\.sys$')) {
        $info.Reason = 'AppLocker filter identity does not match the expected AppLockerFltr.sys driver'
        return $info
    }
    if ($null -ne $entry.ErrorControl -and [int]$entry.ErrorControl -ge 2) {
        $info.Reason = 'Severe/Critical boot error handling: protected'
        return $info
    }

    $backup = Get-WinUtilOptionalDriverBackup -Name $Name
    if ($backup -and ($backup.Type -ne $info.Type -or $backup.ImagePath -ne $info.ImagePath)) {
        $info.Reason = 'Driver identity changed since backup: review manually'
        return $info
    }
    $info.Managed = [bool]$backup
    if ($info.Start -eq 4 -and -not $info.Managed) {
        $info.Reason = 'Already disabled outside APBOptimizer; no original state to restore'
        return $info
    }
    if ($info.Start -notin $(if ($Name -eq 'UCPD') { @(1, 2, 3, 4) } else { @(2, 3, 4) })) {
        $info.Reason = 'Unsupported startup value'
        return $info
    }
    $info.CanChange = $true
    if ($Name -eq 'UCPD') {
        try {
            $task = Get-WinUtilUcpdTask
            if ($task -and $task.State -ne 'Disabled') { $info.Disabled = $false }
        } catch {
            $info.CanChange = $false
            $info.Disabled = $false
            $info.Reason = "Cannot inspect UCPD velocity task: $($_.Exception.Message)"
            return $info
        }
    }
    $info.Reason = if ($info.Disabled) { 'Disabled by APBOptimizer (takes effect after reboot)' } else { 'Optional driver; reboot needed after change' }
    return $info
}

function Set-WinUtilOptionalDriverStartup {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet(1, 2, 3, 4)][int]$Start
    )
    if ($Start -eq 1 -and $Name -ne 'UCPD') { throw "System-start is only permitted for restoring the UCPD driver." }
    $mode = @{ 1 = 'system'; 2 = 'auto'; 3 = 'demand'; 4 = 'disabled' }[$Start]
    $output = & sc.exe config $Name 'start=' $mode 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Service Control Manager refused to configure driver $Name ($LASTEXITCODE): $($output -join ' ')"
    }
}

function Set-WinUtilOptionalDriver {
    param(
        [Parameter(Mandatory)][ValidateSet('Telemetry', 'PEAUTH', 'tcpipreg', 'IntelPMT', 'AppLockerFltr', 'GpuEnergyDrv', 'IObitUnlocker', 'UCPD')][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode
    )
    if (-not (Test-WinUtilWindowsUpdateAdmin)) { throw 'Administrator privileges required to change driver startup.' }
    $info = Get-WinUtilOptionalDriverInfo -Name $Name
    if (-not $info.Present) {
        Write-WinUtilLog -Component 'Drivers' -Message "Driver $Name is not installed. Skipping."
        return
    }
    if (-not $info.CanChange) { throw "Driver $Name cannot be changed: $($info.Reason)" }

    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\DriverStartupBackup'
    $servicePath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if ($Mode -eq 'Disable') {
        if ($info.Disabled) { return }
        $existing = Get-WinUtilOptionalDriverBackup -Name $Name
        if (-not $existing) {
            $ucpdTask = if ($Name -eq 'UCPD') { Get-WinUtilUcpdTask } else { $null }
            $existing = [pscustomobject]@{
                Version = 1; Name = $Name; Start = $info.Start
                Type = $info.Type; ImagePath = $info.ImagePath
            }
            if ($Name -eq 'UCPD') {
                $existing | Add-Member -NotePropertyName TaskPresent -NotePropertyValue ([bool]$ucpdTask)
                $existing | Add-Member -NotePropertyName TaskEnabled -NotePropertyValue ([bool]($ucpdTask -and $ucpdTask.State -ne 'Disabled'))
            }
            # Save first. Never infer an original startup value during Undo.
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $backupPath -Name $Name -PropertyType String -Value ($existing | ConvertTo-Json -Depth 4 -Compress) -Force -ErrorAction Stop
        }
        $target = 4
    } else {
        $existing = Get-WinUtilOptionalDriverBackup -Name $Name
        if (-not $existing) { throw "No APBOptimizer backup exists for $Name; refusing to invent its previous startup configuration." }
        $target = [int]$existing.Start
    }

    if ($Name -eq 'UCPD' -and $Mode -eq 'Disable') {
        $task = Get-WinUtilUcpdTask
        if ($task -and $task.State -ne 'Disabled') {
            $null = Disable-ScheduledTask -TaskName 'UCPD velocity' -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -ErrorAction Stop
        }
        $task = Get-WinUtilUcpdTask
        if ($task -and $task.State -ne 'Disabled') {
            throw 'UCPD velocity task is still enabled. Original startup backup retained.'
        }
    }

    # Driver binaries, device bindings, ACLs and loaded kernel modules remain
    # untouched. Only driver startup and the exact UCPD velocity task are managed.
    Set-WinUtilOptionalDriverStartup -Name $Name -Start $target
    $current = Get-ItemProperty -LiteralPath $servicePath -ErrorAction Stop
    if ([int]$current.Start -ne $target) {
        throw "Driver $Name startup change could not be verified. Backup preserved."
    }

    if ($Name -eq 'UCPD' -and $Mode -eq 'Restore') {
        $task = Get-WinUtilUcpdTask
        if ($existing.TaskPresent -and -not $task) {
            throw 'UCPD velocity task was present originally but is now missing. The recovery backup was preserved.'
        }
        if ($existing.TaskPresent) {
            $shouldEnable = [bool]$existing.TaskEnabled
            if ($shouldEnable -and $task.State -eq 'Disabled') {
                $null = Enable-ScheduledTask -TaskName 'UCPD velocity' -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -ErrorAction Stop
            } elseif (-not $shouldEnable -and $task.State -ne 'Disabled') {
                $null = Disable-ScheduledTask -TaskName 'UCPD velocity' -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -ErrorAction Stop
            }
            $task = Get-WinUtilUcpdTask
            if (-not $task -or (($task.State -ne 'Disabled') -ne $shouldEnable)) {
                throw 'UCPD velocity task could not be verified after restoration. Backup retained.'
            }
        }
    }

    if ($Mode -eq 'Restore') {
        Remove-ItemProperty -LiteralPath $backupPath -Name $Name -ErrorAction Stop
    }
    Write-WinUtilLog -Component 'Drivers' -Message "$Mode $Name startup verified. Restart Windows to apply driver load changes."
}
