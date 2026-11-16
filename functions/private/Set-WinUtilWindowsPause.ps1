function Get-WinUtilWindowsPauseNames {
    return @(
        'PauseFeatureUpdatesStartTime',
        'PauseQualityUpdatesStartTime',
        'PauseUpdatesStartTime',
        'PauseUpdatesExpiryTime',
        'PauseFeatureUpdatesEndTime',
        'PauseQualityUpdatesEndTime'
    )
}

function Get-WinUtilWindowsPauseValues {
    $path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    $values = @()
    if ($key) {
        $names = @($key.GetValueNames())
        foreach ($name in @(Get-WinUtilWindowsPauseNames)) {
            if ($name -notin $names) { continue }
            $kind = [string]$key.GetValueKind($name)
            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $values += [pscustomobject]@{ Name = $name; Kind = $kind; Value = $value }
        }
    }
    return @($values)
}

function Get-WinUtilWindowsPauseState {
    $entries = @(Get-WinUtilWindowsPauseValues)
    $expiry = $entries | Where-Object { $_.Name -eq 'PauseUpdatesExpiryTime' -and $_.Kind -eq 'String' } | Select-Object -First 1
    if ($expiry -and $expiry.Value -eq '2099-08-17T20:09:55Z') { return 'Registry2099' }
    if (@($entries | Where-Object { $_.Name -eq 'PauseUpdatesExpiryTime' }).Count -gt 0) { return 'ExistingPause' }
    return 'NoPause'
}

function Set-WinUtilWindowsPause {
    param([Parameter(Mandatory)][ValidateSet('Pause', 'Restore')][string]$Mode)

    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to configure Windows Update pause settings.'
    }

    $path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\WindowsPauseBackup'
    $backup = Get-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction SilentlyContinue
    $snapshot = $null
    if ($backup) {
        if ([string]::IsNullOrWhiteSpace($backup.Snapshot)) { throw 'Windows Update pause backup is empty.' }
        $snapshot = $backup.Snapshot | ConvertFrom-Json -ErrorAction Stop
        if ($snapshot.Version -ne 1) { throw 'Unsupported Windows Update pause backup version.' }
    }

    if ($Mode -eq 'Pause') {
        if (-not $snapshot) {
            $snapshot = [pscustomobject]@{
                Version = 1
                KeyExisted = [bool](Test-Path -LiteralPath $path)
                Values = @(Get-WinUtilWindowsPauseValues)
            }
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $json = $snapshot | ConvertTo-Json -Depth 7 -Compress
            $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -Value $json -PropertyType String -Force -ErrorAction Stop
        }

        $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        $expiry = '2099-08-17T20:09:55Z'
        $startNames = @('PauseFeatureUpdatesStartTime', 'PauseQualityUpdatesStartTime', 'PauseUpdatesStartTime')
        $endNames = @('PauseUpdatesExpiryTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesEndTime')
        $null = New-Item -Path $path -Force -ErrorAction Stop
        foreach ($name in $startNames) {
            $null = New-ItemProperty -LiteralPath $path -Name $name -Value $now -PropertyType String -Force -ErrorAction Stop
        }
        foreach ($name in $endNames) {
            $null = New-ItemProperty -LiteralPath $path -Name $name -Value $expiry -PropertyType String -Force -ErrorAction Stop
        }
        $applied = @(Get-WinUtilWindowsPauseValues)
        foreach ($name in $startNames) {
            if (-not @($applied | Where-Object { $_.Name -eq $name -and $_.Kind -eq 'String' -and $_.Value -eq $now }).Count) {
                throw "Pause registry value $name did not persist; backup kept."
            }
        }
        foreach ($name in $endNames) {
            if (-not @($applied | Where-Object { $_.Name -eq $name -and $_.Kind -eq 'String' -and $_.Value -eq $expiry }).Count) {
                throw "Pause registry value $name did not persist; backup kept."
            }
        }
        Write-WinUtilLog -Component 'WindowsPause' -Message 'Wrote experimental Windows Update pause dates through 2099-08-17. Actual Windows Update enforcement is not guaranteed.'
        return
    }

    if (-not $snapshot) { throw 'No Windows Update pause backup exists; refusing to overwrite unknown registry settings.' }
    $failed = $false
    foreach ($name in @(Get-WinUtilWindowsPauseNames)) {
        try {
            $previous = $snapshot.Values | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($previous) {
                $value = $previous.Value
                switch ($previous.Kind) {
                    'Binary' { $value = [byte[]]@($previous.Value) }
                    'MultiString' { $value = [string[]]@($previous.Value) }
                    'DWord' { $value = [int]$previous.Value }
                    'QWord' { $value = [long]$previous.Value }
                }
                $null = New-Item -Path $path -Force -ErrorAction Stop
                $null = New-ItemProperty -LiteralPath $path -Name $name -Value $value -PropertyType $previous.Kind -Force -ErrorAction Stop
            } else {
                $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                if ($key -and $name -in @($key.GetValueNames())) {
                    Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop
                }
            }
        } catch {
            $failed = $true
            Write-Warning "Could not restore pause value $name`: $($_.Exception.Message)"
        }
    }

    $current = @(Get-WinUtilWindowsPauseValues)
    foreach ($name in @(Get-WinUtilWindowsPauseNames)) {
        $previous = $snapshot.Values | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        $actual = $current | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (($null -eq $previous) -ne ($null -eq $actual) -or ($previous -and $actual -and (
            $previous.Kind -ne $actual.Kind -or
            (ConvertTo-Json -InputObject $previous.Value -Compress -Depth 4) -ne (ConvertTo-Json -InputObject $actual.Value -Compress -Depth 4)
        ))) {
            $failed = $true
            Write-Warning "Pause value $name could not be verified after restoration."
        }
    }
    if ($failed) {
        Write-Warning 'Windows Update pause restoration incomplete. Saved values kept for another attempt.'
    } else {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
        Write-WinUtilLog -Component 'WindowsPause' -Message 'Original Windows Update pause registry values restored.'
    }
}
