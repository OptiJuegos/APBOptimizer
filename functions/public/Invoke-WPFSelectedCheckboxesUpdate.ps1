function Invoke-WPFSelectedCheckboxesUpdate ($type, $checkboxName) {
    $listName = switch -Regex ($checkboxName) {
        '^WPFTweaks'  { 'selectedTweaks' }
        '^WPFToggle'  { 'selectedToggles' }
    }
    if (-not $listName) { return }
    if ($type -eq "Add") {
        if (-not $sync.$listName.Contains($checkboxName)) {
            $sync.$listName.Add($checkboxName)
        }
    } else {
        [void]$sync.$listName.Remove($checkboxName)
    }
}
