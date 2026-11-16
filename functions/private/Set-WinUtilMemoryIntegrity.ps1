function Get-WinUtilMemoryIntegrityRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    $result = [pscustomobject]@{ Present = $false; Kind = ''; Value = $null }
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    } catch {
        # A missing registry key is fine. Denied access, a broken provider,
        # or other read errors must NOT look like a nonexistent policy/lock.
        if ($_.Exception -is [System.Management.Automation.ItemNotFoundException] -or
            $_.FullyQualifiedErrorId -like 'PathNotFound,*' -or
            $_.FullyQualifiedErrorId -like 'ItemNotFound,*') {
            return $result
        }
        throw
    }
    if ($null -eq $key -or $Name -notin @($key.GetValueNames())) { return $result }
    $result.Present = $true
    $result.Kind = [string]$key.GetValueKind($Name)
    $result.Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return $result
}

function Get-WinUtilMemoryIntegrityBackup {
    $path = 'HKLM:\SOFTWARE\OptiUtil\MemoryIntegrityBackup'
    $saved = Get-WinUtilMemoryIntegrityRegistryValue -Path $path -Name Snapshot
    if (-not $saved.Present) { return $null }
    if ($saved.Kind -ne 'String' -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
        throw 'HVCI backup exists but is empty. Refusing to overwrite its recovery information.'
    }
    $snapshot = ConvertFrom-Json -InputObject ([string]$saved.Value) -ErrorAction Stop
    if ($snapshot.Version -ne 1 -or $snapshot.HadEnabled -isnot [bool] -or
        ($snapshot.HadEnabled -and ($snapshot.Kind -ne 'DWord' -or
            $null -eq $snapshot.EnabledValue -or
            [string]$snapshot.EnabledValue -notmatch '^-?\d+$'))) {
        throw 'Unrecognized HVCI backup; refusing to change memory integrity.'
    }
    return $snapshot
}

function Assert-WinUtilMemoryIntegrityIsConfigurable {
    # Enabling/disabling a UEFI-locked or policy-managed HVCI installation
    # requires its management authority. Never overwrite those settings.
    $deviceGuard = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
    $scenario = "$deviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
    foreach ($path in @($deviceGuard, $scenario)) {
        $locked = Get-WinUtilMemoryIntegrityRegistryValue -Path $path -Name Locked
        if ($locked.Present -and [string]$locked.Value -ne '0') {
            throw 'HVCI/DeviceGuard has a UEFI lock. Change it through the authorized firmware/policy procedure instead.'
        }
    }
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'
    $policyValue = Get-WinUtilMemoryIntegrityRegistryValue -Path $policy -Name HypervisorEnforcedCodeIntegrity
    if ($policyValue.Present) {
        throw 'Memory integrity is configured by Group Policy; change the managed policy rather than overriding it.'
    }
}

function Set-WinUtilMemoryIntegrity {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode)

    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'Memory integrity (HVCI) setting is only supported here on Windows 10/11.'
    }
    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to change memory integrity.'
    }
    Assert-WinUtilMemoryIntegrityIsConfigurable

    $scenario = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\MemoryIntegrityBackup'
    $backup = Get-WinUtilMemoryIntegrityBackup

    if ($Mode -eq 'Disable') {
        $previous = Get-WinUtilMemoryIntegrityRegistryValue -Path $scenario -Name Enabled
        if ($previous.Present -and $previous.Kind -ne 'DWord') {
            throw 'Unexpected HVCI Enabled value type: refusing to overwrite it.'
        }
        if (-not $backup) {
            $backup = [pscustomobject]@{
                Version = 1
                HadEnabled = [bool]$previous.Present
                Kind = if ($previous.Present) { 'DWord' } else { '' }
                EnabledValue = if ($previous.Present) { [int]$previous.Value } else { $null }
            }
            # Save the original value (or absence) BEFORE writing Enabled=0.
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -PropertyType String -Value ($backup | ConvertTo-Json -Depth 4 -Compress) -Force -ErrorAction Stop
        }
        $null = New-Item -Path $scenario -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $scenario -Name Enabled -PropertyType DWord -Value 0 -Force -ErrorAction Stop
        $after = Get-WinUtilMemoryIntegrityRegistryValue -Path $scenario -Name Enabled
        if (-not $after.Present -or $after.Kind -ne 'DWord' -or [int]$after.Value -ne 0) {
            throw 'HVCI Enabled=0 could not be verified. Original settings remain backed up.'
        }
        Write-WinUtilLog -Component 'MemoryIntegrity' -Message 'Memory integrity Enabled=0 saved. Restart Windows to request HVCI disable. VBS and other policies unchanged.'
        return
    }

    if (-not $backup) {
        throw 'No APBOptimizer HVCI backup exists. Refusing to guess the previous protection state.'
    }
    if ($backup.HadEnabled) {
        $null = New-Item -Path $scenario -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $scenario -Name Enabled -PropertyType DWord -Value ([int]$backup.EnabledValue) -Force -ErrorAction Stop
    } else {
        $now = Get-WinUtilMemoryIntegrityRegistryValue -Path $scenario -Name Enabled
        if ($now.Present) {
            Remove-ItemProperty -LiteralPath $scenario -Name Enabled -ErrorAction Stop
        }
    }
    $after = Get-WinUtilMemoryIntegrityRegistryValue -Path $scenario -Name Enabled
    if ($backup.HadEnabled) {
        if (-not $after.Present -or $after.Kind -ne 'DWord' -or
            [int]$after.Value -ne [int]$backup.EnabledValue) {
            throw 'Could not verify original HVCI state after Restore. Backup retained.'
        }
    } elseif ($after.Present) {
        throw 'Could not remove the originally absent HVCI Enabled value. Backup retained.'
    }
    Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
    Write-WinUtilLog -Component 'MemoryIntegrity' -Message 'Original HVCI Enabled registry state restored. Restart Windows; other VBS settings unchanged.'
}
