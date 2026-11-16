function Invoke-WPFGetInstalled {
    param([string]$CheckBox)

    if ($CheckBox -ne 'tweaks') { return }

    Start-WinUtilJob -Name 'Detect applied tweaks' -Description 'Checking applied tweaks' -ScriptBlock {
        Step-WinUtilJob -Status 'Checking applied tweaks' -State 'Indeterminate'
        $found = @(Invoke-WinUtilCurrentSystem -CheckBox 'tweaks')
        Write-WinUtilLog -Component 'Tweaks' -Message "Detected $($found.Count) applied tweak(s)."
        Invoke-WPFUIThread -Parameters @{ Found = $found } -ScriptBlock {
            param($Found)
            foreach ($name in $Found) {
                if ($null -ne $sync.$name) {
                    $sync.$name.IsChecked = $true
                }
            }
        }
    }
}
