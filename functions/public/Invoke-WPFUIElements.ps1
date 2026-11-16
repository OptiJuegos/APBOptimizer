function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount,

        # Let the interface answer between batches of entries. Only for content nobody is
        # waiting on: a user who just clicked the tab is better served by finishing at once.
        [switch]$Yield
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")
    $linkFontSizeDescriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty(
        [Windows.Controls.Control]::FontSizeProperty,
        [Windows.Controls.TextBlock]
    )

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object System.Windows.GridLength([double]1, [System.Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]
        $entryLocale = Get-WinUtilLocalizedEntry -Key $entry
        # Children are rendered inside the group's drop-down, never as separate
        # rows at the category level.
        if ($entryInfo.ParentGroup -or $entryInfo.LegacyOnly) { continue }

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Category    = $entryInfo.Category
            Content     = if ($entryLocale -and $null -ne $entryLocale.Content) { $entryLocale.Content } else { $entryInfo.Content }
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = if ($entryLocale -and $null -ne $entryLocale.Description) { $entryLocale.Description } else { $entryInfo.description }
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            LocalizedComboItems = if ($entryLocale) { $entryLocale.ComboItems } else { $null }
            ComboDescriptions = $entryInfo.ComboDescriptions
            LocalizedComboDescriptions = if ($entryLocale) { $entryLocale.ComboDescriptions } else { $null }
            Registry    = $entryInfo.registry
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
            Children    = $entryInfo.Children
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $yieldClock = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create a StackPanel for application content controls
        $stackPanelContainer = New-Object Windows.Controls.StackPanel
        $stackPanelContainer.HorizontalAlignment = 'Stretch'
        $stackPanelContainer.VerticalAlignment = 'Stretch'

        # Check if the target grid (or any ancestor) is already inside a ScrollViewer
        $hasOuterScrollViewer = $false
        $currentElement = $targetGrid
        while ($null -ne $currentElement) {
            if ($currentElement -is [System.Windows.Controls.ScrollViewer] -or $currentElement.GetType().Name -eq "ScrollViewer") {
                $hasOuterScrollViewer = $true
                break
            }
            $currentElement = $currentElement.Parent
        }

        if ($hasOuterScrollViewer) {
            # Add StackPanel directly to DockPanel without nesting a ScrollViewer
            [Windows.Controls.DockPanel]::SetDock($stackPanelContainer, [Windows.Controls.Dock]::Bottom)
            $dockPanelContainer.Children.Add($stackPanelContainer) | Out-Null
        }
        else {
            # Create a ScrollViewer for targets that do not already have an outer ScrollViewer
            $scrollViewer = New-Object Windows.Controls.ScrollViewer
            $scrollViewer.VerticalScrollBarVisibility = "Auto"
            $scrollViewer.HorizontalScrollBarVisibility = "Disabled"
            $scrollViewer.HorizontalAlignment = 'Stretch'
            $scrollViewer.VerticalAlignment = 'Stretch'
            $scrollViewer.Content = $stackPanelContainer

            [Windows.Controls.DockPanel]::SetDock($scrollViewer, [Windows.Controls.Dock]::Bottom)
            $dockPanelContainer.Children.Add($scrollViewer) | Out-Null
        }
        $panelcount++

        # Now proceed with adding category labels and entries to $stackPanelContainer
        $columnAttached = $false
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {

            $label = New-Object Windows.Controls.Label
            $categoryCleanName = $category -replace ".*__", ""
            $label.Content = Get-WinUtilLocalizedCategory -Category $categoryCleanName
            $label.Focusable = $true
            $label.IsTabStop = $true
            [System.Windows.Automation.AutomationProperties]::SetName($label, $categoryCleanName)
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $label.UseLayoutRounding = $true
            $stackPanelContainer.Children.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by type (checkboxes first, then buttons, then comboboxes, notes last) and then alphabetically by Content
            $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                switch ($_.Type) {
                    'Button' { 1 }
                    'Combobox' { 2 }
                    'Note' { 3 }
                    default { 0 }
                }
            }}, Content
            foreach ($entryInfo in $entries) {

                # Constructing a panel's worth of controls in one go holds the interface for
                # hundreds of milliseconds. Draining the queue on a deadline rather than every
                # nth entry keeps the wait bounded whatever the entries cost to build.
                if ($Yield -and $columnAttached -and $yieldClock.ElapsedMilliseconds -ge 75 -and (Test-WinUtilUIAlive)) {
                    $yieldClock.Restart()
                    $frame = New-Object Windows.Threading.DispatcherFrame
                    $null = $sync.Form.Dispatcher.BeginInvoke(
                        [Windows.Threading.DispatcherPriority]::Background,
                        [Windows.Threading.DispatcherOperationCallback]{
                            param($dispatcherFrame)
                            $dispatcherFrame.Continue = $false
                            return $null
                        },
                        $frame)
                    [Windows.Threading.Dispatcher]::PushFrame($frame)
                }

                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    { $_ -in @('ServiceGroup', 'DriverGroup', 'TaskGroup') } {
                        $isDriverGroup = ($entryInfo.Type -eq 'DriverGroup')
                        $isTaskGroup = ($entryInfo.Type -eq 'TaskGroup')
                        # Same small checkboxes as ordinary Advanced Tweaks. A frameless
                        # triangle at the left only expands/collapses the indented list.
                        $groupWrapper = New-Object Windows.Controls.StackPanel
                        # Populate search terms after checking installed services,
                        # so searching for an unavailable service does not show it.
                        # Ordinary entries use only the checkbox's own margins.
                        # Extra wrapper spacing made this row noticeably taller.
                        $groupWrapper.Margin = '0'
                        # A shared grid lets the arrow sit immediately before the
                        # checkmark without shifting that checkmark off the column
                        # used by the other Advanced Tweaks.
                        $header = New-Object Windows.Controls.Grid
                        $header.VerticalAlignment = 'Center'

                        $expand = New-Object Windows.Controls.Button
                        $expand.Name = $entryInfo.Name + 'Expander'
                        $expand.Content = 'Collapsed'
                        $expand.Style = $window.FindResource('ServiceGroupExpanderStyle')
                        $expand.HorizontalAlignment = 'Left'
                        $expand.VerticalAlignment = 'Center'
                        $expand.Margin = '19,-1,0,3'
                        $expand.ToolTip = if ($isTaskGroup) { 'Expand or collapse the scheduled task list' } elseif ($isDriverGroup) { 'Expand or collapse the driver list' } else { 'Expand or collapse the service list' }
                        # The checkbox's outer transparent area overlaps the arrow;
                        # keep the arrow above it so both hit targets work.
                        [Windows.Controls.Panel]::SetZIndex($expand, 1)
                        $header.Children.Add($expand) | Out-Null

                        $master = New-Object Windows.Controls.CheckBox
                        $master.Name = $entryInfo.Name
                        $master.Content = $entryInfo.Content
                        $master.HorizontalAlignment = 'Left'
                        $master.VerticalAlignment = 'Center'
                        # Match the visible square's baseline and the 18px height
                        # of normal Advanced rows without adding bottom padding.
                        $master.Margin = '15,-1,0,1'
                        $master.UseLayoutRounding = $true
                        $master.ToolTip = if ($isTaskGroup) {
                            "Disable or restore all available optional scheduled tasks. $($entryInfo.Description)"
                        } elseif ($isDriverGroup) {
                            "Select eligible drivers; changes run only when you click Apply Tweaks. Review each driver's impact and reboot. $($entryInfo.Description)"
                        } else { "Select services to disable or restore when you click Apply Tweaks. $($entryInfo.Description)" }
                        $master.Tag = @{ Children = [string[]]@($entryInfo.Children); Updating = $false; IsDriverGroup = $isDriverGroup; IsTaskGroup = $isTaskGroup; NoManageableDrivers = $false; AllAlreadyDisabled = $false; UnavailableMessage = '' }
                        [System.Windows.Automation.AutomationProperties]::SetName($master, $entryInfo.Content)
                        $header.Children.Add($master) | Out-Null

                        $groupWrapper.Children.Add($header) | Out-Null

                        $childPanel = New-Object Windows.Controls.StackPanel
                        $childPanel.Margin = '30,1,0,2'
                        $childPanel.Visibility = [Windows.Visibility]::Collapsed
                        $groupWrapper.Children.Add($childPanel) | Out-Null
                        $stackPanelContainer.Children.Add($groupWrapper) | Out-Null
                        $sync[$entryInfo.Name] = $master
                        $sync[$expand.Name] = $expand
                        $sync[$entryInfo.Name + 'Children'] = $childPanel

                        $expand.Tag = $childPanel
                        $expand.Add_Click({
                            $children = $this.Tag
                            $isOpening = ($children.Visibility -ne [Windows.Visibility]::Visible)
                            $children.Visibility = if ($isOpening) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
                            $this.Content = if ($isOpening) { 'Expanded' } else { 'Collapsed' }
                        })

                        # One scheduler read per TaskGroup render. The previous
                        # per-child status + info checks enumerated every Windows
                        # task twenty times and stalled the UI for seconds.
                        $taskSnapshot = @()
                        $taskBackup = $null
                        $taskReadError = $null
                        if ($isTaskGroup) {
                            try {
                                $taskSnapshot = @(Get-WinUtilTelemetryTaskSnapshot)
                                $taskBackup = Get-WinUtilTelemetryTaskBackup
                            } catch {
                                $taskReadError = $_.Exception.Message
                            }
                            if ($null -eq $sync.ToggleStatusCache) {
                                $sync.ToggleStatusCache = @{}
                            }
                        }
                        $driverMissingNames = [System.Collections.Generic.List[string]]::new()
                        $driverAlreadyDisabledNames = [System.Collections.Generic.List[string]]::new()
                        $driverProtectedNames = [System.Collections.Generic.List[string]]::new()
                        foreach ($childKey in @($entryInfo.Children)) {
                            $childConfig = $configHashtable[$childKey]
                            $childLocale = Get-WinUtilLocalizedEntry -Key $childKey
                            if ($null -eq $childConfig -or $childConfig.Type -ne 'Toggle' -or $childConfig.ParentGroup -ne $entryInfo.Name -or
                                ($isDriverGroup -and -not $childConfig.driver.Name) -or ($isTaskGroup -and -not $childConfig.scheduledTask.Name)) {
                                throw "Invalid group child '$childKey' in '$($entryInfo.Name)'."
                            }
                            $childToggle = New-Object Windows.Controls.CheckBox
                            $childToggle.Name = $childKey
                            $childToggle.Content = if ($childLocale -and $childLocale.Content) { $childLocale.Content } else { $childConfig.Content }
                            $childToggle.HorizontalAlignment = 'Left'
                            $childToggle.VerticalAlignment = 'Center'
                            $childToggle.Margin = '0,1,0,1'
                            $childToggle.UseLayoutRounding = $true
                            $childToggle.Tag = @{ Group = $entryInfo.Name; Updating = $false; IsDriverGroup = $isDriverGroup; IsTaskGroup = $isTaskGroup }
                            $childInfo = if ($childLocale -and $childLocale.Description) { $childLocale.Description } else { $childConfig.Description }
                            $childToggle.ToolTip = if ($isTaskGroup) { $childInfo } elseif ($isDriverGroup) { "$childInfo $(if ($sync.Language -eq 'es') { 'Pulsa Aplicar ajustes para realizar cambios. Se requiere reiniciar.' } else { 'Click Apply Tweaks to make changes. A reboot is required.' })" } else {
                                if ($sync.Language -eq 'es') { "$childInfo Los cambios se realizan al pulsar Aplicar ajustes." } else { "$childInfo Changes run when you click Apply Tweaks." }
                            }
                            [System.Windows.Automation.AutomationProperties]::SetName($childToggle, $childConfig.Content)
                            $childPanel.Children.Add($childToggle) | Out-Null
                            $sync[$childKey] = $childToggle

                            if ($isTaskGroup) {
                                if ($taskReadError) {
                                    $childToggle.IsEnabled = $false
                                    $childToggle.ToolTip = "$($childToggle.ToolTip) $taskReadError"
                                } else {
                                    try {
                                        $taskInfo = Get-WinUtilTelemetryTaskInfo -Name $childConfig.scheduledTask.Name -TaskSnapshot $taskSnapshot -Backup $taskBackup
                                        $sync.ToggleStatusCache[$childKey] = [bool]$taskInfo.Disabled
                                        $childToggle.IsChecked = [bool]$taskInfo.Disabled
                                        if ($null -ne $sync.PendingTaskSelections -and
                                            $sync.PendingTaskSelections.ContainsKey($childKey)) {
                                            $childToggle.IsChecked = [bool]$sync.PendingTaskSelections[$childKey]
                                        }
                                        if (-not $taskInfo.Present) {
                                            $childToggle.IsEnabled = $false
                                            $childToggle.Visibility = [Windows.Visibility]::Collapsed
                                        } elseif (-not $taskInfo.CanChange) {
                                            $childToggle.IsEnabled = $false
                                            $childToggle.ToolTip = "$($childToggle.ToolTip) $($taskInfo.Reason)"
                                        }
                                    } catch {
                                        $childToggle.IsEnabled = $false
                                        $childToggle.ToolTip = "$($childToggle.ToolTip) $($_.Exception.Message)"
                                    }
                                }
                            } else {
                                if ($isDriverGroup) {
                                    $driverInfo = Get-WinUtilOptionalDriverInfo -Name $childConfig.driver.Name
                                    $childToggle.IsChecked = [bool]$driverInfo.Disabled
                                } else {
                                    $servicePresent = $true
                                    $serviceDisabled = $true
                                    foreach ($serviceEntry in @($childConfig.service)) {
                                        $serviceInfo = Get-Service -Name $serviceEntry.Name -ErrorAction SilentlyContinue
                                        if ($null -eq $serviceInfo) {
                                            $servicePresent = $false
                                            $serviceDisabled = $false
                                            break
                                        }
                                        if ([string]$serviceInfo.StartType -ne [string]$serviceEntry.StartupType) {
                                            $serviceDisabled = $false
                                        }
                                    }
                                    $childToggle.IsChecked = $serviceDisabled
                                }
                                if ($null -eq $sync.ToggleStatusCache) {
                                    $sync.ToggleStatusCache = @{}
                                }
                                # Store the real initial state once. Subsequent
                                # checkbox events only compare with this cache.
                                $sync.ToggleStatusCache[$childKey] = [bool]$childToggle.IsChecked
                                if ($null -ne $sync.PendingGroupSelections -and
                                    $sync.PendingGroupSelections.ContainsKey($childKey)) {
                                    $childToggle.IsChecked = [bool]$sync.PendingGroupSelections[$childKey]
                                }
                            }
                            if ($isDriverGroup) {
                                if (-not $driverInfo.Present) {
                                    $driverMissingNames.Add($childConfig.driver.Name)
                                    $childToggle.IsEnabled = $false
                                    $childToggle.Visibility = [Windows.Visibility]::Collapsed
                                } elseif (-not $driverInfo.CanChange) {
                                    $reason = $driverInfo.Reason
                                    if ($driverInfo.Disabled -and -not $driverInfo.Managed) {
                                        $driverAlreadyDisabledNames.Add($childConfig.driver.Name)
                                        if ($sync.Language -eq 'es') { $reason = 'Ya estaba desactivado fuera de APBOptimizer; no hay un modo de inicio original guardado para reactivarlo.' }
                                    } else {
                                        $driverProtectedNames.Add($childConfig.driver.Name)
                                    }
                                    $childToggle.IsEnabled = $false
                                    $childToggle.ToolTip = "$($childToggle.ToolTip) $reason"
                                }
                            } elseif (-not $isTaskGroup -and -not $servicePresent) {
                                $childToggle.IsEnabled = $false
                                # Missing services do not occupy space in the list.
                                $childToggle.Visibility = [Windows.Visibility]::Collapsed
                            }

                            # All three advanced groups only stage selections.
                            # The main Apply Tweaks job changes the OS later.
                            $onServiceChange = {
                                [System.Object]$senderControl = $args[0]
                                if ($senderControl.Tag.Updating) { return }
                                $requested = ($senderControl.IsChecked -eq $true)
                                if (-not $sync.ImportInProgress) {
                                    $pendingName = if ($senderControl.Tag.IsTaskGroup) {
                                        'PendingTaskSelections'
                                    } else {
                                        'PendingGroupSelections'
                                    }
                                    if ($null -eq $sync[$pendingName]) {
                                        $sync[$pendingName] = [hashtable]::Synchronized(@{})
                                    }
                                    try {
                                        # A cached baseline avoids synchronous
                                        # registry/service/scheduler reads per click.
                                        $actual = Get-WinUtilToggleStatus $senderControl.Name
                                        if ($requested -eq $actual) {
                                            $sync[$pendingName].Remove($senderControl.Name)
                                        } else {
                                            $sync[$pendingName][$senderControl.Name] = $requested
                                        }
                                    } catch {
                                        $senderControl.Tag.Updating = $true
                                        try { $senderControl.IsChecked = -not $requested }
                                        finally { $senderControl.Tag.Updating = $false }
                                        Show-WinUtilMessage -Title 'APBOptimizer' -Message "Could not stage $($senderControl.Name): $($_.Exception.Message)" -Icon 'Warning' -Button 'OK' | Out-Null
                                        return
                                    }
                                }
                                Invoke-WPFSelectedCheckboxesUpdate -type $(if ($senderControl.IsChecked) { 'Add' } else { 'Remove' }) -checkboxName $senderControl.Name
                                Update-WinUtilServiceGroupMaster -GroupName $senderControl.Tag.Group
                            }
                            $childToggle.Add_Checked($onServiceChange)
                            $childToggle.Add_Unchecked($onServiceChange)
                        }

                        $installedSearchTerms = @($entryInfo.Children | Where-Object {
                            $sync[$_] -and $sync[$_].Visibility -eq [Windows.Visibility]::Visible
                        } | ForEach-Object {
                            $childDefinition = $configHashtable[$_]
                            $systemName = if ($childDefinition.driver) { $childDefinition.driver.Name } elseif ($childDefinition.scheduledTask) { $childDefinition.scheduledTask.Name } else { $childDefinition.service[0].Name }
                            "$_ $($childDefinition.Content) $systemName"
                        }) -join ' '
                        $groupWrapper.Tag = "$($entryInfo.Content) $($entryInfo.Description) $installedSearchTerms"

                        if ($isDriverGroup) {
                            $manageable = @($entryInfo.Children | Where-Object {
                                $sync[$_] -and $sync[$_].IsEnabled -and
                                $sync[$_].Visibility -eq [Windows.Visibility]::Visible
                            }).Count
                            if ($manageable -eq 0) {
                                $isSpanish = ($sync.Language -eq 'es')
                                # One line per non-empty category, naming the drivers.
                                $lines = @(if ($isSpanish) { 'No hay nada que aplicar en este grupo.' } else { 'There is nothing to apply in this group.' })
                                foreach ($category in @(
                                    @{ Names = $driverAlreadyDisabledNames; Label = $(if ($isSpanish) { 'Ya desactivados' } else { 'Already disabled' }) },
                                    @{ Names = $driverMissingNames; Label = $(if ($isSpanish) { 'No instalados' } else { 'Not installed' }) },
                                    @{ Names = $driverProtectedNames; Label = $(if ($isSpanish) { 'Protegidos' } else { 'Protected' }) }
                                )) {
                                    if ($category.Names.Count -gt 0) {
                                        $lines += "$($category.Label) ($($category.Names.Count)): $($category.Names -join ', ')."
                                    }
                                }
                                if ($driverAlreadyDisabledNames.Count -gt 0) {
                                    $lines += if ($isSpanish) {
                                        "`nLos desactivó otra herramienta, una versión anterior de APBOptimizer o un cambio manual, así que no hay un modo de inicio original guardado. APBOptimizer no lo adivina y no puede reactivarlos. Para reactivar uno, usa un punto de restauración anterior al cambio o reinstala el programa que lo instaló."
                                    } else {
                                        "`nThey were disabled by another tool, an older APBOptimizer version or by hand, so no original startup mode was saved. APBOptimizer will not guess it and cannot re-enable them. To re-enable one, use a restore point from before the change or reinstall the program that installed it."
                                    }
                                }
                                $explanation = Convert-WinUtilTextEncoding -Text ($lines -join "`n")
                                $allAlreadyDisabled = ($driverAlreadyDisabledNames.Count -gt 0 -and $driverProtectedNames.Count -eq 0)
                                $master.Tag.NoManageableDrivers = $true
                                $master.Tag.AllAlreadyDisabled = $allAlreadyDisabled
                                $master.Tag.UnavailableMessage = $explanation
                                $master.Content = if ($allAlreadyDisabled) {
                                    if ($isSpanish) { "$($entryInfo.Content) (ya desactivados)" } else { "$($entryInfo.Content) (already disabled)" }
                                } elseif ($isSpanish) {
                                    "$($entryInfo.Content) (0 disponibles)"
                                } else {
                                    "$($entryInfo.Content) (0 available)"
                                }
                                $master.ToolTip = $explanation
                            }
                        }
                        Update-WinUtilServiceGroupMaster -GroupName $entryInfo.Name
                        $master.Add_Checked({
                            if ($this.Tag.Updating) { return }
                            if ($this.Tag.NoManageableDrivers) {
                                Show-WinUtilMessage -Title 'APBOptimizer - Drivers' -Message $this.Tag.UnavailableMessage -Icon 'Information' -Button 'OK' | Out-Null
                                Update-WinUtilServiceGroupMaster -GroupName $this.Name
                                return
                            }
                            $this.Tag.Updating = $true
                            try {
                                foreach ($childKey in @($this.Tag.Children)) {
                                    $child = $sync[$childKey]
                                    if ($null -ne $child -and $child.IsEnabled) { $child.IsChecked = $true }
                                }
                            } finally { $this.Tag.Updating = $false }
                            Update-WinUtilServiceGroupMaster -GroupName $this.Name
                        })
                        $master.Add_Unchecked({
                            if ($this.Tag.Updating) { return }
                            if ($this.Tag.NoManageableDrivers) {
                                Show-WinUtilMessage -Title 'APBOptimizer - Drivers' -Message $this.Tag.UnavailableMessage -Icon 'Information' -Button 'OK' | Out-Null
                                Update-WinUtilServiceGroupMaster -GroupName $this.Name
                                return
                            }
                            $this.Tag.Updating = $true
                            try {
                                foreach ($childKey in @($this.Tag.Children)) {
                                    $child = $sync[$childKey]
                                    if ($null -ne $child -and $child.IsEnabled) { $child.IsChecked = $false }
                                }
                            } finally { $this.Tag.Updating = $false }
                            Update-WinUtilServiceGroupMaster -GroupName $this.Name
                        })
                    }
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        [System.Windows.Automation.AutomationProperties]::SetName($dockPanel, $entryInfo.Content)
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $label.UseLayoutRounding = $true
                        $dockPanel.Children.Add($label) | Out-Null
                        $stackPanelContainer.Children.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox
                        $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                            # Skip applying tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtilTweaks $Sender.name
                            }
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                            # Skip undoing tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtiltweaks $Sender.name -undo $true
                            }
                        })
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = Get-WinUtilEntryToolTip -Description $entryInfo.Description -Key $entryInfo.Name
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle
                        [System.Windows.Automation.AutomationProperties]::SetName($toggleButton, $entryInfo.Content[0])

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $contentOn }
                        }

                        $stackPanelContainer.Children.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $toggleButton.Name) {
                            $toggleButton.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($toggleButton.Name) | Out-Null
                        }
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.HorizontalAlignment = "Left"
                        $label.ToolTip = $entryInfo.Description
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $label.UseLayoutRounding = $true
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $comboBox.UseLayoutRounding = $true
                        $comboBox.Tag = [pscustomobject]@{
                            Registry = $entryInfo.Registry
                            State = $null
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        $comboItems = if ($entryInfo.ComboItems -is [string]) {
                            if ($entryInfo.ComboItems.Contains("|")) {
                                $entryInfo.ComboItems -split "\|"
                            } else {
                                $entryInfo.ComboItems -split " "
                            }
                        } else {
                            @($entryInfo.ComboItems)
                        }

                        foreach ($comboitem in $comboItems) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            # Keep registry/DNS identifiers as Tag; only localize the
                            # visible labels, never the underlying system value.
                            $comboBoxItem.Tag = $comboitem
                            $localizedOption = if ($entryInfo.LocalizedComboItems) {
                                $entryInfo.LocalizedComboItems.PSObject.Properties[[string]$comboitem]
                            } else { $null }
                            $comboBoxItem.Content = if ($localizedOption) { $localizedOption.Value } else { $comboitem }
                            if ($entryInfo.ComboDescriptions) {
                                $comboDescription = $entryInfo.ComboDescriptions.PSObject.Properties[$comboitem].Value
                                if ($entryInfo.LocalizedComboDescriptions -and $entryInfo.LocalizedComboDescriptions.PSObject.Properties[[string]$comboitem]) {
                                    $comboDescription = $entryInfo.LocalizedComboDescriptions.PSObject.Properties[[string]$comboitem].Value
                                }
                                if ($comboDescription) {
                                    $comboBoxItem.ToolTip = $comboDescription
                                }
                            }
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $stackPanelContainer.Children.Add($horizontalStackPanel) | Out-Null

                        if ($entryInfo.Registry -and @($entryInfo.Registry)[0].Values) {
                            try {
                                $comboBox.Tag.State = Get-WinUtilRegistryComboState -Registry $entryInfo.Registry
                                $comboBox.SelectedIndex = @($comboBox.Items | ForEach-Object { $_.Tag }).IndexOf([string]$comboBox.Tag.State)
                            } catch {
                                $unknownStateItem = New-Object Windows.Controls.ComboBoxItem
                                $unknownStateItem.Content = if ($sync.Language -eq 'es') { 'Personalizado / Desconocido: elige una opción' } else { 'Custom / Unknown - select a state' }
                                $unknownStateItem.IsEnabled = $false
                                $unknownStateItem.ToolTip = "$($_.Exception.Message) Select one of the supported states to replace these values."
                                $comboBox.Items.Add($unknownStateItem) | Out-Null
                                $comboBox.SelectedItem = $unknownStateItem
                                $comboBox.ToolTip = $unknownStateItem.ToolTip
                            }
                        } else {
                            $comboBox.SelectedIndex = 0
                        }

                        # Set initial text
                        if ($comboBox.Items.Count -gt 0) {
                            $comboBox.Text = $comboBox.SelectedItem.Content
                        }

                        $sync[$entryInfo.Name] = $comboBox

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if ($selectedItem) {
                                $this.Text = $selectedItem.Content
                                $registry = $this.Tag.Registry
                                $stateValue = [string]$selectedItem.Tag
                                if ($registry -and $selectedItem.IsEnabled -and $stateValue -ne $this.Tag.State) {
                                    try {
                                        Set-WinUtilRegistryComboState -Registry $registry -State $stateValue
                                        $this.Tag.State = $stateValue
                                        $this.ToolTip = $null
                                        $unknownStateItem = @($this.Items) | Where-Object { -not $_.IsEnabled } | Select-Object -First 1
                                        if ($unknownStateItem) {
                                            $this.Items.Remove($unknownStateItem)
                                        }
                                    } catch {
                                        $applyError = $_.Exception.Message
                                        if ([string]::IsNullOrWhiteSpace($applyError)) {
                                            $applyError = "Unable to apply registry state '$($selectedItem.Content)'."
                                        }
                                        $previousState = [string]$this.Tag.State
                                        $this.SelectedItem = @($this.Items) | Where-Object { [string]$_.Tag -eq $previousState } | Select-Object -First 1
                                        [System.Windows.MessageBox]::Show(
                                            $applyError,
                                            "WinUtil",
                                            [System.Windows.MessageBoxButton]::OK,
                                            [System.Windows.MessageBoxImage]::Warning
                                        ) | Out-Null
                                    }
                                }
                            }
                        })

                        if ($entryInfo.Description -or $entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $comboBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = if ($sync.Language -eq 'es') { 'Ver información del ajuste' } else { 'View tweak information' }
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true
                            $textBlock.VerticalAlignment = "Center"
                            $textBlock.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                            $textBlock.Tag = $comboBox
                            $textBlock.Uid = $entryInfo.Name

                            $textBlock.Add_MouseUp({
                                [System.Object]$Sender = $args[0]
                                Show-WinUtilTweakHelp -Key $Sender.Uid -Anchor $Sender
                            })

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null
                            $sync[$textBlock.Name] = $textBlock
                        }
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $baseWidth = [int]$entryInfo.ButtonWidth
                            $button.Width = [math]::Max($baseWidth, 350)
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($button, $entryInfo.Content)
                        $stackPanelContainer.Children.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $button.Name) {
                            $button.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($button.Name) | Out-Null
                        }
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"
                            [System.Windows.Automation.AutomationProperties]::SetName($groupStackPanel, $entryInfo.GroupName)
                            $radioButtonGroups[$entryInfo.GroupName] = $groupStackPanel

                            # Add the group container to the ItemsControl
                            $stackPanelContainer.Children.Add($groupStackPanel) | Out-Null
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description
                        $radioButton.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($radioButton, $entryInfo.Content)

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    "Note" {
                        $textBlock = New-Object Windows.Controls.TextBlock
                        $textBlock.TextWrapping = "Wrap"
                        $textBlock.Margin = "5,5,5,5"
                        $textBlock.UseLayoutRounding = $true

                        $bulletBadge = [Windows.Documents.InlineUIContainer]::new((New-WinUtilFossBadge -Size 18 -Round))
                        $bulletBadge.BaselineAlignment = [Windows.BaselineAlignment]::Center

                        $textRun = New-Object Windows.Documents.Run
                        $textRun.Text = " $($entryInfo.Content)"
                        $textRun.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $textRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(19, 143, 83))

                        $textBlock.Inlines.Add($bulletBadge)
                        $textBlock.Inlines.Add($textRun)

                        $stackPanelContainer.Children.Add($textBlock) | Out-Null
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = Get-WinUtilEntryToolTip -Description $entryInfo.Description -Key $entryInfo.Name
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Description -or $entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = if ($sync.Language -eq 'es') { 'Ver información del ajuste' } else { 'View tweak information' }
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true

                            $textBlock.VerticalAlignment = "Center"
                            $textBlock.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                            $textBlock.Tag = $checkBox
                            $textBlock.Uid = $entryInfo.Name

                            $textBlock.Add_MouseUp({
                                [System.Object]$Sender = $args[0]
                                Show-WinUtilTweakHelp -Key $Sender.Uid -Anchor $Sender
                            })

                            $updateLinkMargin = {
                                [System.Object]$Sender = $args[0]
                                $linkedCheckBox = $Sender.Tag
                                $MarginTopBase = if ($linkedCheckBox) { $linkedCheckBox.Margin.Top } else { 0 }
                                $Sender.Margin = New-Object Windows.Thickness(
                                    [math]::Round($Sender.FontSize * 0.5),
                                    ($MarginTopBase - [math]::Round($Sender.FontSize / 2)),
                                    0, 0
                                )
                            }
                            $textBlock.Add_Loaded($updateLinkMargin)
                            $linkFontSizeDescriptor.AddValueChanged($textBlock, $updateLinkMargin)

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $stackPanelContainer.Children.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                        })
                    }
                }
            }
            if ($Yield -and -not $columnAttached) {
                $targetGrid.Children.Add($border) | Out-Null
                $columnAttached = $true
                $yieldClock.Restart()
                if (Test-WinUtilUIAlive) {
                    $frame = [Windows.Threading.DispatcherFrame]::new()
                    $null = $sync.Form.Dispatcher.BeginInvoke(
                        [Windows.Threading.DispatcherPriority]::Background,
                        [Windows.Threading.DispatcherOperationCallback]{
                            param($dispatcherFrame)
                            $dispatcherFrame.Continue = $false
                            return $null
                        },
                        $frame)
                    [Windows.Threading.Dispatcher]::PushFrame($frame)
                }
            }
        }
        # Normal redraws attach once; the first load shows each column's first category sooner.
        if (-not $columnAttached) { $targetGrid.Children.Add($border) | Out-Null }
    }

    # A search event can run inside one of the yielded dispatcher frames above. Controls added
    # after that event start visible, so reapply the live filter once this tab is complete.
    $filterPanel = switch ($sync.currentTab) {
        "Tweaks" { "tweakspanel" }
        "AppX" { "appxpanel" }
    }
    if ($filterPanel -eq $targetGridName -and $null -ne $sync.SearchBar -and $sync.SearchBar.Text) {
        Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
    }
}
