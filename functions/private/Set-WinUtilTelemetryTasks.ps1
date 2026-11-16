function Get-WinUtilTelemetryTaskTargets {
    # Explicit allowlist: no Windows Update, Defender, maintenance or UCPD tasks.
    # Firefox creates a machine/profile-specific hex suffix, so it is the only
    # entry resolved by a strict name pattern inside its exact Mozilla folder.
    return @(
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'Microsoft Compatibility Appraiser' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'ProgramDataUpdater' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'Consolidator' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'UsbCeip' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'KernelCeipTask' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'Microsoft Compatibility Appraiser Exp' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Windows Media Sharing\'; TaskName = 'UpdateLibrary' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Flighting\FeatureConfig\'; TaskName = 'UsageDataReporting' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Sustainability\'; TaskName = 'SustainabilityTelemetry' }
        [pscustomobject]@{ TaskPath = '\Mozilla\'; TaskName = 'Firefox Default Browser Agent'; TaskNameRegex = '^Firefox Default Browser Agent [0-9A-Fa-f]{8,64}$' }
    )
}

function Get-WinUtilTelemetryTaskSnapshot {
    # Read only allowlisted folders through the Task Scheduler COM API.
    $paths = @(Get-WinUtilTelemetryTaskTargets | Select-Object -ExpandProperty TaskPath -Unique)
    $scheduler = $null
    try {
        $scheduler = New-Object -ComObject 'Schedule.Service' -ErrorAction Stop
        $scheduler.Connect()
    } catch {
        if ($null -ne $scheduler) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($scheduler) }
        return @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -in $paths })
    }

    $snapshot = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($path in $paths) {
            $folder = $null
            try {
                $folder = $scheduler.GetFolder($path.TrimEnd('\'))
                foreach ($task in $folder.GetTasks(1)) {
                    $snapshot.Add([pscustomobject]@{
                        TaskPath = $path
                        TaskName = [string]$task.Name
                        State = if ($task.State -eq 1) { 'Disabled' } else { 'Ready' }
                    })
                }
            } catch {
                if ($_.Exception.HResult -ne -2147024894) { throw }
            } finally {
                if ($null -ne $folder) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($folder) }
            }
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($scheduler)
    }
    return $snapshot.ToArray()
}

function Test-WinUtilTelemetryTaskAllowed {
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)
    foreach ($target in Get-WinUtilTelemetryTaskTargets) {
        if ($target.TaskPath -ne $TaskPath) { continue }
        if ($target.TaskNameRegex) {
            if ($TaskName -cmatch $target.TaskNameRegex) { return $true }
        } elseif ($TaskName -eq $target.TaskName) {
            return $true
        }
    }
    return $false
}

function Get-WinUtilTelemetryTaskBackup {
    $saved = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OptiUtil\TelemetryTaskBackup' -Name Snapshot -ErrorAction SilentlyContinue
    if (-not $saved -or [string]::IsNullOrWhiteSpace([string]$saved.Snapshot)) { return $null }
    $backup = ConvertFrom-Json -InputObject ([string]$saved.Snapshot) -ErrorAction Stop
    if ($backup.Version -ne 1 -or @($backup.Tasks).Count -lt 1) {
        throw 'Unrecognized telemetry task backup; no changes were made.'
    }
    $seen = @{}
    foreach ($entry in @($backup.Tasks)) {
        $key = [string]$entry.TaskPath + [string]$entry.TaskName
        if (-not (Test-WinUtilTelemetryTaskAllowed -TaskPath $entry.TaskPath -TaskName $entry.TaskName) -or
            $seen.ContainsKey($key) -or
            $entry.Enabled -isnot [bool]) {
            throw 'Telemetry task backup contains an invalid or duplicate target; no changes were made.'
        }
        $seen[$key] = $true
    }
    return $backup
}

function Get-WinUtilTelemetryTask {
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)
    # Query the scheduler once for exact path/name matching; do not use a wildcard
    # or assume that a task with the same short name in another folder is ours.
    return Get-ScheduledTask -ErrorAction Stop |
        Where-Object { $_.TaskPath -eq $TaskPath -and $_.TaskName -eq $TaskName } |
        Select-Object -First 1
}

function Get-WinUtilTelemetryTaskTarget {
    param([Parameter(Mandatory)][string]$Name)
    $match = @(Get-WinUtilTelemetryTaskTargets | Where-Object { $_.TaskName -eq $Name })
    if ($match.Count -ne 1) { throw "Scheduled task '$Name' is not approved for management." }
    return $match[0]
}

function Get-WinUtilTelemetryTaskMatches {
    param([Parameter(Mandatory)]$Target, [object[]]$TaskSnapshot)
    # Read the scheduler in one operation and only return entries in the
    # allowlisted folder. A UI snapshot avoids querying Windows for each row.
    $candidates = if ($PSBoundParameters.ContainsKey('TaskSnapshot')) {
        $TaskSnapshot
    } else {
        @(Get-ScheduledTask -ErrorAction Stop)
    }
    return $candidates |
        Where-Object {
            $_.TaskPath -eq $Target.TaskPath -and
            $(if ($Target.TaskNameRegex) {
                $_.TaskName -cmatch $Target.TaskNameRegex
            } else {
                $_.TaskName -eq $Target.TaskName
            })
        }
}

function Get-WinUtilTelemetryTaskInfo {
    param([Parameter(Mandatory)][string]$Name, [object[]]$TaskSnapshot, $Backup)
    $target = Get-WinUtilTelemetryTaskTarget -Name $Name
    if (-not $PSBoundParameters.ContainsKey('Backup')) {
        $Backup = Get-WinUtilTelemetryTaskBackup
    }
    $saved = @(Get-WinUtilTelemetryTaskBackupEntries -Target $target -Backup $Backup)
    [object[]]$tasks = if ($PSBoundParameters.ContainsKey('TaskSnapshot')) {
        @(Get-WinUtilTelemetryTaskMatches -Target $target -TaskSnapshot $TaskSnapshot)
    } else {
        @(Get-WinUtilTelemetryTaskMatches -Target $target)
    }
    $disabled = ($tasks.Count -gt 0 -and @($tasks | Where-Object { $_.State -ne 'Disabled' }).Count -eq 0)
    $managed = ($saved.Count -gt 0)
    $anyEnabled = @($tasks | Where-Object { $_.State -ne 'Disabled' }).Count -gt 0
    return [pscustomobject]@{
        Present = ($tasks.Count -gt 0)
        Disabled = $disabled
        Managed = $managed
        CanChange = ($tasks.Count -gt 0 -and ($anyEnabled -or $managed))
        Reason = if ($tasks.Count -eq 0) { 'Task is not installed' }
                 elseif ($disabled -and -not $managed) { 'Already disabled outside APBOptimizer: no original enabled state to restore' }
                 else { '' }
    }
}

function Get-WinUtilTelemetryTaskBackupEntries {
    param([Parameter(Mandatory)]$Target, $Backup)
    return @($Backup.Tasks | Where-Object {
        $_.TaskPath -eq $Target.TaskPath -and
        $(if ($Target.TaskNameRegex) {
            $_.TaskName -cmatch $Target.TaskNameRegex
        } else {
            $_.TaskName -eq $Target.TaskName
        })
    })
}

function Save-WinUtilTelemetryTaskBackup {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\TelemetryTaskBackup'
    if ($Entries.Count -eq 0) {
        Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
    } else {
        $null = New-Item -Path $backupPath -Force -ErrorAction Stop
        $snapshot = [pscustomobject]@{ Version = 1; Tasks = @($Entries) }
        $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -PropertyType String -Value ($snapshot | ConvertTo-Json -Depth 5 -Compress) -Force -ErrorAction Stop
    }
}

function Get-WinUtilTelemetryTaskStatus {
    $backup = Get-WinUtilTelemetryTaskBackup
    if (-not $backup) { return $false }
    foreach ($entry in @($backup.Tasks)) {
        $task = Get-WinUtilTelemetryTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName
        if (-not $task -or $task.State -ne 'Disabled') { return $false }
    }
    return $true
}

function Set-WinUtilTelemetryTask {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode
    )
    $target = Get-WinUtilTelemetryTaskTarget -Name $Name
    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to manage scheduled tasks.'
    }
    foreach ($command in @('Get-ScheduledTask', 'Disable-ScheduledTask', 'Enable-ScheduledTask')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Task Scheduler command $command is unavailable."
        }
    }
    $backup = Get-WinUtilTelemetryTaskBackup
    [object[]]$entries = if ($backup) { @($backup.Tasks) } else { @() }
    $saved = @(Get-WinUtilTelemetryTaskBackupEntries -Target $target -Backup $backup)
    $tasks = @(Get-WinUtilTelemetryTaskMatches -Target $target)
    if ($tasks.Count -eq 0) {
        if ($saved.Count -gt 0) { throw "The backed-up task '$Name' is missing; snapshot retained." }
        Write-WinUtilLog -Component 'Tasks' -Message "Optional task '$Name' is not installed. Skipping."
        return
    }

    if ($Mode -eq 'Disable') {
        $pending = @($tasks | Where-Object {
            $taskEntry = $_
            $taskEntry.State -ne 'Disabled' -and
                @($entries | Where-Object {
                    $_.TaskPath -eq $taskEntry.TaskPath -and $_.TaskName -eq $taskEntry.TaskName
                }).Count -eq 0
        })
        if ($pending.Count -gt 0) {
            # Journal all original states before the first change, including
            # every matching Firefox agent when multiple profiles are present.
            foreach ($task in $pending) {
                $entries += [pscustomobject]@{
                    TaskPath = $task.TaskPath; TaskName = $task.TaskName; Enabled = $true
                }
            }
            Save-WinUtilTelemetryTaskBackup -Entries $entries
        }
        foreach ($task in $tasks) {
            if ($task.State -ne 'Disabled') {
                $null = Disable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop
            }
        }
    } else {
        if ($saved.Count -eq 0) {
            throw "No APBOptimizer backup for '$Name'; refusing to enable a task without its original state."
        }
        foreach ($entry in $saved) {
            $task = @($tasks | Where-Object { $_.TaskPath -eq $entry.TaskPath -and $_.TaskName -eq $entry.TaskName })
            if ($task.Count -ne 1) {
                throw "Backed-up scheduled task '$($entry.TaskName)' disappeared; snapshot retained."
            }
            if ($entry.Enabled -and $task[0].State -eq 'Disabled') {
                $null = Enable-ScheduledTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName -ErrorAction Stop
            } elseif (-not $entry.Enabled -and $task[0].State -ne 'Disabled') {
                $null = Disable-ScheduledTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName -ErrorAction Stop
            }
        }
    }

    foreach ($task in $tasks) {
        $verified = Get-WinUtilTelemetryTask -TaskPath $task.TaskPath -TaskName $task.TaskName
        $previous = @($saved | Where-Object { $_.TaskPath -eq $task.TaskPath -and $_.TaskName -eq $task.TaskName })
        $shouldEnable = ($Mode -eq 'Restore' -and $previous.Count -gt 0 -and [bool]$previous[0].Enabled)
        if (-not $verified -or (($verified.State -ne 'Disabled') -ne $shouldEnable)) {
            throw "Could not verify '$($task.TaskName)' after $Mode. Snapshot retained."
        }
    }
    if ($Mode -eq 'Restore') {
        $remaining = @($entries | Where-Object {
            $entry = $_
            @($saved | Where-Object {
                $_.TaskPath -eq $entry.TaskPath -and $_.TaskName -eq $entry.TaskName
            }).Count -eq 0
        })
        Save-WinUtilTelemetryTaskBackup -Entries $remaining
    }
    Write-WinUtilLog -Component 'Tasks' -Message "$Mode optional scheduled task '$Name' verified."
}

function Set-WinUtilTelemetryTasks {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode)
    # Backward-compatible entry point for older APBOptimizer exports containing
    # WPFTweaksDisableTelemetryTasks. The new group calls each task separately.
    if ($Mode -eq 'Restore') {
        $backup = Get-WinUtilTelemetryTaskBackup
        if (-not $backup) { throw 'No APBOptimizer telemetry task backup exists.' }
        $names = @(foreach ($target in Get-WinUtilTelemetryTaskTargets) {
            if (@(Get-WinUtilTelemetryTaskBackupEntries -Target $target -Backup $backup).Count -gt 0) {
                $target.TaskName
            }
        })
    } else {
        # This entry point belonged to the former five-task bulk checkbox.
        # Never disable newly added optional tasks from an old preset/export.
        $names = @(
            'Microsoft Compatibility Appraiser', 'ProgramDataUpdater',
            'Consolidator', 'UsbCeip', 'KernelCeipTask'
        )
    }
    foreach ($name in $names) {
        Set-WinUtilTelemetryTask -Name $name -Mode $Mode
    }
}
