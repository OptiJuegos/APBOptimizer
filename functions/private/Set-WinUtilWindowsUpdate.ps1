function Get-WinUtilWindowsUpdateState {
    try {
        $service = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' -Name Start -ErrorAction Stop
        $dlls = @(Get-WinUtilWindowsUpdateFiles)
        $renamedCount = @($dlls | Where-Object {
            -not (Test-Path -LiteralPath $_.OriginalPath) -and (Test-Path -LiteralPath $_.RenamedPath)
        }).Count
        if ($renamedCount -eq $dlls.Count -and $service.Start -eq 4) { return 'Disabled' }
        if ($renamedCount -gt 0 -or $service.Start -eq 4) { return 'Partial' }
        return 'Enabled'
    } catch { return 'Unknown' }
}

function Test-WinUtilWindowsUpdateRecoveryRequired {
    $path = 'HKLM:\SOFTWARE\OptiUtil\WindowsUpdateBackup'
    $existing = Get-ItemProperty -LiteralPath $path -Name Snapshot -ErrorAction SilentlyContinue
    $snapshot = $null
    if ($existing -and $existing.Snapshot) {
        try { $snapshot = $existing.Snapshot | ConvertFrom-Json -ErrorAction Stop }
        catch { return $false }
    }
    foreach ($file in @(Get-WinUtilWindowsUpdateFiles)) {
        if ((Test-Path -LiteralPath $file.OriginalPath) -or -not (Test-Path -LiteralPath $file.RenamedPath)) { continue }
        if ($null -eq $snapshot) { return $true }
        $entry = $snapshot.Files | Where-Object { $_.Name -eq $file.Name } | Select-Object -First 1
        if ($null -eq $entry -or -not $entry.OriginalExisted -or $entry.RenamedExisted) { return $true }
    }
    return $false
}

function Get-WinUtilWindowsUpdateRestoreIssues {
    $issues = @()
    foreach ($file in @(Get-WinUtilWindowsUpdateFiles)) {
        if (-not (Test-Path -LiteralPath $file.OriginalPath)) {
            $issues += "Missing $($file.Name).dll"
        }
        if (Test-Path -LiteralPath $file.RenamedPath) {
            $issues += "$($file.Name)_BAK.dll is still present"
        }
    }
    foreach ($name in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
        $service = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name Start -ErrorAction SilentlyContinue
        if ($service -and [int]$service.Start -eq 4) { $issues += "Service $name remains disabled" }
    }
    $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -ErrorAction SilentlyContinue
    if ($policy -and $policy.NoAutoUpdate -eq 1) { $issues += 'NoAutoUpdate is still 1' }
    return @($issues)
}

function Update-WinUtilWindowsUpdateStatusUI {
    if ($null -eq $sync.WPFWindowsUpdateStatus) { return }
    $state = Get-WinUtilWindowsUpdateState
    $messages = if ($sync.Language -eq 'es') {
        @{ Disabled = 'Estado: DLL de Windows Update renombradas y servicio deshabilitado.'; Partial = 'Estado: bloqueo parcial. Revisa el registro.'; Enabled = 'Estado: Windows Update no está bloqueado por APBOptimizer.'; Unknown = 'Estado: no se pudo consultar.' }
    } else {
        @{ Disabled = 'Status: Windows Update DLLs renamed and service disabled.'; Partial = 'Status: partially disabled. Check the log.'; Enabled = 'Status: Windows Update is not blocked by APBOptimizer.'; Unknown = 'Status: could not query Windows Update.' }
    }
    $hasSnapshot = $null -ne (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OptiUtil\WindowsUpdateBackup' -Name Snapshot -ErrorAction SilentlyContinue)
    $needsRecovery = Test-WinUtilWindowsUpdateRecoveryRequired
    $canRestore = $hasSnapshot -or $needsRecovery
    $statusText = $messages[$state]
    if ($needsRecovery) {
        $statusText = if ($sync.Language -eq 'es') {
            'Estado: hay DLL renombradas que requieren recuperación. Pulsa Restaurar Windows Update.'
        } else {
            'Status: renamed DLLs need recovery. Select Restore Windows Update.'
        }
    }
    Invoke-WPFUIThread -Async -Parameters @{ Text = $statusText; CanRestore = $canRestore } -ScriptBlock {
        param($Text, $CanRestore)
        if ($sync.WPFWindowsUpdateStatus) { $sync.WPFWindowsUpdateStatus.Text = $Text }
        if ($sync.WPFRestoreWindowsUpdate) { $sync.WPFRestoreWindowsUpdate.IsEnabled = [bool]$CanRestore }
    }
}

function Test-WinUtilWindowsUpdateAdmin {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-WinUtilWindowsUpdateSnapshot {
    param([Parameter(Mandatory)]$Snapshot)
    $path = 'HKLM:\SOFTWARE\OptiUtil\WindowsUpdateBackup'
    $null = New-Item -Path $path -Force -ErrorAction Stop
    $json = $Snapshot | ConvertTo-Json -Depth 8 -Compress
    $null = New-ItemProperty -LiteralPath $path -Name Snapshot -Value $json -PropertyType String -Force -ErrorAction Stop
}

function Set-WinUtilWindowsUpdateServiceStartup {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Automatic', 'Manual', 'Disabled')][string]$StartupType,
        [bool]$Delayed = $false
    )
    $startValue = @{ Automatic = 2; Manual = 3; Disabled = 4 }[$StartupType]
    try {
        if ($StartupType -eq 'Automatic' -and $Delayed) {
            $output = & sc.exe config $Name 'start=' 'delayed-auto' 2>&1
            if ($LASTEXITCODE -ne 0) { throw "sc.exe returned $LASTEXITCODE`: $output" }
        } else {
            Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        }
    } catch {
        # SCM may deny SERVICE_CHANGE_CONFIG on protected services even to an
        # elevated administrator. Match the BAT's direct Start value fallback.
        Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -Value $startValue -ErrorAction Stop
        if ($StartupType -eq 'Automatic') {
            Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name DelayedAutoStart -Value ([int]$Delayed) -ErrorAction Stop
        }
        Write-WinUtilLog -Component 'WindowsUpdate' -Message "Service $Name startup changed via registry fallback (SCM refused direct change)."
    }
}

function Restore-WinUtilWindowsUpdateLegacyPolicy {
    param([Parameter(Mandatory)]$Snapshot)
    if ($null -eq $Snapshot.LegacyPolicy -or -not $Snapshot.LegacyPolicy.Pending) { return }
    # One-time migration: undo the NoAutoUpdate value applied by the earlier
    # APBOptimizer version. New installations never change this Windows policy.
    $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if ($Snapshot.LegacyPolicy.Present) {
        $null = New-Item -Path $path -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $path -Name NoAutoUpdate -PropertyType DWord -Value ([int]$Snapshot.LegacyPolicy.Value) -Force -ErrorAction Stop
    } elseif (Get-ItemProperty -LiteralPath $path -Name NoAutoUpdate -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -LiteralPath $path -Name NoAutoUpdate -ErrorAction Stop
    }
    $Snapshot.LegacyPolicy.Pending = $false
    Save-WinUtilWindowsUpdateSnapshot -Snapshot $Snapshot
    Write-WinUtilLog -Component 'WindowsUpdate' -Message 'Restored legacy NoAutoUpdate policy; aggressive mode no longer uses it.'
}

function Initialize-WinUtilWindowsUpdateRecovery {
    param($Snapshot)

    if ($null -eq $Snapshot) {
        $Snapshot = [pscustomobject]@{
            Version = 2; RecoveryOnly = $true; Services = @(); Tasks = @()
            Files = @(); LegacyPolicy = $null
        }
    }
    # There is no longer an original baseline. Explicit recovery uses the ACL
    # on the renamed file and a working Manual service startup, not invented
    # "original" values. Save this repair journal before changing anything.
    foreach ($file in @(Get-WinUtilWindowsUpdateFiles)) {
        if ((Test-Path -LiteralPath $file.OriginalPath) -or -not (Test-Path -LiteralPath $file.RenamedPath)) { continue }
        $entry = @($Snapshot.Files | Where-Object { $_.Name -eq $file.Name } | Select-Object -First 1)
        if ($entry.Count -gt 0 -and $entry[0].OriginalExisted -and -not $entry[0].RenamedExisted) { continue }
        $descriptor = (Get-Acl -LiteralPath $file.RenamedPath -ErrorAction Stop).Sddl
        if ([string]::IsNullOrWhiteSpace($descriptor)) { throw "Cannot safely recover $($file.Name).dll without its current security descriptor." }
        $Snapshot.Files = @($Snapshot.Files | Where-Object { $_.Name -ne $file.Name }) + @([pscustomobject]@{
            Name = $file.Name; OriginalExisted = $true
            RenamedExisted = $false; SecurityDescriptor = $descriptor
        })
    }
    foreach ($name in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        $settings = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name Start -ErrorAction SilentlyContinue
        if (-not $service -or -not $settings -or [int]$settings.Start -ne 4) { continue }
        $entry = @($Snapshot.Services | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
        if ($entry.Count -gt 0 -and $entry[0].Changed -and [int]$entry[0].Start -ne 4) { continue }
        $Snapshot.Services = @($Snapshot.Services | Where-Object { $_.Name -ne $name }) + @([pscustomobject]@{
            Name = $name; Start = 3; Delayed = 0; Running = $false; Changed = $true
        })
    }
    $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -ErrorAction SilentlyContinue
    if ($policy -and $policy.NoAutoUpdate -eq 1) {
        $Snapshot.LegacyPolicy = [pscustomobject]@{ Present = $false; Value = 0; Pending = $true }
    }
    Save-WinUtilWindowsUpdateSnapshot -Snapshot $Snapshot
    Write-WinUtilLog -Component 'WindowsUpdate' -Message 'Started explicit recovery of missing DLLs and update configuration. Original settings may be unknown.'
    return $Snapshot
}

function Set-WinUtilWindowsUpdate {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore', 'Recover')][string]$Mode)

    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to change Windows Update.'
    }

    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\WindowsUpdateBackup'
    $original = $null
    if (Test-Path -LiteralPath $backupPath) {
        $saved = (Get-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop).Snapshot
        if ([string]::IsNullOrWhiteSpace($saved)) { throw 'Windows Update backup is empty.' }
        $original = $saved | ConvertFrom-Json -ErrorAction Stop
        if ($original.Version -notin @(1, 2)) { throw 'Windows Update backup has an unsupported version.' }
    }

    if ($null -ne $original -and $original.Version -eq 1) {
        # Preserve the original V1 baseline, even when Windows Update has already
        # been partially disabled. Only restore settings this tool actually changed.
        foreach ($entry in @($original.Services)) {
            $current = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$($entry.Name)" -ErrorAction Stop
            $entry | Add-Member -NotePropertyName Changed -NotePropertyValue ([int]$current.Start -ne [int]$entry.Start) -Force
        }
        if (-not @($original.Services | Where-Object { $_.Name -eq 'uhssvc' }).Count) {
            $health = Get-Service -Name 'uhssvc' -ErrorAction SilentlyContinue
            if ($health) {
                $healthSettings = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\uhssvc' -ErrorAction Stop
                $original.Services = @($original.Services) + @([pscustomobject]@{
                    Name = 'uhssvc'; Start = [int]$healthSettings.Start
                    Delayed = [int]$healthSettings.DelayedAutoStart
                    Running = ($health.Status -eq 'Running'); Changed = $false
                })
            }
        }
        # Old snapshots can contain scheduled-task metadata. Preserve it as
        # historical data, but never inspect or change Task Scheduler entries.
        $original | Add-Member -NotePropertyName LegacyPolicy -NotePropertyValue ([pscustomobject]@{
            Present = [bool]$original.PolicyPresent
            Value = [int]$original.PolicyValue
            Pending = $true
        }) -Force
        $original | Add-Member -NotePropertyName Files -NotePropertyValue @(Get-WinUtilWindowsUpdateFileSnapshot) -Force
        $original.Version = 2
        Save-WinUtilWindowsUpdateSnapshot -Snapshot $original
        Write-WinUtilLog -Component 'WindowsUpdate' -Message 'Migrated original Windows Update settings from backup v1 to v2.'
    }

    if ($Mode -eq 'Recover') {
        $original = Initialize-WinUtilWindowsUpdateRecovery -Snapshot $original
        $Mode = 'Restore'
    }

    if ($Mode -eq 'Disable') {
        if ($null -eq $original) {
            $services = @()
            foreach ($name in @('wuauserv', 'UsoSvc', 'uhssvc', 'WaaSMedicSvc')) {
                $service = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($null -eq $service) { continue }
                $settings = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -ErrorAction Stop
                $services += [pscustomobject]@{
                    Name = $name
                    Start = [int]$settings.Start
                    Delayed = [int]$settings.DelayedAutoStart
                    Running = ($service.Status -eq 'Running')
                    Changed = $false
                }
            }
            $original = [pscustomobject]@{
                Version = 2
                Services = @($services)
                Tasks = @() # Backward-compatible snapshot field; not managed.
                Files = @(Get-WinUtilWindowsUpdateFileSnapshot)
                LegacyPolicy = $null
            }
            # Save before changing Windows, and keep this snapshot for subsequent attempts.
            Save-WinUtilWindowsUpdateSnapshot -Snapshot $original
        }

        try { Restore-WinUtilWindowsUpdateLegacyPolicy -Snapshot $original }
        catch { Write-Warning "Could not remove legacy Windows Update policy: $($_.Exception.Message)" }

        foreach ($entry in $original.Services) {
            try {
                $current = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$($entry.Name)" -ErrorAction Stop
                if ([int]$current.Start -ne 4) {
                    Set-WinUtilWindowsUpdateServiceStartup -Name $entry.Name -StartupType Disabled
                    $entry.Changed = $true
                    Save-WinUtilWindowsUpdateSnapshot -Snapshot $original
                }
                $service = Get-Service -Name $entry.Name -ErrorAction Stop
                if ($service.Status -ne 'Stopped') {
                    Stop-Service -Name $entry.Name -Force -ErrorAction Stop
                    $entry.Changed = $true
                    Save-WinUtilWindowsUpdateSnapshot -Snapshot $original
                }
                Write-WinUtilLog -Component 'WindowsUpdate' -Message "Disabled service $($entry.Name)."
            } catch {
                Write-Warning "Could not disable Windows Update service $($entry.Name): $($_.Exception.Message)"
            }
        }
        Rename-WinUtilWindowsUpdateFiles -Snapshot $original
        Write-WinUtilLog -Component 'WindowsUpdate' -Message 'Disable attempt completed. Previous settings retained for restoration.'
        return
    }

    if ($null -eq $original) {
        throw 'No APBOptimizer Windows Update backup exists. Cannot safely restore unknown settings.'
    }

    $failed = $false
    if (-not (Restore-WinUtilWindowsUpdateFiles -Snapshot $original)) { $failed = $true }
    foreach ($entry in $original.Services | Where-Object { $_.Changed }) {
        try {
            $startupMode = switch ([int]$entry.Start) {
                2 { 'Automatic' }
                3 { 'Manual' }
                4 { 'Disabled' }
                default { throw "Unexpected original startup mode for $($entry.Name): $($entry.Start)" }
            }
            Set-WinUtilWindowsUpdateServiceStartup -Name $entry.Name -StartupType $startupMode -Delayed ([int]$entry.Delayed -eq 1)
            if ($entry.Running -and $startupMode -ne 'Disabled') {
                $service = Get-Service -Name $entry.Name -ErrorAction Stop
                if ($service.Status -ne 'Running') { Start-Service -Name $entry.Name -ErrorAction Stop }
            }
            $entry.Changed = $false
            Save-WinUtilWindowsUpdateSnapshot -Snapshot $original
        } catch {
            $failed = $true
            Write-Warning "Could not restore service $($entry.Name): $($_.Exception.Message)"
        }
    }

    try { Restore-WinUtilWindowsUpdateLegacyPolicy -Snapshot $original }
    catch {
        $failed = $true
        Write-Warning "Could not restore old APBOptimizer NoAutoUpdate policy: $($_.Exception.Message)"
    }

    $remaining = @(Get-WinUtilWindowsUpdateRestoreIssues)
    if ($remaining.Count -gt 0) {
        $failed = $true
        foreach ($issue in $remaining) { Write-Warning "Windows Update restoration incomplete: $issue" }
    }
    if ($failed) {
        Write-Warning 'Some settings could not be restored. The backup was kept so you can retry.'
    } else {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
        Write-WinUtilLog -Component 'WindowsUpdate' -Message 'Original Windows Update settings restored.'
    }
}
