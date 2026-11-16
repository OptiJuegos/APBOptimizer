function Get-WinUtilWindowsUpdateFiles {
    # Sysnative is required when a 32-bit PowerShell process runs on 64-bit Windows.
    $systemFolder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        Join-Path $env:SystemRoot 'Sysnative'
    } else {
        Join-Path $env:SystemRoot 'System32'
    }

    foreach ($name in @('WaaSMedicSvc', 'wuaueng')) {
        [pscustomobject]@{
            Name = $name
            OriginalPath = Join-Path $systemFolder "$name.dll"
            RenamedPath = Join-Path $systemFolder "${name}_BAK.dll"
        }
    }
}

function Grant-WinUtilWindowsUpdateFileAccess {
    param([Parameter(Mandatory)][string]$Path)

    # Grant access only to the built-in Administrators group, not Everyone as in
    # the original BAT. Each file's original ACL is saved before this operation.
    $result = & takeown.exe /F $Path /A 2>&1
    if ($LASTEXITCODE -ne 0) { throw "takeown.exe failed for $Path ($LASTEXITCODE): $result" }
    $result = & icacls.exe $Path /grant '*S-1-5-32-544:F' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls.exe failed for $Path ($LASTEXITCODE): $result" }
}

function Restore-WinUtilWindowsUpdateFileSecurity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SecurityDescriptor
    )

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetSecurityDescriptorSddlForm($SecurityDescriptor)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Get-WinUtilWindowsUpdateFileSnapshot {
    $files = @()
    foreach ($file in @(Get-WinUtilWindowsUpdateFiles)) {
        $present = Test-Path -LiteralPath $file.OriginalPath
        $alreadyRenamed = Test-Path -LiteralPath $file.RenamedPath
        $descriptor = if ($present) { (Get-Acl -LiteralPath $file.OriginalPath -ErrorAction Stop).Sddl } else { $null }
        if ($present -and [string]::IsNullOrWhiteSpace($descriptor)) {
            throw "Could not back up the security descriptor of $($file.OriginalPath). No Windows files were changed."
        }
        $files += [pscustomobject]@{
            Name = $file.Name
            OriginalExisted = [bool]$present
            RenamedExisted = [bool]$alreadyRenamed
            SecurityDescriptor = $descriptor
        }
    }
    return $files
}

function Rename-WinUtilWindowsUpdateFiles {
    param([Parameter(Mandatory)]$Snapshot)

    $paths = @(Get-WinUtilWindowsUpdateFiles)
    foreach ($entry in @($Snapshot.Files)) {
        $file = $paths | Where-Object { $_.Name -eq $entry.Name } | Select-Object -First 1
        if ($null -eq $file) { Write-Warning "Unknown Windows Update file in snapshot: $($entry.Name)"; continue }
        if (-not $entry.OriginalExisted -or $entry.RenamedExisted) {
            Write-Warning "Skipping $($entry.Name).dll: the original file was missing or the _BAK file already existed before APBOptimizer."
            continue
        }
        if (-not (Test-Path -LiteralPath $file.OriginalPath)) {
            if (Test-Path -LiteralPath $file.RenamedPath) { continue } # Already renamed by an earlier attempt.
            Write-Warning "Neither original nor backup exists for $($entry.Name).dll."
            continue
        }
        if (Test-Path -LiteralPath $file.RenamedPath) {
            Write-Warning "Cannot rename $($entry.Name).dll because the _BAK name already exists."
            continue
        }

        try {
            Grant-WinUtilWindowsUpdateFileAccess -Path $file.OriginalPath
            Rename-Item -LiteralPath $file.OriginalPath -NewName (Split-Path $file.RenamedPath -Leaf) -ErrorAction Stop
            Write-WinUtilLog -Component 'WindowsUpdate' -Message "Renamed $($entry.Name).dll to $($entry.Name)_BAK.dll."
        } catch {
            Write-Warning "Could not rename protected Windows Update file $($entry.Name).dll: $($_.Exception.Message)"
        } finally {
            # Restore the original owner/DACL even if the rename failed midway.
            $actualPath = if (Test-Path -LiteralPath $file.RenamedPath) { $file.RenamedPath }
                          elseif (Test-Path -LiteralPath $file.OriginalPath) { $file.OriginalPath }
                          else { $null }
            if ($actualPath) {
                try { Restore-WinUtilWindowsUpdateFileSecurity -Path $actualPath -SecurityDescriptor $entry.SecurityDescriptor }
                catch { Write-Warning "Could not restore original permissions of $($entry.Name).dll: $($_.Exception.Message)" }
            }
        }
    }
}

function Restore-WinUtilWindowsUpdateFiles {
    param([Parameter(Mandatory)]$Snapshot)

    $failed = $false
    $paths = @(Get-WinUtilWindowsUpdateFiles)
    foreach ($entry in @($Snapshot.Files)) {
        # Do not claim or restore a DLL that was already renamed by another tool.
        if (-not $entry.OriginalExisted -or $entry.RenamedExisted) { continue }
        $file = $paths | Where-Object { $_.Name -eq $entry.Name } | Select-Object -First 1
        if ($null -eq $file) { $failed = $true; continue }
        $originalExists = Test-Path -LiteralPath $file.OriginalPath
        $renamedExists = Test-Path -LiteralPath $file.RenamedPath
        if ($originalExists -and -not $renamedExists) {
            # A prior restore may have renamed the file back but failed before
            # recovering its owner/ACL. Do not discard the snapshot prematurely.
            try {
                $currentSddl = (Get-Acl -LiteralPath $file.OriginalPath -ErrorAction Stop).Sddl
                if ($currentSddl -ne $entry.SecurityDescriptor) {
                    Grant-WinUtilWindowsUpdateFileAccess -Path $file.OriginalPath
                    Restore-WinUtilWindowsUpdateFileSecurity -Path $file.OriginalPath -SecurityDescriptor $entry.SecurityDescriptor
                }
            } catch {
                $failed = $true
                Write-Warning "Could not recover permissions of $($entry.Name).dll: $($_.Exception.Message)"
            }
            continue
        }
        if ($originalExists -or -not $renamedExists) {
            $failed = $true
            Write-Warning "Cannot restore $($entry.Name).dll: conflicting or missing original/_BAK files."
            continue
        }
        try {
            Grant-WinUtilWindowsUpdateFileAccess -Path $file.RenamedPath
            Rename-Item -LiteralPath $file.RenamedPath -NewName (Split-Path $file.OriginalPath -Leaf) -ErrorAction Stop
            Restore-WinUtilWindowsUpdateFileSecurity -Path $file.OriginalPath -SecurityDescriptor $entry.SecurityDescriptor
            Write-WinUtilLog -Component 'WindowsUpdate' -Message "Restored $($entry.Name).dll and its original permissions."
        } catch {
            $failed = $true
            Write-Warning "Could not restore $($entry.Name).dll: $($_.Exception.Message)"
        }
    }
    return (-not $failed)
}
