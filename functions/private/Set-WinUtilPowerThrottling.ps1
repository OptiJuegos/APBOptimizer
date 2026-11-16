function Get-WinUtilPowerThrottlingRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)

    $result = [pscustomobject]@{ Present = $false; Kind = ''; Value = $null }
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    } catch {
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

function Get-WinUtilPowerThrottlingBackup {
    $saved = Get-WinUtilPowerThrottlingRegistryValue -Path 'HKLM:\SOFTWARE\OptiUtil\PowerThrottlingBackup' -Name Snapshot
    if (-not $saved.Present) { return $null }
    if ($saved.Kind -ne 'String' -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
        throw 'Power Throttling backup is empty or has an invalid type. No changes made.'
    }
    $backup = ConvertFrom-Json -InputObject ([string]$saved.Value) -ErrorAction Stop
    if ($backup.Version -ne 1 -or $backup.HadValue -isnot [bool] -or
        ($backup.HadValue -and ($backup.Kind -ne 'DWord' -or $null -eq $backup.Value -or
            [string]$backup.Value -notmatch '^-?\d+$'))) {
        throw 'Unrecognized Power Throttling backup. No changes made.'
    }
    return $backup
}

function Set-WinUtilPowerThrottling {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode)

    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'Power Throttling control requires Windows 10 or newer.'
    }
    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to configure Power Throttling.'
    }

    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\PowerThrottlingBackup'
    $backup = Get-WinUtilPowerThrottlingBackup
    if ($Mode -eq 'Disable') {
        $previous = Get-WinUtilPowerThrottlingRegistryValue -Path $path -Name PowerThrottlingOff
        if ($previous.Present -and $previous.Kind -ne 'DWord') {
            throw 'Unexpected PowerThrottlingOff registry type: refusing to overwrite it.'
        }
        if (-not $backup) {
            $backup = [pscustomobject]@{
                Version = 1
                HadValue = [bool]$previous.Present
                Kind = if ($previous.Present) { 'DWord' } else { '' }
                Value = if ($previous.Present) { [int]$previous.Value } else { $null }
            }
            # Save the previous DWORD (or absence) before modifying Windows.
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -PropertyType String -Value ($backup | ConvertTo-Json -Depth 4 -Compress) -Force -ErrorAction Stop
        }
        $null = New-Item -Path $path -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $path -Name PowerThrottlingOff -PropertyType DWord -Value 1 -Force -ErrorAction Stop
        $actual = Get-WinUtilPowerThrottlingRegistryValue -Path $path -Name PowerThrottlingOff
        if (-not $actual.Present -or $actual.Kind -ne 'DWord' -or [int]$actual.Value -ne 1) {
            throw 'Could not verify PowerThrottlingOff=1; original value backed up for recovery.'
        }
        Write-WinUtilLog -Component 'PowerThrottling' -Message 'PowerThrottlingOff=1 applied. Power usage/temperature may increase; restart recommended.'
        return
    }

    if (-not $backup) {
        throw 'No Power Throttling backup exists. Refusing to guess the original power settings.'
    }
    if ($backup.HadValue) {
        $null = New-Item -Path $path -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $path -Name PowerThrottlingOff -PropertyType DWord -Value ([int]$backup.Value) -Force -ErrorAction Stop
    } else {
        $current = Get-WinUtilPowerThrottlingRegistryValue -Path $path -Name PowerThrottlingOff
        if ($current.Present) {
            Remove-ItemProperty -LiteralPath $path -Name PowerThrottlingOff -ErrorAction Stop
        }
    }
    $actual = Get-WinUtilPowerThrottlingRegistryValue -Path $path -Name PowerThrottlingOff
    if ($backup.HadValue) {
        if (-not $actual.Present -or $actual.Kind -ne 'DWord' -or [int]$actual.Value -ne [int]$backup.Value) {
            throw 'Original Power Throttling DWORD could not be verified; backup retained.'
        }
    } elseif ($actual.Present) {
        throw 'Originally absent PowerThrottlingOff could not be removed; backup retained.'
    }
    Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
    Write-WinUtilLog -Component 'PowerThrottling' -Message 'Original Power Throttling registry value restored. Restart recommended.'
}
