function Get-WinUtilGuidedLanguage {
    # The guided window is always in Spanish, whatever language the main
    # window uses. guided.json keeps English as the fallback text.
    return 'es'
}

function Get-WinUtilGuidedText {
    param($Text)
    if ($null -eq $Text) { return '' }
    $language = Get-WinUtilGuidedLanguage
    $value = if ($Text.PSObject.Properties[$language]) { $Text.$language } else { $Text.en }
    return Convert-WinUtilTextEncoding -Text ([string]$value)
}

function Get-WinUtilGuidedList {
    # Same as Get-WinUtilGuidedText, for { en: [...], es: [...] } lists.
    param($List)
    if ($null -eq $List) { return @() }
    $language = Get-WinUtilGuidedLanguage
    $values = if ($List.PSObject.Properties[$language]) { $List.$language } else { $List.en }
    return @($values | ForEach-Object { Convert-WinUtilTextEncoding -Text ([string]$_) })
}

function Get-WinUtilGuidedQuestions {
    return @($sync.configs.guided.Questions)
}

function Get-WinUtilGuidedGroupMembers {
    # Only installed services: missing ones are hidden in the Tweaks tab too.
    param([Parameter(Mandatory)][string]$GroupKey)
    return @($sync.configs.tweaks.$GroupKey.Children | Where-Object {
        $child = $sync.configs.tweaks.$_
        $child.service -and (Get-Service -Name $child.service[0].Name -ErrorAction SilentlyContinue)
    })
}

function Get-WinUtilGuidedAvailableOptions {
    param([Parameter(Mandatory)]$Question, [switch]$IncludeUnavailable)
    if ($Question.DataSource -eq 'StartupApps') { return @(Get-WinUtilGuidedStartupOptions -IncludeUnavailable:$IncludeUnavailable) }
    if ($Question.DataSource -eq 'AppxPackages') { return @(Get-WinUtilGuidedAppxOptions) }
    foreach ($option in @($Question.Options)) {
        if ($option.Unavailable) {
            if ($IncludeUnavailable) { $option }
            continue
        }
        $actions = @($option.Actions)
        $driverActions = @($actions | Where-Object { $sync.configs.tweaks.([string]$_.Key).driver.Name })
        if ($driverActions.Count -eq 0) { $option; continue }
        if ($actions.Count -ne 1) { continue }
        $key = [string]$actions[0].Key
        $entry = $sync.configs.tweaks.$key
        if (-not $entry -or -not $entry.driver.Name) { continue }
        if ($key -ne 'WPFTweaksDisableUCPD' -and $entry.ParentGroup -ne 'WPFDriverGroupOptional') { continue }
        # The same read-only check as the advanced driver manager: installed,
        # recognized and safely configurable, including a backed-up disabled driver.
        $info = $null
        try { $info = Get-WinUtilOptionalDriverInfo -Name ([string]$entry.driver.Name) }
        catch { $info = $null }
        if (-not $info -or -not $info.Present) { continue }
        if ($IncludeUnavailable) {
            $displayOption = $option.PSObject.Copy()
            $displayOption | Add-Member -NotePropertyName DriverInfo -NotePropertyValue $info
            $displayOption
        } elseif ($info -and $info.Present -and $info.CanChange) { $option }
    }
}

function Get-WinUtilGuidedPlan {
    <#
        .SYNOPSIS
            Turns guided answers into the work Apply runs and the rows the summary shows
    #>
    param(
        [hashtable]$Answers = @{},
        [hashtable]$Options = @{}
    )

    $tweaks = [System.Collections.Generic.List[string]]::new()
    $toggles = [System.Collections.Generic.List[object]]::new()
    $groupChanges = [System.Collections.Generic.List[object]]::new()
    $taskChanges = [System.Collections.Generic.List[object]]::new()
    $startupChanges = [System.Collections.Generic.List[object]]::new()
    $appxChanges = [System.Collections.Generic.List[object]]::new()
    $items = [System.Collections.Generic.List[object]]::new()
    $restorePoint = $false
    $powerPlan = $false
    $reboot = $false

    $questions = @(Get-WinUtilGuidedQuestions)
    for ($index = 0; $index -lt $questions.Count; $index++) {
        $question = $questions[$index]
        if (-not $Answers[$question.Id]) { continue }

        # A question with options contributes one summary row per selected option.
        $parts = @(if ($question.Options -or $question.DataSource -in @('StartupApps', 'AppxPackages')) {
            $chosen = $Options[$question.Id]
            Get-WinUtilGuidedAvailableOptions -Question $question | Where-Object { $chosen -and $chosen[$_.Id] } | ForEach-Object {
                if ($_.StartupEntry -and ($chosen[$_.Id] -notin @('Enable','Disable') -or
                    [bool]$_.StartupEntry.Enabled -eq ($chosen[$_.Id] -eq 'Enable'))) { return }
                [pscustomobject]@{ Label = Get-WinUtilGuidedText $_.Label; Actions = @($_.Actions); Reboot = [bool]($question.Reboot -or $_.Reboot); StartupEntry = $_.StartupEntry; AppxEntry = $_.AppxEntry; Reversible = ($question.Reversible -ne $false -and $_.Reversible -ne $false) }
            }
        } else {
            [pscustomobject]@{ Label = Get-WinUtilGuidedText $question.Summary; Actions = @($question.Actions); Reboot = [bool]$question.Reboot; Reversible = ($question.Reversible -ne $false) }
        })

        foreach ($part in $parts) {
            if ($part.StartupEntry) {
                $mode = [string]$Options[$question.Id][$part.StartupEntry.Id]
                $startupChanges.Add([pscustomobject]@{ Id=$part.StartupEntry.Id; Name=$part.StartupEntry.Name; Identity=$part.StartupEntry.Identity; Mode=$mode })
                $part.Label = $(if ($mode -eq 'Enable') { 'Habilitar al inicio: ' } else { 'Deshabilitar al inicio: ' }) + $part.Label
            }
            if ($part.AppxEntry) {
                $appxChanges.Add([pscustomobject]@{ Id = [string]$part.AppxEntry.Id; Name = [string]$part.AppxEntry.Name })
            }
            foreach ($action in $part.Actions) {
                $key = [string]$action.Key
                $entry = $sync.configs.tweaks.$key
                if ($null -eq $entry) { throw "Guided question '$($question.Id)' names unknown entry '$key'." }
                if ($key -eq 'WPFTweaksRestorePoint') {
                    $restorePoint = $true
                } elseif ($entry.Type -eq 'Button') {
                    # Buttons run code, not catalog entries; only this one is supported.
                    if ($key -ne 'WPFAddUltPerf') { throw "Guided question '$($question.Id)' names button '$key', which guided mode cannot run." }
                    $powerPlan = $true
                } elseif ($entry.Type -eq 'ServiceGroup') {
                    foreach ($member in @(Get-WinUtilGuidedGroupMembers -GroupKey $key)) {
                        if (-not ($groupChanges | Where-Object { $_.Key -eq $member })) {
                            $groupChanges.Add([pscustomobject]@{ Key = [string]$member; Disable = $true })
                        }
                    }
                } elseif ($entry.driver.Name -and $entry.ParentGroup -eq 'WPFDriverGroupOptional') {
                    if (-not ($groupChanges | Where-Object { $_.Key -eq $key })) {
                        $groupChanges.Add([pscustomobject]@{ Key = $key; Disable = $true })
                    }
                } elseif ($entry.Type -eq 'TaskGroup') {
                    # Members narrows the group to telemetry tasks; the Apply job
                    # skips tasks this PC does not have.
                    $members = if ($action.Members) { @($action.Members) } else { @($entry.Children) }
                    foreach ($member in $members) {
                        if ($member -notin @($entry.Children)) { throw "Guided question '$($question.Id)' names '$member', which is not part of '$key'." }
                        if (-not ($taskChanges | Where-Object { $_.Key -eq $member })) {
                            $taskChanges.Add([pscustomobject]@{ Key = [string]$member; Disable = $true })
                        }
                    }
                } elseif ($entry.Type -eq 'Toggle') {
                    $toggles.Add([pscustomobject]@{ Key = $key; State = [bool]$action.State })
                } elseif (-not $tweaks.Contains($key)) {
                    $tweaks.Add($key)
                }
            }
            $items.Add([pscustomobject]@{
                Index = $index
                Category = Get-WinUtilGuidedText $question.Category
                Label = $part.Label
                Advanced = ($question.Section -eq 'advanced')
                Reversible = [bool]$part.Reversible
                Reboot = [bool]$part.Reboot
            })
            if ($part.Reboot) { $reboot = $true }
        }
    }

    return [pscustomobject]@{
        RestorePoint = $restorePoint
        PowerPlan = $powerPlan
        Tweaks = @($tweaks)
        Toggles = @($toggles)
        GroupChanges = @($groupChanges)
        TaskChanges = @($taskChanges)
        StartupChanges = @($startupChanges)
        AppxChanges = @($appxChanges)
        Reboot = $reboot
        Items = @($items)
    }
}

function Get-WinUtilCpuMitigationAdvice {
    <#
        .SYNOPSIS
            Estimates from the CPU model whether turning off Spectre/Meltdown mitigations pays off

        .DESCRIPTION
            Intel CPUs before the 9th generation need software mitigations for Meltdown and
            Spectre v2, which cost the most. Intel 10th generation and later and AMD Zen 2 and
            later fix most of this in hardware, so the gain is small. Name-based estimate only.
    #>
    param([string]$Name)
    if (-not $Name) {
        try { $Name = [string](Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name } catch { $Name = '' }
    }
    $Name = ($Name -replace '\s+', ' ').Trim()

    $verdict = 'Unknown'
    if ($Name -match 'Intel') {
        if ($Name -match 'Core\(TM\) Ultra|Core Ultra') {
            $verdict = 'Low'
        } elseif ($Name -match '\bi[3579]-(\d{3,5})') {
            # 4-digit models starting with 1 are 10th/11th/12th+ gen laptop chips (i7-1165G7).
            $model = $Matches[1]
            $generation = if ($model.Length -eq 3) { 1 } elseif ($model.StartsWith('1')) { [int]$model.Substring(0, 2) } else { [int]$model.Substring(0, 1) }
            $verdict = if ($generation -le 8) { 'High' } elseif ($generation -eq 9) { 'Medium' } else { 'Low' }
        } elseif ($Name -match 'Core\(TM\)2|Core 2') {
            $verdict = 'High'
        }
    } elseif ($Name -match 'AMD') {
        if ($Name -match 'Ryzen AI') {
            $verdict = 'Low'
        } elseif ($Name -match 'Ryzen.*?\b(\d)\d{3}([A-Z]*)') {
            # Ryzen 1000/2000 and 3000 APUs (3400G) are Zen/Zen+.
            $series = [int]$Matches[1]
            $verdict = if ($series -le 2 -or ($series -eq 3 -and $Matches[2] -like 'G*')) { 'Medium' } else { 'Low' }
        } elseif ($Name -match '\bFX\b|Athlon|Phenom|\bA\d+-\d') {
            $verdict = 'Medium'
        }
    }

    $text = switch ($verdict) {
        'High' { @{ Title = 'Puede valer la pena en tu procesador'; Color = '#3FA34D'
                Text = 'Es un Intel anterior a la 9.ª generación: depende de mitigaciones por software que pueden costar bastante rendimiento en juegos, disco y red.' } }
        'Medium' { @{ Title = 'Ganancia pequeña en tu procesador'; Color = '#D4A017'
                Text = 'Tu procesador tiene parte de estas protecciones en hardware. Pruébalo solo si buscas cada FPS y aceptas el riesgo.' } }
        'Low' { @{ Title = 'No recomendado en tu procesador'; Color = '#E07B24'
                Text = 'Tu procesador trae estas protecciones en hardware: la ganancia es mínima y pierdes seguridad.' } }
        default { @{ Title = 'No se pudo identificar la generación de tu procesador'; Color = '#8A8A8A'
                Text = 'La ganancia suele ser notable en Intel anteriores a la 9.ª generación y mínima en procesadores modernos.' } }
    }
    return [pscustomobject]@{
        Name = $Name
        Verdict = $verdict
        Title = $text.Title
        Text = $text.Text
        Color = $text.Color
    }
}

function Get-WinUtilPowerPlanAdvice {
    <#
        .SYNOPSIS
            Says whether the Ultimate Performance plan suits this PC: desktop yes, laptop no

        .DESCRIPTION
            The chassis type decides. A battery only counts when the chassis is unknown,
            because a USB UPS also shows up as a battery on desktops.
    #>
    param([int[]]$ChassisTypes, [object]$HasBattery = $null)
    if (-not $PSBoundParameters.ContainsKey('ChassisTypes')) {
        try { $ChassisTypes = @((Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes) } catch { $ChassisTypes = @() }
    }
    $portable = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $desktop = @(3, 4, 5, 6, 7, 13, 15, 16, 17, 23, 24, 35, 36)
    $isLaptop = if (@($ChassisTypes | Where-Object { $_ -in $portable }).Count -gt 0) { $true }
        elseif (@($ChassisTypes | Where-Object { $_ -in $desktop }).Count -gt 0) { $false }
        else {
            if ($null -eq $HasBattery) {
                try { $HasBattery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { $HasBattery = $false }
            }
            [bool]$HasBattery
        }

    if ($isLaptop) {
        return [pscustomobject]@{
            Recommend = $false
            Title = 'No recomendado en tu equipo (portátil)'
            Text = 'Tu equipo es portátil: el plan sube el consumo y la temperatura y gasta más batería. Aunque la uses enchufada, la ganancia suele ser pequeña.'
            Color = '#E07B24'
        }
    }
    return [pscustomobject]@{
        Recommend = $true
        Title = 'Recomendado en tu equipo (PC de escritorio)'
        Text = 'Tu equipo es de escritorio: no tienes batería que cuidar. Solo sube un poco el consumo en reposo.'
        Color = '#3FA34D'
    }
}

function Test-WinUtilGuidedQuestionApplied {
    # True only when every action is a readable toggle or service group already
    # in the answer's state. Script tweaks have no reliable state, so $null.
    param([Parameter(Mandatory)]$Question)
    if ($Question.Options -or -not $Question.Actions) { return $null }
    foreach ($action in @($Question.Actions)) {
        $entry = $sync.configs.tweaks.$($action.Key)
        if ($entry.Type -eq 'ServiceGroup') {
            foreach ($member in @(Get-WinUtilGuidedGroupMembers -GroupKey $action.Key)) {
                if (-not (Get-WinUtilToggleStatus -ToggleSwitch $member)) { return $false }
            }
        } elseif ($entry.Type -eq 'Toggle' -and $null -ne $action.State) {
            if ([bool](Get-WinUtilToggleStatus -ToggleSwitch $action.Key) -ne [bool]$action.State) { return $false }
        } else {
            return $null
        }
    }
    return $true
}

function New-WinUtilGuidedBadge {
    param([string]$Text, [string]$Color)
    $brush = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    $badge = New-Object Windows.Controls.Border
    $badge.BorderBrush = $brush
    $badge.BorderThickness = '1.5'
    $badge.CornerRadius = '10'
    $badge.Padding = '10,3'
    $badge.Margin = '0,0,8,6'
    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontSize = 12
    $label.FontWeight = 'Bold'
    $label.Background = [Windows.Media.Brushes]::Transparent
    $label.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MainForegroundColor')
    $badge.Child = $label
    return $badge
}

function New-WinUtilGuidedWindow {
    <#
        .SYNOPSIS
            Builds the separate guided-mode window from $guidedXML

        .DESCRIPTION
            A closed WPF window cannot be shown again, so every opening builds a new one. The
            main window's resources are merged in, which gives it the same theme and styles.
    #>
    param([System.Windows.Window]$Owner)

    [xml]$xaml = $guidedXML
    $window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
    if ($sync.Form) { $window.Resources.MergedDictionaries.Add($sync.Form.Resources) }
    $xaml.SelectNodes('//*[@Name]') | ForEach-Object { $sync[$_.Name] = $window.FindName($_.Name) }
    $sync.GuidedWindow = $window
    $sync.GuidedOpenAdvanced = $false
    if ($Owner) {
        $window.Owner = $Owner
        $window.WindowStartupLocation = 'CenterOwner'
    }
    if ($sync.version) { $window.Title = "APBOptimizer $($sync.version)" }

    # The main window wired its buttons before this one existed.
    foreach ($node in $xaml.SelectNodes("//*[local-name()='Button'][@Name]")) {
        $sync[$node.Name].Add_Click({ Invoke-WPFButton $this.Name })
    }
    $sync.WPFGuidedTitleBar.Add_MouseLeftButtonDown({ $sync.GuidedWindow.DragMove() })
    $window.Add_Closing({
        param($eventSender, $closingArgs)
        $null = $eventSender
        if ($sync.ActiveJob -in @('Guided', 'StartupAppsScan', 'GuidedAppxScan')) {
            $closingArgs.Cancel = $true
            $message = if ((Get-WinUtilGuidedLanguage) -eq 'es') { 'Espera a que termine la operación en curso.' } else { 'Wait until the current operation finishes.' }
            Show-WinUtilMessage -Title 'APBOptimizer' -Message $message -Button 'OK' -Icon 'Information' | Out-Null
        }
    })
    $window.Add_Closed({ $sync.GuidedPanel = $null })

    try {
        $logo = Invoke-WinUtilAssets -Type 'logo' -Size 25
        $sync.GuidedLogoPanel.Children.Add($logo) | Out-Null
        $window.Icon = $logo.Source
    } catch {
        Write-WinUtilLog -Level 'WARN' -Component 'Guided' -Message "Could not draw the guided window logo: $($_.Exception.Message)"
    }
    return $window
}

function Show-WinUtilGuidedWindow {
    <#
        .SYNOPSIS
            Shows the guided window until it closes; returns $true when the user chose advanced mode
    #>
    param(
        [ValidateSet('Chooser', 'Resume')][string]$Start = 'Chooser',
        [System.Windows.Window]$Owner
    )

    $sync.GuidedReviewPlan = $null
    $window = New-WinUtilGuidedWindow -Owner $Owner
    if ($Start -eq 'Chooser' -and -not $Owner) {
        $window.Add_ContentRendered({
            $sync.GuidedWindow.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ApplicationIdle, [action]{
                if ($null -eq $sync.GuidedWindow -or $sync.GuidedOpenAdvanced -or
                    ($sync.InitializedTabs -and $sync.InitializedTabs['Tweaks'])) { return }
                try {
                    Initialize-WinUtilTabContent -TabName 'Tweaks' -Yield
                } catch {
                    Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'UI' -Context 'Prepare advanced Tweaks'
                }
            }) | Out-Null
        })
    }
    switch ($Start) {
        'Chooser' { Show-WinUtilModeChooser }
        'Resume' {
            # Reopening keeps an unfinished run's answers.
            if ($sync.GuidedState -and -not $sync.GuidedState.Completed) {
                Show-WinUtilGuidedQuestion -Index $sync.GuidedState.Index
            } else {
                Start-WinUtilGuided
            }
        }
    }
    $null = $window.ShowDialog()
    $sync.GuidedWindow = $null
    return [bool]$sync.GuidedOpenAdvanced
}

function Show-WinUtilGuidedPanel {
    param([Parameter(Mandatory)][ValidateSet('Chooser', 'Wizard', 'Summary', 'Done')][string]$Panel)
    $panels = @{ Chooser = 'WPFModeChooser'; Wizard = 'WPFGuidedWizard'; Summary = 'WPFGuidedSummary'; Done = 'WPFGuidedDone' }
    foreach ($entry in $panels.GetEnumerator()) {
        $sync[$entry.Value].Visibility = if ($entry.Key -eq $Panel) { 'Visible' } else { 'Collapsed' }
    }
    $sync.GuidedPanel = $Panel
}

function Show-WinUtilModeChooser {
    Show-WinUtilGuidedPanel -Panel 'Chooser'
}

function Select-WinUtilMode {
    param([Parameter(Mandatory)][ValidateSet('guided', 'advanced')][string]$Mode)
    if ($Mode -eq 'guided') { Start-WinUtilGuided } else { Exit-WinUtilGuided }
}

function Start-WinUtilGuided {
    $sync.GuidedState = @{ Index = 0; Answers = @{}; Options = @{}; ReturnToSummary = $false; Completed = $false }
    $sync.StartupAppsCacheLoaded = $false
    $sync.GuidedAppxCacheLoaded = $false
    $sync.GuidedAppxEntries = @()
    Show-WinUtilGuidedQuestion -Index 0
}

function Exit-WinUtilGuided {
    # Closing hands over to the full interface: Start-WinUtilUserInterface opens it,
    # or it is already open underneath when guided mode came from its menu.
    $sync.GuidedOpenAdvanced = $true
    if ($sync.GuidedWindow) { $sync.GuidedWindow.Close() }
}

function Show-WinUtilGuidedQuestion {
    param([int]$Index)

    $questions = @(Get-WinUtilGuidedQuestions)
    if ($Index -ge $questions.Count) {
        Show-WinUtilGuidedSummary
        return
    }
    if ($Index -lt 0) { $Index = 0 }
    $sync.GuidedState.Index = $Index
    $question = $questions[$Index]
    if ($question.DataSource -eq 'StartupApps') { Request-WinUtilGuidedStartupApps }
    if ($question.DataSource -eq 'AppxPackages') { Request-WinUtilGuidedAppx }
    $isSpanish = ((Get-WinUtilGuidedLanguage) -eq 'es')
    $sync.WPFGuidedCategory.Text = Get-WinUtilGuidedText $question.Category
    $sync.WPFGuidedStep.Text = if ($isSpanish) { "Pregunta $($Index + 1) de $($questions.Count)" } else { "Question $($Index + 1) of $($questions.Count)" }
    $sync.WPFGuidedProgress.Value = [math]::Round((($Index + 1) / $questions.Count) * 100)
    $sync.WPFGuidedTitle.Text = Get-WinUtilGuidedText $question.Title
    $sync.WPFGuidedBody.Text = Get-WinUtilGuidedText $question.Body
    $sync.WPFGuidedBenefitsTitle.Text = if ($isSpanish) { 'Ventajas' } else { 'Benefits' }
    foreach ($section in @(
        @{ Panel = $sync.WPFGuidedDetails; List = $sync.WPFGuidedDetailsList; Items = $question.Details },
        @{ Panel = $sync.WPFGuidedBenefits; List = $sync.WPFGuidedBenefitsList; Items = $question.Benefits }
    )) {
        $section.List.Children.Clear()
        $items = @(Get-WinUtilGuidedList $section.Items)
        foreach ($item in $items) {
            $line = New-Object Windows.Controls.TextBlock
            $line.Text = [string][char]0x2022 + '  ' + $item
            $line.FontSize = 14
            $line.TextWrapping = 'Wrap'
            $line.Margin = '4,0,0,4'
            $line.Opacity = 0.9
            $line.Background = [Windows.Media.Brushes]::Transparent
            $line.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MainForegroundColor')
            $section.List.Children.Add($line) | Out-Null
        }
        $section.Panel.Visibility = if ($items.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    }
    $note = Get-WinUtilGuidedText $question.Note
    $sync.WPFGuidedNoteText.Text = $note
    $sync.WPFGuidedNote.Visibility = if ($note) { 'Visible' } else { 'Collapsed' }

    # Some answers depend on this PC: the advice box says why, and a desktop
    # makes the power plan a recommended answer.
    $advice = $null
    if ($question.Advice -eq 'CPUMitigations') {
        if (-not $sync.GuidedCpuAdvice) { $sync.GuidedCpuAdvice = Get-WinUtilCpuMitigationAdvice }
        $cpu = $sync.GuidedCpuAdvice
        $cpuName = if ($cpu.Name) { $cpu.Name } else { 'desconocido' }
        $advice = [pscustomobject]@{ Title = "$($cpu.Title) ($cpuName)"; Text = "$($cpu.Text) Estimación según el modelo del procesador."; Color = $cpu.Color; Recommend = $false }
    } elseif ($question.Advice -eq 'PowerPlan') {
        if (-not $sync.GuidedPowerAdvice) { $sync.GuidedPowerAdvice = Get-WinUtilPowerPlanAdvice }
        $advice = $sync.GuidedPowerAdvice
    }
    $recommended = [bool]$question.Recommended -or ($null -ne $advice -and [bool]$advice.Recommend)

    $sync.WPFGuidedBadges.Children.Clear()
    if ($recommended) {
        $sync.WPFGuidedBadges.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'Recomendado' } else { 'Recommended' }) -Color '#2E77FF')) | Out-Null
    }
    if ($question.Reversible -eq $false) {
        $sync.WPFGuidedBadges.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'No se puede deshacer' } else { 'Cannot be undone' }) -Color '#E07B24')) | Out-Null
    } elseif (@($question.Options | Where-Object { $_.Reversible -eq $false }).Count -gt 0) {
        $sync.WPFGuidedBadges.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'Algunas opciones no se pueden deshacer' } else { 'Some options cannot be undone' }) -Color '#E07B24')) | Out-Null
    } else {
        $sync.WPFGuidedBadges.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'Se puede deshacer' } else { 'Can be undone' }) -Color '#3FA34D')) | Out-Null
    }
    if ($question.Reboot) {
        $sync.WPFGuidedBadges.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'Requiere reiniciar' } else { 'Restart required' }) -Color '#D4A017')) | Out-Null
    }

    $sync.WPFGuidedAdvice.Visibility = 'Collapsed'
    if ($advice) {
        $sync.WPFGuidedAdviceTitle.Text = Convert-WinUtilTextEncoding -Text ([string]$advice.Title)
        $sync.WPFGuidedAdviceText.Text = Convert-WinUtilTextEncoding -Text ([string]$advice.Text)
        $sync.WPFGuidedAdvice.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString($advice.Color)
        $sync.WPFGuidedAdvice.Visibility = 'Visible'
    }

    $applied = $null
    try { $applied = Test-WinUtilGuidedQuestionApplied -Question $question } catch { $applied = $null }
    $sync.WPFGuidedState.Text = if ($isSpanish) { 'Ya está así en tu PC.' } else { 'This PC is already set this way.' }
    $sync.WPFGuidedState.Visibility = if ($applied -eq $true) { 'Visible' } else { 'Collapsed' }

    $sync.WPFGuidedOptions.Children.Clear()
    $sync.GuidedOptionBoxes = [System.Collections.Generic.List[object]]::new()
    if ($question.Options -or $question.DataSource -in @('StartupApps','AppxPackages')) {
        $saved = $sync.GuidedState.Options[$question.Id]
        $asToggles = ($question.OptionStyle -eq 'Toggle')
        # Display installed drivers, but leave plan building on the eligibility filter.
        $availableOptions = @(Get-WinUtilGuidedAvailableOptions -Question $question -IncludeUnavailable)
        foreach ($option in $availableOptions) {
            $box = New-Object Windows.Controls.CheckBox
            $box.Tag = [string]$option.Id
            $box.IsChecked = if ($saved -and $saved.ContainsKey([string]$option.Id)) { [bool]$saved[[string]$option.Id] } else { [bool]$option.Default }
            if ($option.Unavailable) {
                $box.IsEnabled = $false
                $box.IsChecked = $false
            }
            if ($option.PSObject.Properties['DriverInfo']) {
                $info = $option.DriverInfo
                $box.IsEnabled = [bool]($info -and $info.Present -and $info.CanChange)
                if (-not $box.IsEnabled) { $box.IsChecked = [bool]($info -and $info.Disabled) }
            }
            if ($option.StartupEntry) {
                $box.IsEnabled = [bool]($option.StartupEntry.CanChange -and -not $sync.StartupAppsLoading)
                # Startup switches show whether the app will start, while saved
                # choices identify pending enable/disable operations.
                $pending = if ($saved) { $saved[[string]$option.Id] } else { $null }
                $box.IsChecked = if ($option.StartupEntry.CanChange -and $pending -in @('Enable','Disable')) { $pending -eq 'Enable' } else { [bool]$option.StartupEntry.Enabled }
            }
            $content = New-Object Windows.Controls.StackPanel
            foreach ($line in @(
                @{ Text = Get-WinUtilGuidedText $option.Label; Size = 15; Bold = $true },
                @{ Text = Get-WinUtilGuidedText $option.Detail; Size = 13; Bold = $false }
            )) {
                $text = New-Object Windows.Controls.TextBlock
                $text.Text = $line.Text
                $text.FontSize = $line.Size
                $text.TextWrapping = 'Wrap'
                $text.Background = [Windows.Media.Brushes]::Transparent
                if ($line.Bold) { $text.FontWeight = 'Bold' } else { $text.Opacity = 0.8; $text.Margin = '0,3,0,0' }
                $text.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MainForegroundColor')
                $content.Children.Add($text) | Out-Null
            }
            if ($option.StartupEntry -or $option.AppxEntry) {
                $icon = New-Object Windows.Controls.Image
                $icon.Source = if ($option.StartupEntry) { $option.StartupEntry.Icon } else { $option.AppxEntry.Icon }
                $icon.Width = 32; $icon.Height = 32; $icon.Margin = '0,0,12,0'; $icon.VerticalAlignment = 'Center'
                $rowContent = New-Object Windows.Controls.DockPanel
                $rowContent.Children.Add($icon) | Out-Null
                $rowContent.Children.Add($content) | Out-Null
                $content = $rowContent
            }
            $sync.GuidedOptionBoxes.Add($box)

            if (-not $asToggles) {
                $box.Margin = '0,0,0,10'
                $box.Content = $content
                $sync.WPFGuidedOptions.Children.Add($box) | Out-Null
                continue
            }

            # Settings-style row: text on the left, the same switch the Tweaks tab
            # uses on the right. Clicking anywhere on the row flips it.
            $box.SetResourceReference([Windows.FrameworkElement]::StyleProperty, 'ColorfulToggleSwitchStyle')
            $box.VerticalAlignment = 'Center'
            $box.Margin = '20,0,0,0'
            $box.IsHitTestVisible = $false
            [System.Windows.Automation.AutomationProperties]::SetName($box, (Get-WinUtilGuidedText $option.Label))
            $grid = New-Object Windows.Controls.Grid
            foreach ($width in @('*', 'Auto')) {
                $column = New-Object Windows.Controls.ColumnDefinition
                $column.Width = $width
                $grid.ColumnDefinitions.Add($column) | Out-Null
            }
            [Windows.Controls.Grid]::SetColumn($box, 1)
            $grid.Children.Add($content) | Out-Null
            $grid.Children.Add($box) | Out-Null
            $row = New-Object Windows.Controls.Border
            $row.Child = $grid
            $row.Tag = $box
            $row.Padding = '16,12'
            $row.Margin = '0,0,0,10'
            $row.CornerRadius = '6'
            $row.BorderThickness = '1'
            $row.Cursor = if ($box.IsEnabled) { [Windows.Input.Cursors]::Hand } else { [Windows.Input.Cursors]::Arrow }
            $row.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'TweakHelpSectionColor')
            $row.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'TweakHelpBorderColor')
            $row.Add_MouseLeftButtonUp({ if ($this.Tag.IsEnabled) { $this.Tag.IsChecked = -not [bool]$this.Tag.IsChecked } })
            $sync.WPFGuidedOptions.Children.Add($row) | Out-Null
        }
    }

    $yes = Get-WinUtilGuidedText $question.YesLabel
    $no = Get-WinUtilGuidedText $question.NoLabel
    $sync.WPFGuidedYes.Content = if ($yes) { $yes } elseif ($isSpanish) { 'Sí' } else { 'Yes' }
    $sync.WPFGuidedNo.Content = if ($no) { $no } else { 'No' }
    # Advanced questions highlight neither answer. ClearValue restores the
    # window's implicit Button style; assigning $null would fall back to the
    # system theme.
    if ($recommended) {
        $sync.WPFGuidedYes.Style = $sync.Form.FindResource('GuidedPrimaryButton')
    } else {
        $sync.WPFGuidedYes.ClearValue([Windows.FrameworkElement]::StyleProperty)
    }
    $sync.WPFGuidedBack.Content = if ($isSpanish) { 'Atrás' } else { 'Back' }
    $isStartup = $question.DataSource -eq 'StartupApps'
    $isAppx = $question.DataSource -eq 'AppxPackages'
    $sync.WPFGuidedYes.IsEnabled = -not (($isStartup -and $sync.StartupAppsLoading) -or ($isAppx -and $sync.GuidedAppxLoading))
    $sync.WPFGuidedStartupStatus.Text = ''
    if ($isStartup) {
        $sync.WPFGuidedStartupStatus.Text = if ($sync.StartupAppsLoading) { 'Buscando aplicaciones de inicio...' }
            elseif ($sync.StartupAppsError) { $sync.StartupAppsError }
            elseif (@($sync.StartupAppsEntries).Count -eq 0) { 'No se encontraron aplicaciones de inicio en este equipo.' }
            else { '' }
    }
    if ($isAppx) {
        $sync.WPFGuidedStartupStatus.Text = if ($sync.GuidedAppxLoading) { 'Buscando aplicaciones de Microsoft Store...' }
            elseif ($sync.GuidedAppxError) { $sync.GuidedAppxError }
            elseif (@($sync.GuidedAppxEntries).Count -eq 0) { 'No se encontraron aplicaciones opcionales para desinstalar.' }
            else { "$(@($sync.GuidedAppxEntries).Count) aplicaciones disponibles. Activado: desinstalar. Desactivado: conservar." }
    }
    $sync.WPFGuidedStartupStatus.Visibility = if ($sync.WPFGuidedStartupStatus.Text) { 'Visible' } else { 'Collapsed' }

    Show-WinUtilGuidedPanel -Panel 'Wizard'
}

function Save-WinUtilGuidedOptions {
    # Keeps the current checkbox choices when the view is redrawn.
    param([bool]$Answer = $true)
    $questions = @(Get-WinUtilGuidedQuestions)
    $question = $questions[$sync.GuidedState.Index]
    if (-not $question.Options -and $question.DataSource -notin @('StartupApps','AppxPackages')) { return $null }
    $selected = @{}
    foreach ($box in @($sync.GuidedOptionBoxes)) {
        if ($question.DataSource -eq 'StartupApps') {
            $entry = @($sync.StartupAppsEntries | Where-Object Id -eq ([string]$box.Tag)) | Select-Object -First 1
            $selected[[string]$box.Tag] = if ($Answer -and $entry.CanChange -and $box.IsEnabled -and
                [bool]$box.IsChecked -ne [bool]$entry.Enabled) { if ($box.IsChecked) { 'Enable' } else { 'Disable' } } else { $null }
        } else {
            $selected[[string]$box.Tag] = ($Answer -and $box.IsEnabled -and $box.IsChecked -eq $true)
        }
    }
    $sync.GuidedState.Options[$question.Id] = $selected
    return $selected
}

function Submit-WinUtilGuidedAnswer {
    param([Parameter(Mandatory)][bool]$Answer)
    $questions = @(Get-WinUtilGuidedQuestions)
    $question = $questions[$sync.GuidedState.Index]
    $selected = Save-WinUtilGuidedOptions -Answer $Answer
    $sync.GuidedState.Answers[$question.Id] = if ($question.DataSource -eq 'StartupApps') {
        [bool](@($selected.Values | Where-Object { $_ -in @('Enable','Disable') }).Count)
    } elseif ($question.Options) { [bool](@($selected.Values) -contains $true) } else { $Answer }

    if ($sync.GuidedState.ReturnToSummary) {
        $sync.GuidedState.ReturnToSummary = $false
        Show-WinUtilGuidedSummary
        return
    }
    Show-WinUtilGuidedQuestion -Index ($sync.GuidedState.Index + 1)
}

function Step-WinUtilGuidedBack {
    if ($sync.GuidedState.ReturnToSummary) {
        $sync.GuidedState.ReturnToSummary = $false
        Show-WinUtilGuidedSummary
    } elseif ($sync.GuidedState.Index -le 0) {
        Show-WinUtilModeChooser
    } else {
        Show-WinUtilGuidedQuestion -Index ($sync.GuidedState.Index - 1)
    }
}

function Show-WinUtilGuidedSummary {
    $isSpanish = ((Get-WinUtilGuidedLanguage) -eq 'es')
    $plan = Get-WinUtilGuidedPlan -Answers $sync.GuidedState.Answers -Options $sync.GuidedState.Options
    $sync.GuidedPlan = $plan
    $sync.GuidedState.Index = @(Get-WinUtilGuidedQuestions).Count
    $count = @($plan.Items).Count

    $sync.WPFGuidedSummaryTitle.Text = if ($count -eq 0) {
        if ($isSpanish) { 'No hay cambios para aplicar' } else { 'There are no changes to apply' }
    } elseif ($isSpanish) { "Se aplicarán $count cambios" } else { "$count changes will be applied" }
    $sync.WPFGuidedSummarySubtitle.Text = if ($isSpanish) {
        'Lo que respondiste con No no se toca. Pulsa Cambiar para corregir una respuesta.'
    } else { 'Anything you answered No to is left alone. Click Change to correct an answer.' }
    $sync.WPFGuidedSummaryNote.Text = if (@($plan.Items | Where-Object { -not $_.Reversible }).Count -gt 0) {
        if ($isSpanish) { 'Los cambios marcados "No se puede deshacer" no vuelven atrás. El resto se puede revertir desde el modo avanzado.' }
        else { 'Changes marked "Cannot be undone" cannot be reverted. Everything else can be reverted from advanced mode.' }
    } elseif ($isSpanish) { 'Todo se puede revertir después desde el modo avanzado.' } else { 'Everything can be reverted later from advanced mode.' }

    $list = $sync.WPFGuidedSummaryList
    $list.Children.Clear()
    $row = 0
    foreach ($item in @($plan.Items)) {
        $grid = New-Object Windows.Controls.Grid
        $grid.Margin = '0'
        foreach ($width in @('170', '*', 'Auto', 'Auto')) {
            $column = New-Object Windows.Controls.ColumnDefinition
            $column.Width = $width
            $grid.ColumnDefinitions.Add($column) | Out-Null
        }
        if ($row % 2 -eq 0) { $grid.SetResourceReference([Windows.Controls.Panel]::BackgroundProperty, 'TweakHelpSectionColor') }

        $category = New-Object Windows.Controls.TextBlock
        $category.Text = $item.Category
        $category.FontWeight = 'SemiBold'
        $category.Margin = '14,9,8,9'
        $category.VerticalAlignment = 'Center'
        $category.Background = [Windows.Media.Brushes]::Transparent
        $category.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $(if ($item.Advanced) { 'ProgressBarWarningColor' } else { 'LinkForegroundColor' }))
        [Windows.Controls.Grid]::SetColumn($category, 0)

        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $item.Label
        $label.FontSize = 14
        $label.TextWrapping = 'Wrap'
        $label.Margin = '0,9,8,9'
        $label.VerticalAlignment = 'Center'
        $label.Background = [Windows.Media.Brushes]::Transparent
        $label.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MainForegroundColor')
        [Windows.Controls.Grid]::SetColumn($label, 1)

        $tags = New-Object Windows.Controls.WrapPanel
        $tags.VerticalAlignment = 'Center'
        $tags.Margin = '0,6,0,0'
        if ($item.Reboot) { $tags.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'Reinicio' } else { 'Restart' }) -Color '#D4A017')) | Out-Null }
        if (-not $item.Reversible) { $tags.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'No se puede deshacer' } else { 'Cannot be undone' }) -Color '#E07B24')) | Out-Null }
        [Windows.Controls.Grid]::SetColumn($tags, 2)

        $change = New-Object Windows.Controls.Button
        $change.Content = if ($isSpanish) { 'Cambiar' } else { 'Change' }
        $change.Width = [double]::NaN
        $change.Height = 30
        $change.Margin = '4,4,10,4'
        $change.Tag = [int]$item.Index
        $change.Add_Click({
            $sync.GuidedState.ReturnToSummary = $true
            Show-WinUtilGuidedQuestion -Index ([int]$this.Tag)
        })
        [Windows.Controls.Grid]::SetColumn($change, 3)

        foreach ($cell in @($category, $label, $tags, $change)) { $grid.Children.Add($cell) | Out-Null }
        $list.Children.Add($grid) | Out-Null
        $row++
    }

    $sync.WPFGuidedApply.Content = if ($isSpanish) { "Aplicar $count cambios" } else { "Apply $count changes" }
    $sync.WPFGuidedApply.IsEnabled = ($count -gt 0)
    $sync.WPFGuidedReview.Content = if ($isSpanish) { 'Revisar en modo avanzado' } else { 'Review in advanced mode' }
    $sync.WPFGuidedSummaryBack.Content = if ($isSpanish) { 'Atrás' } else { 'Back' }
    Show-WinUtilGuidedPanel -Panel 'Summary'
}

function Invoke-WinUtilGuidedReview {
    $sync.GuidedReviewPlan = $sync.GuidedPlan
    Exit-WinUtilGuided
}

function Complete-WinUtilGuidedReview {
    # Marks the plan in the main window's Tweaks tab instead of applying it.
    # Toggle switches apply on click, so they are listed rather than flipped.
    $plan = $sync.GuidedReviewPlan
    $sync.GuidedReviewPlan = $null
    if (-not $plan) { return }
    Invoke-WPFTab 'WPFTab2BT'

    $selection = @($plan.Tweaks)
    if ($plan.RestorePoint) { $selection = @('WPFTweaksRestorePoint') + $selection }
    Invoke-WPFPresets -preset $selection -imported $true -checkboxfilterpattern 'WPFTweak*'
    $sync.PendingStartupChanges = [hashtable]::Synchronized(@{})
    foreach ($change in @($plan.StartupChanges)) { $sync.PendingStartupChanges[$change.Id] = $change }
    foreach ($change in @($plan.GroupChanges) + @($plan.TaskChanges)) {
        $checkbox = $sync[$change.Key]
        if ($checkbox -and $checkbox.IsEnabled -and $checkbox.IsChecked -ne $true) { $checkbox.IsChecked = $true }
    }

    $toggleNames = @($plan.Toggles | Where-Object {
        [bool](Get-WinUtilToggleStatus -ToggleSwitch $_.Key) -ne [bool]$_.State
    } | ForEach-Object {
        $localized = Get-WinUtilLocalizedEntry -Key $_.Key
        $name = if ($localized -and $localized.Content) { $localized.Content } else { $sync.configs.tweaks.$($_.Key).Content }
        $state = if ($_.State) { 'ON' } else { 'OFF' }
        "$name -> $state"
    })
    if ($plan.PowerPlan) {
        $toggleNames += "$(Get-WinUtilGuidedStepLabel -Key 'WPFAddUltPerf') -> $(if ((Get-WinUtilGuidedLanguage) -eq 'es') { 'botón en Planes de rendimiento' } else { 'button under Performance Plans' })"
    }
    $startupNotice = if (@($plan.StartupChanges).Count -gt 0) {
        'Cambios de inicio preparados para aplicar al pulsar Ejecutar ajustes: ' + (($plan.StartupChanges | ForEach-Object { $(if ($_.Mode -eq 'Enable') { 'Habilitar: ' } else { 'Deshabilitar: ' }) + $_.Name }) -join ', ') + '. Para revertir un cambio, vuelve a Aplicaciones de inicio, mueve su interruptor al estado anterior y aplica el plan.'
    } else { '' }
    if ($toggleNames.Count -gt 0) {
        $message = if ((Get-WinUtilGuidedLanguage) -eq 'es') {
            "Se marcaron los ajustes del modo guiado. Estos interruptores se aplican al instante, así que no se cambiaron; ajústalos tú en Personalizar preferencias:`n`n$($toggleNames -join "`n")"
        } else {
            "The guided choices are now selected. These switches apply instantly, so they were not changed; set them yourself in Customize Preferences:`n`n$($toggleNames -join "`n")"
        }
        if ($startupNotice) { $message += "`n`n$startupNotice" }
        Show-WinUtilMessage -Title 'APBOptimizer' -Message (Convert-WinUtilTextEncoding -Text $message) -Button 'OK' -Icon 'Information' | Out-Null
    } elseif ($startupNotice) {
        Show-WinUtilMessage -Title 'APBOptimizer' -Message (Convert-WinUtilTextEncoding -Text $startupNotice) -Button 'OK' -Icon 'Information' | Out-Null
    }
}

function Step-WinUtilGuidedJob {
    # The main window's progress bar may be hidden, so the guided window
    # shows the same progress on its own bar.
    param([string]$Status, [int]$Percent)
    Step-WinUtilJob -Status $Status -Percent $Percent
    if (Test-WinUtilUIAlive) {
        Invoke-WPFUIThread -Async -Parameters @{ Status = $Status; Percent = $Percent } -ScriptBlock {
            param($Status, $Percent)
            if ($sync.WPFGuidedJobProgress) {
                $sync.WPFGuidedJobProgress.Value = $Percent
                $sync.WPFGuidedJobLabel.Text = $Status
            }
        }
    }
}

function Get-WinUtilGuidedStepLabel {
    param([Parameter(Mandatory)][string]$Key)
    $localized = if ($sync.configs.es) { $sync.configs.es.PSObject.Properties[$Key] } else { $null }
    $name = if ($localized -and $localized.Value.Content) { $localized.Value.Content } elseif ($sync.configs.tweaks.$Key.Content) { $sync.configs.tweaks.$Key.Content } else { $Key }
    return Convert-WinUtilTextEncoding -Text ([string]$name)
}

function Get-WinUtilGuidedErrorMark {
    if ($null -eq $sync.LoggedErrors) { return 0 }
    return $sync.LoggedErrors.Count
}

function Add-WinUtilGuidedFailures {
    # Errors logged since -Since belong to the step that just ran, so the finish
    # screen can say which change failed and why.
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$Label,
        [int]$Since,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Failures
    )
    if ($null -eq $sync.LoggedErrors) { return }
    foreach ($entry in @($sync.LoggedErrors.ToArray() | Select-Object -Skip $Since)) {
        $message = ([string]$entry) -replace '^\[[^\]]*\]\s*', '' -replace '^Non-terminating error\s*:\s*', ''
        $Failures.Add([pscustomobject]@{ Step = $(if ($Label) { $Label } else { Get-WinUtilGuidedStepLabel -Key $Key }); Message = $message })
    }
}

function Invoke-WinUtilGuidedApply {
    $plan = $sync.GuidedPlan
    if (-not $plan -or @($plan.Items).Count -eq 0) { return }
    if ($sync.ActiveJob) {
        Show-WinUtilMessage -Message "$($sync.ActiveJob) sigue en curso. Espera a que termine antes de aplicar." -Title 'APBOptimizer' -Button 'OK' -Icon 'Warning' | Out-Null
        return
    }
    if (@($plan.AppxChanges).Count -gt 0) {
        $names = @($plan.AppxChanges | ForEach-Object { $_.Name }) -join ', '
        $choice = Show-WinUtilMessage -Title 'Confirmar desinstalación' -Button 'YesNo' -Icon 'Warning' -Message "Se desinstalarán las aplicaciones seleccionadas solo para este usuario: $names. Podrías perder sus datos y Deshacer no las reinstala. ¿Continuar?"
        if ($choice -ne 'Yes') { return }
    }

    $isSpanish = ((Get-WinUtilGuidedLanguage) -eq 'es')
    $sync.WPFGuidedDoneTitle.Text = if ($isSpanish) { 'Aplicando cambios...' } else { 'Applying changes...' }
    $sync.WPFGuidedDoneText.Text = if ($isSpanish) { 'Si algo falla, el resto continúa y queda registrado en el log.' } else { 'If something fails, the rest continues and it is written to the log.' }
    $sync.WPFGuidedDoneButtons.Visibility = 'Collapsed'
    $sync.WPFGuidedErrors.Visibility = 'Collapsed'
    $sync.WPFGuidedJobPanel.Visibility = 'Visible'
    $sync.WPFGuidedJobProgress.Value = 0
    $sync.WPFGuidedJobLabel.Text = ''
    Show-WinUtilGuidedPanel -Panel 'Done'
    $sync.GuidedState.Completed = $true

    Write-WinUtilLog -Component 'Guided' -Message "Guided apply requested: restore point $($plan.RestorePoint), power plan $($plan.PowerPlan), $(@($plan.Tweaks).Count) tweak(s), $(@($plan.Toggles).Count) toggle(s), $(@($plan.GroupChanges).Count) service change(s), $(@($plan.TaskChanges).Count) task change(s), $(@($plan.AppxChanges).Count) AppX removal(s)."

    Start-WinUtilJob -Name 'Guided' -Description 'Applying guided mode changes' -Parameters @{
        RestorePoint = [bool]$plan.RestorePoint
        PowerPlan = [bool]$plan.PowerPlan
        Tweaks = @($plan.Tweaks)
        Toggles = @($plan.Toggles)
        GroupChanges = @($plan.GroupChanges)
        TaskChanges = @($plan.TaskChanges)
        StartupChanges = @($plan.StartupChanges)
        AppxChanges = @($plan.AppxChanges)
        Reboot = [bool]$plan.Reboot
    } -ScriptBlock {
        param($RestorePoint, $PowerPlan, $Tweaks, $Toggles, $GroupChanges, $TaskChanges, $StartupChanges, $AppxChanges, $Reboot)

        $totalSteps = [Math]::Max(([int]$RestorePoint + [int]$PowerPlan + @($Tweaks).Count + @($Toggles).Count + @($GroupChanges).Count + @($TaskChanges).Count + @($StartupChanges).Count + @($AppxChanges).Count), 1)
        $completedSteps = 0
        $failures = [System.Collections.Generic.List[object]]::new()

        # The restore point has to be taken before anything else changes.
        if ($RestorePoint) {
            Step-WinUtilGuidedJob -Status 'Creating restore point' -Percent 0
            $errorMark = Get-WinUtilGuidedErrorMark
            Measure-WinUtilStep -Scope 'Guided' -Name 'WPFTweaksRestorePoint' -ScriptBlock {
                Invoke-WinUtilTweaks 'WPFTweaksRestorePoint'
            }
            Add-WinUtilGuidedFailures -Key 'WPFTweaksRestorePoint' -Since $errorMark -Failures $failures
            $completedSteps++
        }
        # Before the tweaks: the USB/PCIe power tweak writes to the active plan,
        # so the new plan has to be active first.
        if ($PowerPlan) {
            Step-WinUtilGuidedJob -Status "Applying WPFAddUltPerf ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            $errorMark = Get-WinUtilGuidedErrorMark
            Measure-WinUtilStep -Scope 'Guided' -Name 'WPFAddUltPerf' -ScriptBlock {
                try { Invoke-WPFUltimatePerformance -Enable } catch {
                    Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context 'Ultimate Performance plan'
                }
            }
            Add-WinUtilGuidedFailures -Key 'WPFAddUltPerf' -Since $errorMark -Failures $failures
            $completedSteps++
        }
        foreach ($change in @($StartupChanges)) {
            Step-WinUtilGuidedJob -Status "Startup: $($change.Name)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            $errorMark = Get-WinUtilGuidedErrorMark
            Invoke-WinUtilStartupChanges -Changes @($change)
            Add-WinUtilGuidedFailures -Key 'StartupApps' -Label $change.Name -Since $errorMark -Failures $failures
            $completedSteps++
        }
        foreach ($change in @($AppxChanges)) {
            Step-WinUtilGuidedJob -Status "Removing $($change.Name)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            $errorMark = Get-WinUtilGuidedErrorMark
            try {
                Invoke-WinUtilGuidedAppxRemoval -Changes @($change)
            } catch {
                Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'GuidedAppx' -Context "Remove $($change.Name)"
            }
            Add-WinUtilGuidedFailures -Key 'StoreApps' -Label $change.Name -Since $errorMark -Failures $failures
            $completedSteps++
        }
        foreach ($tweak in @($Tweaks)) {
            Step-WinUtilGuidedJob -Status "Applying $tweak ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            $errorMark = Get-WinUtilGuidedErrorMark
            Measure-WinUtilStep -Scope 'Guided' -Name $tweak -ScriptBlock {
                Invoke-WinUtilTweaks $tweak
            }
            Add-WinUtilGuidedFailures -Key $tweak -Since $errorMark -Failures $failures
            $completedSteps++
        }
        foreach ($toggle in @($Toggles)) {
            $key = [string]$toggle.Key
            $desired = [bool]$toggle.State
            Step-WinUtilGuidedJob -Status "Applying $key ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            $errorMark = Get-WinUtilGuidedErrorMark
            Measure-WinUtilStep -Scope 'Guided' -Name $key -ScriptBlock {
                # Only flip a switch that is not already in the chosen state.
                try {
                    if ([bool](Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache) -ne $desired) {
                        Invoke-WinUtilTweaks -CheckBox $key -undo (-not $desired)
                    }
                    if ($null -ne $sync.ToggleStatusCache) {
                        $sync.ToggleStatusCache[$key] = [bool](Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache)
                    }
                } catch {
                    Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context "Toggle $key"
                }
            }
            Add-WinUtilGuidedFailures -Key $key -Since $errorMark -Failures $failures
            $completedSteps++
        }
        foreach ($groupChange in @($GroupChanges)) {
            $key = [string]$groupChange.Key
            Step-WinUtilGuidedJob -Status "Applying service $key ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            $errorMark = Get-WinUtilGuidedErrorMark
            Measure-WinUtilStep -Scope 'Guided' -Name $key -ScriptBlock {
                Invoke-WinUtilPendingGroupChanges -Changes @($groupChange)
            }
            Add-WinUtilGuidedFailures -Key $key -Since $errorMark -Failures $failures
            $completedSteps++
        }
        if (@($TaskChanges).Count -gt 0) {
            # One scheduler read decides which tasks exist on this PC.
            $taskSnapshot = $null
            $errorMark = Get-WinUtilGuidedErrorMark
            try { $taskSnapshot = @(Get-ScheduledTask -ErrorAction Stop) } catch {
                Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context 'Read scheduled tasks'
            }
            Add-WinUtilGuidedFailures -Key 'WPFTaskGroupTelemetry' -Since $errorMark -Failures $failures
        }
        foreach ($taskChange in @($TaskChanges)) {
            $key = [string]$taskChange.Key
            Step-WinUtilGuidedJob -Status "Applying task $key ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            if ($null -ne $taskSnapshot) {
                $errorMark = Get-WinUtilGuidedErrorMark
                Measure-WinUtilStep -Scope 'Guided' -Name $key -ScriptBlock {
                    try {
                        $taskName = $sync.configs.tweaks.$key.scheduledTask.Name
                        $info = Get-WinUtilTelemetryTaskInfo -Name $taskName -TaskSnapshot $taskSnapshot
                        if ($info.Present) {
                            Invoke-WinUtilPendingTaskChanges -Changes @($taskChange)
                        } else {
                            Write-WinUtilLog -Component 'Guided' -Message "Scheduled task '$taskName' is not on this PC. Skipping."
                        }
                    } catch {
                        Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context "Task $key"
                    }
                }
                Add-WinUtilGuidedFailures -Key $key -Since $errorMark -Failures $failures
            }
            $completedSteps++
        }

        if (Test-WinUtilUIAlive) {
            Invoke-WPFUIThread -Parameters @{ Errors = [int]$global:WinUtilJobErrorCount; Reboot = [bool]$Reboot; Failures = @($failures) } -ScriptBlock {
                param($Errors, $Reboot, $Failures)
                Complete-WinUtilGuidedApply -Errors $Errors -Reboot $Reboot -Failures $Failures
            }
        }
    }
}

function Complete-WinUtilGuidedApply {
    param([int]$Errors, [bool]$Reboot, [object[]]$Failures = @())
    $isSpanish = ((Get-WinUtilGuidedLanguage) -eq 'es')
    $sync.WPFGuidedDoneTitle.Text = if ($Errors -gt 0) {
        if ($isSpanish) { "Terminado con $Errors error(es)" } else { "Finished with $Errors error(s)" }
    } elseif ($isSpanish) { 'Listo: cambios aplicados' } else { 'Done: changes applied' }
    $lines = @()
    if ($Errors -gt 0) {
        $lines += if (@($Failures).Count -gt 0) {
            if ($isSpanish) { 'Algunos cambios no se pudieron aplicar; el resto sí. Abajo está cada error.' } else { 'Some changes could not be applied; the rest were. Each error is listed below.' }
        } elseif ($isSpanish) { 'Algunos cambios no se pudieron aplicar; el resto sí. El log indica cuáles y por qué.' } else { 'Some changes could not be applied; the rest were. The log says which ones and why.' }
    }
    $lines += if ($Reboot) {
        if ($isSpanish) { 'Reinicia Windows para terminar de aplicar algunos cambios.' } else { 'Restart Windows to finish applying some changes.' }
    } elseif ($isSpanish) { 'Los cambios ya están activos.' } else { 'The changes are already active.' }
    $sync.WPFGuidedDoneText.Text = $lines -join ' '
    $sync.WPFGuidedErrorsList.Children.Clear()
    foreach ($failure in @($Failures)) {
        $row = New-Object Windows.Controls.TextBlock
        $row.TextWrapping = 'Wrap'
        $row.FontSize = 13
        $row.Margin = '0,0,0,8'
        $row.Background = [Windows.Media.Brushes]::Transparent
        $row.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MainForegroundColor')
        $stepRun = New-Object Windows.Documents.Run -ArgumentList (Convert-WinUtilTextEncoding -Text ([string]$failure.Step))
        $stepRun.FontWeight = 'Bold'
        $row.Inlines.Add($stepRun) | Out-Null
        $row.Inlines.Add((New-Object Windows.Documents.LineBreak)) | Out-Null
        $row.Inlines.Add((New-Object Windows.Documents.Run -ArgumentList (Convert-WinUtilTextEncoding -Text ([string]$failure.Message)))) | Out-Null
        $sync.WPFGuidedErrorsList.Children.Add($row) | Out-Null
    }
    $sync.WPFGuidedErrors.Visibility = if (@($Failures).Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $sync.WPFGuidedJobProgress.Value = 100
    $sync.WPFGuidedJobPanel.Visibility = 'Collapsed'
    $sync.WPFGuidedDoneAdvanced.Content = if ($isSpanish) { 'Ir al modo avanzado' } else { 'Go to advanced mode' }
    $sync.WPFGuidedDoneHome.Content = if ($isSpanish) { 'Volver al inicio' } else { 'Back to start' }
    $sync.WPFGuidedRestart.Content = if ($isSpanish) { 'Reiniciar ahora' } else { 'Restart now' }
    $sync.WPFGuidedRestart.Visibility = if ($Reboot) { 'Visible' } else { 'Collapsed' }
    $sync.WPFGuidedDoneButtons.Visibility = 'Visible'

    # Redraw the Tweaks tab from the new state; import mode keeps the redraw
    # from re-running any toggle.
    if ($sync.InitializedTabs -and $sync.InitializedTabs['Tweaks']) {
        $wasImporting = $sync.ImportInProgress
        $sync.ImportInProgress = $true
        try {
            Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName 'tweakspanel' -columncount 2
            Reset-WPFCheckBoxes -doToggles $true
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        } catch {
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context 'Refresh Tweaks tab'
        } finally { $sync.ImportInProgress = $wasImporting }
    }
}

function Restart-WinUtilComputer {
    $message = if ((Get-WinUtilGuidedLanguage) -eq 'es') {
        'Windows se reiniciará ahora. Guarda tu trabajo y cierra los programas abiertos antes de continuar. ¿Reiniciar?'
    } else { 'Windows will restart now. Save your work and close open programs before continuing. Restart?' }
    if ([string](Show-WinUtilMessage -Title 'APBOptimizer' -Message (Convert-WinUtilTextEncoding -Text $message) -Button 'YesNo' -Icon 'Warning') -ne 'Yes') { return }
    Write-WinUtilLog -Component 'Guided' -Message 'Restart requested from guided mode.'
    Restart-Computer -Force
}
