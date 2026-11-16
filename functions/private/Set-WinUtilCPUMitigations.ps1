function Get-WinUtilCPUMitigationsRegistryValue {
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

function Get-WinUtilCPUMitigationsBackup {
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\CPUMitigationsBackup'
    $saved = Get-WinUtilCPUMitigationsRegistryValue -Path $backupPath -Name Snapshot
    if (-not $saved.Present) { return $null }
    if ($saved.Kind -ne 'String' -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
        throw 'CPU mitigations backup is unreadable. No changes made.'
    }
    try {
        $backup = ConvertFrom-Json -InputObject ([string]$saved.Value) -ErrorAction Stop
        if ($backup.Version -ne 1 -or $null -eq $backup.Values -or
            @($backup.Values.PSObject.Properties).Count -ne 2) {
            throw 'Unexpected backup schema.'
        }
        foreach ($name in @('FeatureSettingsOverride', 'FeatureSettingsOverrideMask')) {
            $entry = $backup.Values.PSObject.Properties[$name]
            if ($null -eq $entry -or $entry.Value.Present -isnot [bool]) {
                throw "Missing saved state for $name."
            }
            if ($entry.Value.Present -and ($entry.Value.Kind -ne 'DWord' -or
                $null -eq $entry.Value.Value -or [string]$entry.Value.Value -notmatch '^-?\d+$' -or
                [long]$entry.Value.Value -gt [int]::MaxValue -or
                [long]$entry.Value.Value -lt [int]::MinValue)) {
                throw "Invalid saved DWORD for $name."
            }
        }
        return $backup
    } catch {
        throw "Invalid CPU mitigations backup; original values cannot be safely restored: $($_.Exception.Message)"
    }
}

function Set-WinUtilCPUMitigations {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode)

    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'This CPU mitigation setting requires Windows 10 or Windows 11.'
    }
    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to configure CPU mitigations.'
    }
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\CPUMitigationsBackup'
    $names = @('FeatureSettingsOverride', 'FeatureSettingsOverrideMask')
    $backup = Get-WinUtilCPUMitigationsBackup

    if ($Mode -eq 'Disable') {
        $values = [ordered]@{}
        foreach ($name in $names) {
            $previous = Get-WinUtilCPUMitigationsRegistryValue -Path $path -Name $name
            if ($previous.Present -and $previous.Kind -ne 'DWord') {
                throw "Unexpected registry type for $name; refusing to overwrite it."
            }
            $values[$name] = @{
                Present = [bool]$previous.Present
                Kind = if ($previous.Present) { 'DWord' } else { '' }
                Value = if ($previous.Present) { [int]$previous.Value } else { $null }
            }
        }
        if (-not $backup) {
            $backup = @{ Version = 1; Values = $values }
            # Persist both original DWORDs (including absence) before writing either value.
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -PropertyType String -Value ($backup | ConvertTo-Json -Depth 5 -Compress) -Force -ErrorAction Stop
        }
        $null = New-Item -Path $path -Force -ErrorAction Stop
        foreach ($name in $names) {
            $null = New-ItemProperty -LiteralPath $path -Name $name -PropertyType DWord -Value 3 -Force -ErrorAction Stop
        }
        foreach ($name in $names) {
            $actual = Get-WinUtilCPUMitigationsRegistryValue -Path $path -Name $name
            if (-not $actual.Present -or $actual.Kind -ne 'DWord' -or [int]$actual.Value -ne 3) {
                throw "Cannot verify $name=3; original settings are still backed up."
            }
        }
        Write-WinUtilLog -Component 'CPUMitigations' -Message 'CPU speculative-execution mitigations override set to 3/3. Windows restart required; security protection is reduced.'
        return
    }

    if (-not $backup) {
        throw 'No APBOptimizer CPU mitigation backup exists. Refusing to guess the original protection settings.'
    }
    foreach ($name in $names) {
        $previous = $backup.Values.PSObject.Properties[$name].Value
        if ($previous.Present) {
            $null = New-Item -Path $path -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $path -Name $name -PropertyType DWord -Value ([int]$previous.Value) -Force -ErrorAction Stop
        } else {
            $current = Get-WinUtilCPUMitigationsRegistryValue -Path $path -Name $name
            if ($current.Present) {
                Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop
            }
        }
    }
    foreach ($name in $names) {
        $previous = $backup.Values.PSObject.Properties[$name].Value
        $actual = Get-WinUtilCPUMitigationsRegistryValue -Path $path -Name $name
        if ($previous.Present) {
            if (-not $actual.Present -or $actual.Kind -ne 'DWord' -or [int]$actual.Value -ne [int]$previous.Value) {
                throw "Could not verify restoration of $name; backup retained."
            }
        } elseif ($actual.Present) {
            throw "Could not remove originally absent $name; backup retained."
        }
    }
    Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
    Write-WinUtilLog -Component 'CPUMitigations' -Message 'Original CPU mitigation registry values restored. Restart Windows for the changes to take effect.'
}
