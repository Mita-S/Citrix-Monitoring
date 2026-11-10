#Requires -Version 7.2
<#
.SYNOPSIS
    Hourly Citrix DaaS (CVAD Manage) REST collection:
      - mon.DeliveryGroup reference (with capacity settings from config)
      - VDAHealth.LastDeregReason enrichment
      - Published-application and delivery-group configuration checks -> mon.HealthCheck
    Run AFTER Collect-CitrixMonitorOData.ps1 for the same hour.
#>
param([int]$HoursBack = 0)

Import-Module (Join-Path $PSScriptRoot 'CitrixMon.Common.psm1') -Force
$cfg = Get-MonConfig
$w   = Get-HourWindow -HoursBack $HoursBack

# ---------- Delivery groups ----------
$dgs   = Get-CitrixRest 'DeliveryGroups'
$dgCfg = @{}; foreach ($d in $cfg.DeliveryGroups) { $dgCfg[$d.Name] = $d }
$rows = foreach ($d in $dgs) {
    $c = $dgCfg[$d.Name]
    @{
        DeliveryGroupId      = [guid]$d.Id
        Name                 = $d.Name
        MaxSessionsPerVda    = if ($c) { $c.MaxSessionsPerVda } else { $cfg.DefaultMaxSessionsPerVda }
        AutoscaleMaxMachines = if ($c) { $c.AutoscaleMaxMachines } else { $null }
        IsCritical           = if ($c) { [bool]$c.IsCritical } else { $false }
        UpdatedUtc           = [datetime]::UtcNow
    }
    if (-not $d.Enabled -or $d.InMaintenanceMode) {
        Write-HealthCheck -Component 'VDAFleet' -Scope $d.Name -CheckName 'DeliveryGroupState' -Status 'Yellow' `
            -Detail "Enabled=$($d.Enabled) InMaintenanceMode=$($d.InMaintenanceMode)"
    }
}
Write-MonRows -Table 'mon.DeliveryGroup' -Rows $rows -DeleteWhere '1=1'

$unknownDg = @($dgs | Where-Object { -not $dgCfg.ContainsKey($_.Name) } | ForEach-Object Name)
if ($unknownDg) { Write-MonLog "Delivery groups missing from settings.json (using DefaultMaxSessionsPerVda): $($unknownDg -join ', ')" 'WARN' }

# ---------- Machines: deregistration reason, cross-check with OData ----------
$machines = Get-CitrixRest 'Machines'
foreach ($m in $machines | Where-Object { $_.RegistrationState -ne 'Registered' -and $_.LastDeregistrationReason }) {
    Invoke-MonSql 'UPDATE mon.VDAHealth SET LastDeregReason=@r WHERE HourUtc=@h AND MachineName=@n' `
        @{ r = [string]$m.LastDeregistrationReason; h = $w.Hour; n = $m.Name } -NonQuery | Out-Null
}

# ---------- Published applications ----------
$apps = Get-CitrixRest 'Applications'
$disabled = @($apps | Where-Object { -not $_.Enabled })
Write-HealthCheck -Component 'VDAFleet' -Scope 'PublishedApps' -CheckName 'DisabledApps' -ValueNum $disabled.Count `
    -Status $(if ($disabled.Count) { 'Yellow' } else { 'Green' }) -Detail (($disabled | Select-Object -First 20 -ExpandProperty Name) -join ', ')

Write-MonLog "REST: $(@($dgs).Count) delivery groups, $(@($machines).Count) machines, $(@($apps).Count) apps ($($disabled.Count) disabled)"
