function Get-WinUtilStartupValue {
    param([string]$Path, [string]$Name)
    $absent = [pscustomobject]@{ Exists = $false; Kind = ''; Data = $null }
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return $absent }
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($Name -notin $key.GetValueNames()) { return $absent }
    $kind = $key.GetValueKind($Name).ToString()
    $data = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($kind -eq 'Binary') { $data = [Convert]::ToBase64String([byte[]]$data) }
    return [pscustomobject]@{ Exists = $true; Kind = $kind; Data = $data }
}

function Set-WinUtilStartupValue {
    param([string]$Path, [string]$Name, $Value)
    if (-not $Value.Exists) {
        if ((Get-WinUtilStartupValue -Path $Path -Name $Name).Exists) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        }
        return
    }
    if ($Value.Kind -notin @('Binary', 'DWord', 'String')) { throw 'Unsupported startup registry type.' }
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { $null = New-Item -Path $Path -Force -ErrorAction Stop }
    $data = $Value.Data
    if ($Value.Kind -eq 'Binary') { $data = [Convert]::FromBase64String([string]$Value.Data) }
    $null = New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Value.Kind -Value $data -Force -ErrorAction Stop
}

function Test-WinUtilStartupValueEqual {
    param($Left, $Right)
    return ($Left.Exists -eq $Right.Exists -and (-not $Left.Exists -or
        ($Left.Kind -eq $Right.Kind -and [string]$Left.Data -ceq [string]$Right.Data)))
}

function Get-WinUtilStartupId {
    param($Entry)
    $identity = "$($Entry.Kind)|$($Entry.Source)|$($Entry.Key)".ToLowerInvariant()
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-WinUtilStartupExecutable {
    param([string]$Command)
    $expanded = [Environment]::ExpandEnvironmentVariables($Command).Trim()
    if ($expanded -match '^"([^"]+)"') { return $matches[1] }
    if ($expanded -match '^(.+?\.(?:exe|com|bat|cmd))(?=\s|$)') { return $matches[1] }
    return ''
}

function Get-WinUtilStartupRawEntries {
    # Task Manager's normal startup sources only: no RunOnce, services or logon tasks.
    foreach ($hive in @('HKCU', 'HKLM')) {
        foreach ($view in @('Run', 'Run32')) {
            $run = if ($view -eq 'Run32') { "${hive}:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" }
                else { "${hive}:\Software\Microsoft\Windows\CurrentVersion\Run" }
            try {
                if (-not (Test-Path -LiteralPath $run -ErrorAction Stop)) { continue }
                $key = Get-Item -LiteralPath $run -ErrorAction Stop
                foreach ($name in $key.GetValueNames()) {
                    if (-not $name -or $key.GetValueKind($name).ToString() -notin @('String', 'ExpandString')) { continue }
                    $command = [string]$key.GetValue($name, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    [pscustomobject]@{
                        Kind = 'Run'; Source = $run; Key = $name; Name = $name; Publisher = ''
                        Command = $command; Identity = $command; IconPath = Get-WinUtilStartupExecutable $command
                        StatePath = "${hive}:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$view"
                        StateName = $name; DefaultEnabled = $true
                        Scope = $(if ($hive -eq 'HKCU') { 'Usuario' } else { 'Todos los usuarios' })
                    }
                }
            } catch { $script:WinUtilStartupReadIncomplete = $true; Write-WinUtilLog -Component 'StartupApps' -Level 'WARN' -Message "Cannot read startup source ${run}: $($_.Exception.Message)" }
        }
    }
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($folderKind in @('Startup', 'CommonStartup')) {
            $folder = [Environment]::GetFolderPath($folderKind)
            if (-not $folder -or -not (Test-Path -LiteralPath $folder -ErrorAction Stop)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction Stop)) {
                $command = $file.FullName
                if ($file.Extension -eq '.lnk') {
                    $shortcut = $shell.CreateShortcut($file.FullName)
                    try { $command = '"' + $shortcut.TargetPath + '" ' + $shortcut.Arguments }
                    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }
                }
                $hive = if ($folderKind -eq 'Startup') { 'HKCU' } else { 'HKLM' }
                [pscustomobject]@{
                    Kind = 'Folder'; Source = $file.FullName; Key = $file.Name; Name = $file.BaseName; Publisher = ''
                    Command = $command; Identity = "$command|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)"
                    IconPath = Get-WinUtilStartupExecutable $command
                    StatePath = "${hive}:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
                    StateName = $file.Name; DefaultEnabled = $true
                    Scope = $(if ($hive -eq 'HKCU') { 'Usuario' } else { 'Todos los usuarios' })
                }
            }
        }
    } catch { $script:WinUtilStartupReadIncomplete = $true; Write-WinUtilLog -Component 'StartupApps' -Level 'WARN' -Message "Cannot read startup shortcuts: $($_.Exception.Message)" }
    finally { if ($shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } }

    $appNames = @{}
    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        try { Get-StartApps -ErrorAction Stop | ForEach-Object { $appNames[$_.AppID] = $_.Name } } catch { }
    }
    try { $packages = @(Get-AppxPackage -ErrorAction Stop) }
    catch { $script:WinUtilStartupReadIncomplete = $true; Write-WinUtilLog -Component 'StartupApps' -Level 'WARN' -Message "Cannot read packaged startup apps: $($_.Exception.Message)"; return }
    foreach ($package in $packages) {
        try {
            $manifestPath = Join-Path $package.InstallLocation 'AppxManifest.xml'
            if (-not (Test-Path -LiteralPath $manifestPath -ErrorAction Stop)) { continue }
            [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop
            foreach ($extension in $manifest.SelectNodes("//*[local-name()='Extension' and @Category='windows.startupTask']")) {
                $application = $extension.SelectSingleNode("ancestor::*[local-name()='Application'][1]")
                foreach ($task in $extension.SelectNodes(".//*[local-name()='StartupTask']")) {
                    $taskId = [string]$task.TaskId
                    # These identifiers become registry path components, never accept separators.
                    if (-not $taskId -or $taskId -in @('.', '..') -or $taskId -match '[\\/]' -or $package.PackageFamilyName -match '[\\/]') { continue }
                    $appId = "$($package.PackageFamilyName)!$($application.Id)"
                    $name = [string]$task.DisplayName
                    if (-not $name -or $name -like 'ms-resource:*') { $name = [string]$appNames[$appId] }
                    if (-not $name) { $name = [string]$package.Name }
                    $executable = if ($extension.Executable) { [string]$extension.Executable } else { [string]$application.Executable }
                    $command = if ($executable) { Join-Path $package.InstallLocation $executable } else { '' }
                    $visual = $application.SelectSingleNode("./*[local-name()='VisualElements']")
                    $logo = if ($visual) { [string]$visual.Square44x44Logo } else { '' }
                    $icon = $command
                    if ($logo) {
                        $logoPath = Join-Path $package.InstallLocation $logo
                        if (Test-Path -LiteralPath $logoPath) { $icon = $logoPath }
                        else {
                            $variant = Get-ChildItem -LiteralPath (Split-Path $logoPath -Parent) -Filter (([IO.Path]::GetFileNameWithoutExtension($logoPath)) + '.*.png') -File -ErrorAction SilentlyContinue | Select-Object -First 1
                            if ($variant) { $icon = $variant.FullName }
                        }
                    }
                    [pscustomobject]@{
                        Kind = 'Package'; Source = [string]$package.PackageFamilyName; Key = $taskId; Name = $name
                        Publisher = [string]$manifest.Package.Properties.PublisherDisplayName
                        Command = $command; Identity = "$($package.PackageFullName)|$($application.Id)|$taskId|$executable"; IconPath = $icon
                        StatePath = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\$($package.PackageFamilyName)\$taskId"
                        StateName = 'State'; DefaultEnabled = ([string]$task.Enabled -eq 'true'); Scope = 'Usuario'
                    }
                }
            }
        } catch { $script:WinUtilStartupReadIncomplete = $true; Write-WinUtilLog -Component 'StartupApps' -Level 'WARN' -Message "Cannot inspect startup tasks for $($package.Name): $($_.Exception.Message)" }
    }
}

function Test-WinUtilStartupPolicy {
    param($Entry)
    if ($Entry.Kind -ne 'Package') { return $false }
    foreach ($hive in @('HKCU', 'HKLM')) {
        $path = "${hive}:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        foreach ($name in @('EnableFullTrustStartupTasks', 'EnableUwpStartupTasks', 'SupportFullTrustStartupTasks', 'SupportUwpStartupTasks')) {
            $value = Get-WinUtilStartupValue -Path $path -Name $name
            $expected = if ($name -like 'Enable*') { 2 } else { 1 }
            if ($value.Exists -and ($value.Kind -ne 'DWord' -or $value.Data -ne $expected)) { return $true }
        }
    }
    return $false
}

function Get-WinUtilStartupIcon {
    param([string]$Path)
    Add-Type -AssemblyName PresentationCore, System.Drawing
    try {
        if ($Path -and -not $Path.StartsWith('\\') -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            if ([IO.Path]::GetExtension($Path) -in @('.png', '.ico', '.jpg', '.bmp')) {
                $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
                $bitmap.BeginInit(); $bitmap.CacheOption = 'OnLoad'; $bitmap.UriSource = [uri]$Path; $bitmap.DecodePixelWidth = 32; $bitmap.EndInit(); $bitmap.Freeze()
                return $bitmap
            }
            $icon = [Drawing.Icon]::ExtractAssociatedIcon($Path)
        }
        if (-not $icon) { $icon = [Drawing.SystemIcons]::Application.Clone() }
        try {
            $bitmap = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($icon.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            $bitmap.Freeze()
            return $bitmap
        } finally { $icon.Dispose() }
    } catch {
        # A missing/corrupt application icon must not hide the startup entry.
        $drawing = [Windows.Media.GeometryDrawing]::new([Windows.Media.Brushes]::SlateGray, $null, [Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0,0,24,24)))
        $fallback = [Windows.Media.DrawingImage]::new($drawing); $fallback.Freeze(); return $fallback
    }
}

function Get-WinUtilStartupEntries {
    param([switch]$NoIcons)
    $script:WinUtilStartupReadIncomplete = $false
    $seen = @{}
    foreach ($raw in @(Get-WinUtilStartupRawEntries)) {
        $id = Get-WinUtilStartupId $raw
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $entry = $raw.PSObject.Copy()
        $value = $null; $enabled = $false; $known = $true; $policy = $false
        try {
            $value = Get-WinUtilStartupValue -Path $raw.StatePath -Name $raw.StateName
            if ($raw.Kind -eq 'Package') {
                # Manifest Enabled=true alone does not prove first-launch/user consent.
                $state = if ($value.Exists -and $value.Kind -eq 'DWord') { [int]$value.Data } elseif (-not $value.Exists -and -not $raw.DefaultEnabled) { 0 } else { -1 }
                $known = $state -in @(0,1,2,3,4)
                $enabled = $state -in @(2,4)
                $policy = $state -in @(3,4) -or (Test-WinUtilStartupPolicy $raw)
            } elseif (-not $value.Exists) { $enabled = [bool]$raw.DefaultEnabled }
            elseif ($value.Kind -eq 'Binary') {
                $bytes = [Convert]::FromBase64String([string]$value.Data)
                $known = $bytes.Length -eq 12 -and $bytes[0] -in @(2,3,6,7) -and $bytes[1] -eq 0 -and $bytes[2] -eq 0 -and $bytes[3] -eq 0
                $enabled = $known -and $bytes[0] -in @(2,6)
            } else { $known = $false }
        } catch { $known = $false }
        $publisher = [string]$raw.Publisher
        if (-not $NoIcons -and $raw.IconPath -and -not $raw.IconPath.StartsWith('\\')) {
            try {
                $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($raw.IconPath)
                if (-not $publisher) { $publisher = $version.CompanyName }
            } catch { }
        }
        $entry | Add-Member -NotePropertyMembers @{
            Id=$id; Enabled=$enabled; Known=$known; PolicyLocked=$policy; CanChange=($known -and -not $policy); CanDisable=($known -and $enabled -and -not $policy)
            StateValue=$value; Icon=$(if (-not $NoIcons) { Get-WinUtilStartupIcon $raw.IconPath } else { $null })
            DisplayPublisher=$(if ($publisher -notlike 'ms-resource:*') { $publisher } else { '' })
        }
        $entry
    }
}

function Get-WinUtilStartupBackupIds {
    $path = 'HKCU:\Software\APBOptimizer\StartupBackup'
    if (Test-Path -LiteralPath $path -ErrorAction Stop) { (Get-Item -LiteralPath $path -ErrorAction Stop).GetValueNames() | Where-Object { $_ -match '^[a-f0-9]{64}$' } }
}

function Get-WinUtilStartupBackup {
    param([string]$Id)
    $value = Get-WinUtilStartupValue -Path 'HKCU:\Software\APBOptimizer\StartupBackup' -Name $Id
    if (-not $value.Exists) { return $null }
    if ($value.Kind -ne 'String') { throw 'Invalid startup recovery record type.' }
    $backup = ConvertFrom-Json -InputObject $value.Data -ErrorAction Stop
    if ($backup.Version -ne 1 -or $backup.Id -ne $Id -or -not $backup.Identity -or
        -not $backup.Original -or -not $backup.Applied) { throw 'Invalid startup recovery record.' }
    return $backup
}

function Set-WinUtilStartupEntry {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Enable','Disable','Restore')][string]$Mode,
        [string]$ExpectedIdentity
    )
    # Resolve paths only from a fresh enumeration, never from caller-supplied metadata.
    $entry = @(Get-WinUtilStartupEntries -NoIcons | Where-Object Id -eq $Id) | Select-Object -First 1
    if (-not $entry) { throw 'The startup entry no longer exists. Recovery metadata was retained.' }
    if ($ExpectedIdentity -and $entry.Identity -cne $ExpectedIdentity) { throw 'The startup entry changed since selection. Refresh the list.' }
    if (-not $entry.Known -or $entry.PolicyLocked) { throw 'This startup state is unknown or managed by policy.' }
    $backup = Get-WinUtilStartupBackup -Id $Id
    if ($backup -and ($backup.Identity -cne $entry.Identity -or $backup.StatePath -ne $entry.StatePath -or $backup.StateName -ne $entry.StateName)) {
        throw 'The startup entry changed since backup. Recovery metadata was retained.'
    }
    $backupPath = 'HKCU:\Software\APBOptimizer\StartupBackup'
    # Older journals contain only disables. Opposite requests restore the exact
    # original state, rather than replacing the first recovery snapshot.
    $backupMode = if ($backup -and $backup.Mode) { [string]$backup.Mode } else { 'Disable' }
    if ($backupMode -notin @('Enable','Disable')) { throw 'Invalid startup recovery operation.' }
    $restore = $Mode -eq 'Restore' -or ($backup -and $Mode -ne $backupMode)
    if (-not $restore) {
        $enable = $Mode -eq 'Enable'
        if (-not $backup -and $entry.Enabled -eq $enable) {
            Write-WinUtilLog -Component 'StartupApps' -Message "Startup entry '$($entry.Name)' already matches $Mode; left unchanged."
            return
        }
        if (-not $backup) {
            $applied = if ($entry.Kind -eq 'Package') { [pscustomobject]@{ Exists=$true; Kind='DWord'; Data=$(if ($enable) { 2 } else { 1 }) } } else {
                $bytes = [byte[]]::new(12)
                if ($enable) { $bytes[0] = 2 } else {
                    $bytes[0] = 3
                    [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()).CopyTo($bytes,4)
                }
                [pscustomobject]@{ Exists=$true; Kind='Binary'; Data=[Convert]::ToBase64String($bytes) }
            }
            $backup = [pscustomobject]@{ Version=1; Mode=$Mode; Id=$Id; Name=$entry.Name; Identity=$entry.Identity; StatePath=$entry.StatePath; StateName=$entry.StateName; Original=$entry.StateValue; Applied=$applied }
            if ($enable -and $entry.Kind -eq 'Package') {
                $consent = Get-WinUtilStartupValue -Path $entry.StatePath -Name 'UserEnabledStartupOnce'
                if ($consent.Exists -and $consent.Kind -ne 'DWord') { throw 'Unknown packaged startup consent state; no changes made.' }
                $backup | Add-Member -NotePropertyMembers @{
                    OriginalConsent=$consent; AppliedConsent=[pscustomobject]@{ Exists=$true; Kind='DWord'; Data=1 }
                }
            }
            $serialized = $backup | ConvertTo-Json -Depth 6 -Compress
            Set-WinUtilStartupValue -Path $backupPath -Name $Id -Value ([pscustomobject]@{ Exists=$true; Kind='String'; Data=$serialized })
            if ((Get-WinUtilStartupValue -Path $backupPath -Name $Id).Data -cne $serialized) { throw 'Startup backup could not be verified; no startup changes made.' }
        }
        $target = $backup.Applied
    } else {
        if (-not $backup) { throw 'No APBOptimizer startup backup exists for this entry.' }
        $target = $backup.Original
    }
    if (-not (Test-WinUtilStartupValueEqual $entry.StateValue $backup.Applied) -and
        -not (Test-WinUtilStartupValueEqual $entry.StateValue $backup.Original)) { throw 'Startup state changed externally; recovery backup retained.' }
    $targetConsent = $null
    if ($backup.PSObject.Properties['OriginalConsent']) {
        if ($entry.Kind -ne 'Package' -or -not $backup.AppliedConsent) { throw 'Invalid startup consent recovery record.' }
        $currentConsent = Get-WinUtilStartupValue -Path $entry.StatePath -Name 'UserEnabledStartupOnce'
        if (-not (Test-WinUtilStartupValueEqual $currentConsent $backup.OriginalConsent) -and
            -not (Test-WinUtilStartupValueEqual $currentConsent $backup.AppliedConsent)) { throw 'Startup consent changed externally; recovery backup retained.' }
        $targetConsent = if ($restore) { $backup.OriginalConsent } else { $backup.AppliedConsent }
        # Set consent before enabling; restore it after restoring the task state.
        if (-not $restore -and -not (Test-WinUtilStartupValueEqual $currentConsent $targetConsent)) {
            Set-WinUtilStartupValue -Path $entry.StatePath -Name 'UserEnabledStartupOnce' -Value $targetConsent
        }
    }
    if (-not (Test-WinUtilStartupValueEqual $entry.StateValue $target)) { Set-WinUtilStartupValue -Path $entry.StatePath -Name $entry.StateName -Value $target }
    if (-not (Test-WinUtilStartupValueEqual (Get-WinUtilStartupValue -Path $entry.StatePath -Name $entry.StateName) $target)) { throw 'Startup state verification failed; recovery backup retained.' }
    if ($targetConsent) {
        if ($restore -and -not (Test-WinUtilStartupValueEqual $currentConsent $targetConsent)) {
            Set-WinUtilStartupValue -Path $entry.StatePath -Name 'UserEnabledStartupOnce' -Value $targetConsent
        }
        if (-not (Test-WinUtilStartupValueEqual (Get-WinUtilStartupValue -Path $entry.StatePath -Name 'UserEnabledStartupOnce') $targetConsent)) { throw 'Startup consent verification failed; recovery backup retained.' }
    }
    if ($restore) { Set-WinUtilStartupValue -Path $backupPath -Name $Id -Value ([pscustomobject]@{ Exists=$false; Kind=''; Data=$null }) }
    Write-WinUtilLog -Component 'StartupApps' -Message "$Mode startup entry '$($entry.Name)' verified. Running applications were not stopped."
}

function Invoke-WinUtilStartupChanges {
    param([object[]]$Changes, [ValidateSet('Enable','Disable','Restore')][string]$Mode)
    foreach ($change in @($Changes)) {
        $operation = if ($Mode) { $Mode } elseif ($change.Mode) { [string]$change.Mode } else { 'Disable' }
        try {
            Set-WinUtilStartupEntry -Id $change.Id -Mode $operation -ExpectedIdentity $change.Identity
            $sync.StartupAppsCacheLoaded = $false
            if ($sync.PendingStartupChanges -and $sync.PendingStartupChanges.ContainsKey($change.Id) -and
                $sync.PendingStartupChanges[$change.Id].Identity -ceq $change.Identity -and
                ($operation -eq 'Restore' -or $sync.PendingStartupChanges[$change.Id].Mode -eq $change.Mode)) { $sync.PendingStartupChanges.Remove($change.Id) }
        } catch { Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'StartupApps' -Context "$operation $($change.Name)" }
    }
}
