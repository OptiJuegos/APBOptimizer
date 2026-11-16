function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  param([switch]$IncludeToggles)

  $Tweaks = @($sync.selectedTweaks)
  if ($IncludeToggles) {
    $Tweaks = @(@($Tweaks) + @($sync.selectedToggles) | Select-Object -Unique)
  }
  $TaskChanges = @()
  $GroupChanges = @()
  $StartupChanges = @()
  if ($sync.Form) {
    # Grouped services, drivers and tasks are diffed against their actual
    # state. Generic processing would duplicate them and miss queued restores.
    $Tweaks = @($Tweaks | Where-Object {
      $parent = $sync.configs.tweaks.$_.ParentGroup
      $parent -notin @('WPFServiceGroupDiagnostics', 'WPFServiceGroupUseless', 'WPFDriverGroupOptional', 'WPFTaskGroupTelemetry')
    })
    $TaskChanges = @(Get-WinUtilPendingTaskChanges)
    $GroupChanges = @(Get-WinUtilPendingGroupChanges)
    if ($sync.PendingStartupChanges) { $StartupChanges = @(Get-WinUtilPendingStartupChanges) }
  }
  $dnsProvider = if ($sync["WPFchangedns"].SelectedItem -and $sync["WPFchangedns"].SelectedItem.Tag) {
    [string]$sync["WPFchangedns"].SelectedItem.Tag
  } else {
    $sync["WPFchangedns"].Text
  }
  if (-not ($dnsProvider)) {
    $dnsProvider = "Default"
  }

  if ($Tweaks.count -eq 0 -and $TaskChanges.Count -eq 0 -and $GroupChanges.Count -eq 0 -and $StartupChanges.Count -eq 0 -and $dnsProvider -eq "Default") {
    $emptySelectionMessage = if ($sync.Language -eq 'es') { 'Selecciona los ajustes que quieres aplicar.' } else { 'Please check the tweaks you wish to perform.' }
    Show-WinUtilMessage -Message $emptySelectionMessage -Title "APBOptimizer" -Button "OK" -Icon "Warning"
    return
  }

  $driverDisables = @($GroupChanges | Where-Object {
    $_.Disable -and $sync.configs.tweaks.$($_.Key).ParentGroup -eq 'WPFDriverGroupOptional'
  })
  if ($driverDisables.Count -gt 0) {
    $driverNames = @($driverDisables | ForEach-Object { $sync.configs.tweaks.$($_.Key).driver.Name }) -join ', '
    $warning = if ($sync.Language -eq 'es') {
      "Vas a desactivar $($driverDisables.Count) driver(s) del kernel: $driverNames. Puede afectar DRM, red o funciones de energia. Se aplicara al reiniciar Windows. APBOptimizer guardara sus estados originales. ¿Continuar?"
    } else {
      "You are about to disable $($driverDisables.Count) kernel driver(s): $driverNames. This may affect DRM, networking or power features, and requires a reboot. APBOptimizer will back up their original states. Continue?"
    }
    $confirmation = Show-WinUtilMessage -Title 'APBOptimizer - Drivers' -Message $warning -Icon 'Warning' -Button 'YesNo'
    if ([string]$confirmation -ne 'Yes') { return }
  }

  if ($sync.Form -and $Tweaks -contains 'WPFTweaksDisableMemoryIntegrity') {
    $warning = if ($sync.Language -eq 'es') {
      'Desactivar Integridad de memoria (HVCI) reduce la seguridad del nucleo de Windows frente a malware y drivers maliciosos. No desactiva todo VBS. Necesitaras reiniciar para que el cambio tenga efecto. ¿Continuar?'
    } else {
      'Disabling Memory integrity (HVCI) reduces Windows kernel protection against malicious software and drivers. It does not disable all VBS. A reboot is required. Continue?'
    }
    if ([string](Show-WinUtilMessage -Title 'APBOptimizer - Memory Integrity' -Message $warning -Icon 'Warning' -Button 'YesNo') -ne 'Yes') { return }
  }

  if ($sync.Form -and $Tweaks -contains 'WPFTweaksDisablePowerThrottling') {
    $warning = if ($sync.Language -eq 'es') {
      'Desactivar Power Throttling en todo Windows puede aumentar el consumo, la temperatura y el uso de bateria. La mejora de rendimiento no esta garantizada. Se recomienda reiniciar. ¿Continuar?'
    } else {
      'Disabling Power Throttling system-wide may increase power draw, temperatures and battery drain. Performance gains are not guaranteed. Restarting is recommended. Continue?'
    }
    if ([string](Show-WinUtilMessage -Title 'APBOptimizer - Power Throttling' -Message $warning -Icon 'Warning' -Button 'YesNo') -ne 'Yes') { return }
  }

  if ($sync.Form -and $Tweaks -contains 'WPFTweaksDisableCPUMitigations') {
    $warning = if ($sync.Language -eq 'es') {
      'Desactivar las mitigaciones de CPU (Spectre/Meltdown) reduce la seguridad de Windows frente a ataques que pueden filtrar datos entre procesos. No garantiza mejores FPS. Es necesario reiniciar Windows para aplicar el cambio. APBOptimizer guardara los valores originales para Deshacer. ¿Continuar?'
    } else {
      'Disabling CPU mitigations (Spectre/Meltdown) weakens Windows protection against attacks that may leak data across processes. FPS gains are not guaranteed. Windows must be restarted. APBOptimizer will save the original settings for Undo. Continue?'
    }
    if ([string](Show-WinUtilMessage -Title 'APBOptimizer - CPU Mitigations' -Message $warning -Icon 'Warning' -Button 'YesNo') -ne 'Yes') { return }
  }

  if ($sync.Form -and $Tweaks -contains 'WPFTweaksDeBloat') {
    $warning = if ($sync.Language -eq 'es') {
      'ATENCION: se eliminaran numerosas aplicaciones de Microsoft Store de todos los usuarios y se quitara su aprovisionamiento para nuevas cuentas. La lista incluye Minecraft Bedrock, Gaming Services y aplicaciones instaladas por el usuario. Puedes perder datos de apps y juegos. NO existe restauracion automatica desde APBOptimizer; tendras que reinstalarlas manualmente. ¿Quieres continuar?'
    } else {
      'WARNING: This removes many Microsoft Store apps for all users and deprovisions them for new accounts. The list includes Minecraft Bedrock, Gaming Services and user-installed apps. App and game data may be lost. APBOptimizer CANNOT automatically undo this; you must reinstall affected apps manually. Continue?'
    }
    if ([string](Show-WinUtilMessage -Title 'APBOptimizer - MS Store Apps' -Message $warning -Icon 'Warning' -Button 'YesNo') -ne 'Yes') { return }
  }

  Write-WinUtilLog -Component "Tweaks" -Message "Tweaks requested: $(@($Tweaks).Count) tweak(s), $($TaskChanges.Count) scheduled-task change(s), $($GroupChanges.Count) service/driver change(s), DNS provider: $dnsProvider"

  Start-WinUtilJob -Name "Tweaks" -Description "Applying tweaks" -Parameters @{
    Tweaks = @($Tweaks)
    DnsProvider = $dnsProvider
    TaskChanges = @($TaskChanges)
    GroupChanges = @($GroupChanges)
    StartupChanges = @($StartupChanges)
  } -ScriptBlock {
    param($Tweaks, $DnsProvider, $TaskChanges, $GroupChanges, $StartupChanges)

    # The restore point has to be taken before anything else changes
    $restorePointTweak = "WPFTweaksRestorePoint"
    $tweaksToRun = @($Tweaks | Where-Object { $_ -ne $restorePointTweak })
    $totalSteps = [Math]::Max((@($Tweaks).Count + @($TaskChanges).Count + @($GroupChanges).Count + @($StartupChanges).Count), 1)
    $completedSteps = 0

    if ($Tweaks -contains $restorePointTweak) {
      Step-WinUtilJob -Status "Creating restore point" -Percent 0
      Write-WinUtilLog -Component "Tweaks" -Message "Creating restore point before applying selected tweaks."
      Measure-WinUtilStep -Scope "Tweaks" -Name $restorePointTweak -ScriptBlock {
        Invoke-WinUtilTweaks $restorePointTweak
      }
      $completedSteps = 1
    }

    if ($DnsProvider -ne "Default") {
      $dnsResult = Measure-WinUtilStep -Scope "Tweaks" -Name "Set DNS to $DnsProvider" -ScriptBlock {
        @(Set-WinUtilDNS -DNSProvider $DnsProvider)
      }

      # Carrying on after the DNS change failed leaves the machine half configured, so the run
      # ends here and the job layer reports it
      if (@($dnsResult)[-1] -ne $true) {
        throw "The DNS change to $DnsProvider failed, so the remaining tweaks were not applied."
      }
    }

    foreach ($change in @($StartupChanges)) {
      Step-WinUtilJob -Status "Startup: $($change.Name)" -Percent ([int](($completedSteps / $totalSteps) * 100))
      Invoke-WinUtilStartupChanges -Changes @($change)
      $completedSteps++
    }
    foreach ($tweak in $tweaksToRun) {
      Step-WinUtilJob -Status "Applying $tweak ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
      Measure-WinUtilStep -Scope "Tweaks" -Name $tweak -ScriptBlock {
        Invoke-WinUtilTweaks $tweak
      }
      $completedSteps++
      Step-WinUtilJob -Percent ([int](($completedSteps / $totalSteps) * 100))
    }
    foreach ($taskChange in @($TaskChanges)) {
      $key = [string]$taskChange.Key
      Step-WinUtilJob -Status "Applying scheduled task $key ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
      Measure-WinUtilStep -Scope "Tweaks" -Name $key -ScriptBlock {
        Invoke-WinUtilPendingTaskChanges -Changes @($taskChange)
      }
      $completedSteps++
      Step-WinUtilJob -Percent ([int](($completedSteps / $totalSteps) * 100))
    }
    foreach ($groupChange in @($GroupChanges)) {
      $key = [string]$groupChange.Key
      Step-WinUtilJob -Status "Applying service/driver $key ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
      Measure-WinUtilStep -Scope "Tweaks" -Name $key -ScriptBlock {
        Invoke-WinUtilPendingGroupChanges -Changes @($groupChange)
      }
      $completedSteps++
      Step-WinUtilJob -Percent ([int](($completedSteps / $totalSteps) * 100))
    }
    if (Test-WinUtilUIAlive) {
      Update-WinUtilServiceGroupState
    }
  }
}
