function Get-WinUtilDevicePowerSettingList {
    # Only the plugged-in (AC) index is changed; battery behavior stays as configured.
    @(
        [pscustomobject]@{ Name = 'USB selective suspend'; Subgroup = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Max = 1 }
        [pscustomobject]@{ Name = 'PCI Express Link State Power Management'; Subgroup = '501a4d13-42af-4429-9fd1-a8218c268e20'; Setting = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; Max = 2 }
    )
}

function Invoke-WinUtilPowerCfg {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = @(powercfg @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg $($Arguments -join ' ') failed: $($output -join ' ')"
    }
    return $output
}

function Get-WinUtilActivePowerScheme {
    $output = Invoke-WinUtilPowerCfg -Arguments @('/getactivescheme')
    $match = [regex]::Match(($output -join ' '), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if (-not $match.Success) { throw 'Could not find the active power plan GUID.' }
    return $match.Value.ToLowerInvariant()
}

function Get-WinUtilPowerSettingAcValue {
    param([Parameter(Mandatory)][string]$Scheme, [Parameter(Mandatory)]$Setting)

    $output = Invoke-WinUtilPowerCfg -Arguments @('/query', $Scheme, $Setting.Subgroup, $Setting.Setting)
    # Labels are localized; the current AC and DC indexes are the only hex values.
    $values = @($output | ForEach-Object {
        if ([string]$_ -match ':\s*0x([0-9a-fA-F]+)\s*$') { [Convert]::ToInt32($Matches[1], 16) }
    })
    if ($values.Count -ne 2) { throw "$($Setting.Name) is not available in power plan $Scheme." }
    return $values[0]
}

function Get-WinUtilDevicePowerSavingBackup {
    $saved = Get-WinUtilPowerThrottlingRegistryValue -Path 'HKLM:\SOFTWARE\OptiUtil\DevicePowerSavingBackup' -Name Snapshot
    if (-not $saved.Present) { return $null }
    if ($saved.Kind -ne 'String' -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
        throw 'Device power saving backup is empty or has an invalid type. No changes made.'
    }
    $backup = ConvertFrom-Json -InputObject ([string]$saved.Value) -ErrorAction Stop
    $known = @(Get-WinUtilDevicePowerSettingList)
    $entries = @($backup.Settings)
    $valid = $backup.Version -eq 1 -and [string]$backup.Scheme -match '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -and
        $entries.Count -eq $known.Count
    if ($valid) {
        foreach ($entry in $entries) {
            $setting = $known | Where-Object { $_.Setting -eq $entry.Setting }
            if (-not $setting -or [string]$entry.AC -notmatch '^\d+$' -or [int]$entry.AC -gt $setting.Max) { $valid = $false }
        }
    }
    if (-not $valid) { throw 'Unrecognized device power saving backup. No changes made.' }
    return $backup
}

function Set-WinUtilDevicePowerSaving {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode)

    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to change power plan settings.'
    }

    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\DevicePowerSavingBackup'
    $settings = @(Get-WinUtilDevicePowerSettingList)
    $backup = Get-WinUtilDevicePowerSavingBackup
    if ($Mode -eq 'Disable') {
        $scheme = Get-WinUtilActivePowerScheme
        if ($backup -and $backup.Scheme -ne $scheme) {
            throw "Device power saving was already changed in power plan $($backup.Scheme). Undo it before applying to another plan."
        }
        if (-not $backup) {
            $backup = [pscustomobject]@{
                Version = 1
                Scheme = $scheme
                Settings = @($settings | ForEach-Object {
                    [pscustomobject]@{ Setting = $_.Setting; AC = [int](Get-WinUtilPowerSettingAcValue -Scheme $scheme -Setting $_) }
                })
            }
            # Save the plan's original AC indexes before modifying Windows.
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -PropertyType String -Value ($backup | ConvertTo-Json -Depth 4 -Compress) -Force -ErrorAction Stop
        }
        foreach ($setting in $settings) {
            $null = Invoke-WinUtilPowerCfg -Arguments @('/setacvalueindex', $scheme, $setting.Subgroup, $setting.Setting, '0')
        }
        $null = Invoke-WinUtilPowerCfg -Arguments @('/setactive', $scheme)
        foreach ($setting in $settings) {
            if ((Get-WinUtilPowerSettingAcValue -Scheme $scheme -Setting $setting) -ne 0) {
                throw "Could not verify that $($setting.Name) is off; original values backed up for recovery."
            }
        }
        Write-WinUtilLog -Component 'DevicePowerSaving' -Message "USB selective suspend and PCIe link state power management turned off (AC) in power plan $scheme."
        return
    }

    if (-not $backup) {
        throw 'No device power saving backup exists. Refusing to guess the original power plan settings.'
    }
    $schemes = (Invoke-WinUtilPowerCfg -Arguments @('/list')) -join ' '
    if ($schemes -notmatch [regex]::Escape($backup.Scheme)) {
        # The plan was deleted together with its settings; nothing is left to restore.
        Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
        Write-WinUtilLog -Component 'DevicePowerSaving' -Level 'WARN' -Message "Power plan $($backup.Scheme) no longer exists; device power saving backup discarded."
        return
    }
    foreach ($entry in @($backup.Settings)) {
        $setting = $settings | Where-Object { $_.Setting -eq $entry.Setting }
        $null = Invoke-WinUtilPowerCfg -Arguments @('/setacvalueindex', $backup.Scheme, $setting.Subgroup, $setting.Setting, [string][int]$entry.AC)
    }
    if ((Get-WinUtilActivePowerScheme) -eq $backup.Scheme) {
        $null = Invoke-WinUtilPowerCfg -Arguments @('/setactive', $backup.Scheme)
    }
    foreach ($entry in @($backup.Settings)) {
        $setting = $settings | Where-Object { $_.Setting -eq $entry.Setting }
        if ((Get-WinUtilPowerSettingAcValue -Scheme $backup.Scheme -Setting $setting) -ne [int]$entry.AC) {
            throw "Original $($setting.Name) value could not be verified; backup retained."
        }
    }
    Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
    Write-WinUtilLog -Component 'DevicePowerSaving' -Message "Original USB selective suspend and PCIe link state values restored in power plan $($backup.Scheme)."
}
