#Requires -Version 7.2
<#
.SYNOPSIS
    Hourly orchestrator (scheduled at HH:05 UTC).
      1. DaaS REST (reference data)      4. Windows servers (connectors / FAS / App-V)
      2. Monitor OData (current + late-data refresh of the previous hour)
      3. AWS CloudWatch / EC2            5. Capacity forecast   6. Daily rollup + retention (00:xx only)
    Each step is isolated: a failure is logged to mon.CollectorRun and the run continues.
#>
param([switch]$SkipLateDataRefresh)

Import-Module (Join-Path $PSScriptRoot 'CitrixMon.Common.psm1') -Force
$cfg = Get-MonConfig
$w   = Get-HourWindow

$null = Invoke-CollectorJob 'Hourly:DaasRest-Ref' { & (Join-Path $PSScriptRoot 'Collect-CitrixDaasRest.ps1') }
$null = Invoke-CollectorJob 'Hourly:OData'        { & (Join-Path $PSScriptRoot 'Collect-CitrixMonitorOData.ps1') }
if (-not $SkipLateDataRefresh) {
    $null = Invoke-CollectorJob 'Hourly:OData-Late' { & (Join-Path $PSScriptRoot 'Collect-CitrixMonitorOData.ps1') -HoursBack 1 }
}
$null = Invoke-CollectorJob 'Hourly:DaasRest'     { & (Join-Path $PSScriptRoot 'Collect-CitrixDaasRest.ps1') }   # dereg reasons onto fresh VDAHealth rows
$null = Invoke-CollectorJob 'Hourly:AWS'          { & (Join-Path $PSScriptRoot 'Collect-AwsCloudWatch.ps1') }
$null = Invoke-CollectorJob 'Hourly:Windows'      { & (Join-Path $PSScriptRoot 'Collect-WindowsHealth.ps1') -Mode Hourly }

# ---------- Capacity forecast (design section 6.7) ----------
$null = Invoke-CollectorJob 'Hourly:Forecast' {
    $hist = (Invoke-MonSql @'
SELECT HourUtc, ActiveSessions + DisconnectedSessions AS S
FROM mon.HourlySessionSummary
WHERE DeliveryGroupId = '00000000-0000-0000-0000-000000000000' AND HourUtc >= DATEADD(DAY, -29, @h) AND HourUtc <= @h
'@ @{ h = $w.Hour }).Rows
    $byHour = @{}; foreach ($r in $hist) { $byHour[([datetime]$r.HourUtc).ToString('s')] = [double]$r.S }

    $slots = (Invoke-MonSql @'
SELECT
  (SELECT COALESCE(SUM(MaxSessions),0) FROM mon.VDAHealth WHERE HourUtc=@h AND RegistrationState='Registered' AND InMaintenance=0 AND PowerState='On') AS SlotsNow,
  (SELECT COALESCE(SUM(CAST(AutoscaleMaxMachines AS BIGINT) * MaxSessionsPerVda),0) FROM mon.DeliveryGroup WHERE AutoscaleMaxMachines IS NOT NULL) AS SlotsMaxCfg,
  (SELECT COALESCE(SUM(MaxSessions),0) FROM mon.VDAHealth v JOIN mon.DeliveryGroup d ON d.DeliveryGroupId=v.DeliveryGroupId
     WHERE v.HourUtc=@h AND v.RegistrationState='Registered' AND v.InMaintenance=0 AND v.PowerState='On' AND d.AutoscaleMaxMachines IS NULL) AS SlotsNoAutoscale
'@ @{ h = $w.Hour }).Rows[0]
    $slotsNow = [int]$slots.SlotsNow
    $slotsMax = [math]::Max($slotsNow, [int]$slots.SlotsMaxCfg + [int]$slots.SlotsNoAutoscale)

    function Baseline([datetime]$t) {
        # Median of the same weekday+hour over the previous 4 weeks
        $v = @(1..4 | ForEach-Object { $byHour[$t.AddDays(-7 * $_).ToString('s')] } | Where-Object { $null -ne $_ })
        if ($v.Count) { Get-Percentile $v 50 } else { $null }
    }
    # Today-vs-normal ratio from the last 3 hours
    $ratios = @(0..2 | ForEach-Object {
        $t = $w.Hour.AddHours(-$_); $b = Baseline $t; $a = $byHour[$t.ToString('s')]
        if ($b -and $null -ne $a) { $a / $b } })
    $trend = if ($ratios.Count) { [math]::Min(2.0, [math]::Max(0.5, (Get-Avg $ratios))) } else { 1.0 }

    $rows = @(); $exhaust = $null; $peak = 0; $peakAt = $null
    foreach ($k in 1..24) {
        $t = $w.Hour.AddHours($k)
        $b = Baseline $t
        if ($null -eq $b) { $b = $byHour[$w.Hour.ToString('s')] }   # not enough history: flat-line current
        if ($null -eq $b) { continue }
        $f = $b * $trend
        $rows += @{ RunHourUtc = $w.Hour; ForecastHourUtc = $t; ForecastSessions = $f; SlotsNow = $slotsNow; SlotsAtAutoscaleMax = $slotsMax }
        if ($f -gt $peak) { $peak = $f; $peakAt = $t }
        if ($null -eq $exhaust -and $slotsMax -gt 0 -and $f -gt 0.95 * $slotsMax) { $exhaust = $k }
    }
    Write-MonRows -Table 'mon.CapacityForecast' -Rows $rows -DeleteWhere 'RunHourUtc=@h' -DeleteParameters @{ h = $w.Hour }

    $maxPerVda = [int]$cfg.DefaultMaxSessionsPerVda
    $rec = if ($null -ne $exhaust -and $exhaust -lt 8) {
        $need = [math]::Ceiling(($peak - 0.9 * $slotsMax) / $maxPerVda)
        "Raise Autoscale max / power on ~$need additional VDAs before $($w.Hour.AddHours($exhaust).ToString('HH:mm')) UTC (forecast peak $([int]$peak) sessions at $($peakAt.ToString('HH:mm')) UTC vs $slotsMax slots)."
    } elseif ($slotsMax -gt 0 -and $peak -lt 0.4 * $slotsMax) {
        "Forecast peak $([int]$peak) sessions is under 40% of $slotsMax slots - review Autoscale minimums for cost."
    } else { "Capacity sufficient: forecast peak $([int]$peak) of $slotsMax slots." }
    $hoursVal = if ($null -ne $exhaust) { [double]$exhaust } else { $null }
    $st = if ($null -eq $exhaust) { 'Green' } else { Get-RagStatus 'HoursToExhaustion' $hoursVal }
    Write-HealthCheck -Component 'VDAFleet' -Scope 'All' -CheckName 'HoursToExhaustion' -Status $st -ValueNum $hoursVal -Detail $rec
}

# ---------- Daily jobs ----------
if ([datetime]::UtcNow.Hour -eq 0) {
    $null = Invoke-CollectorJob 'Daily:ExecRollup' {
        Invoke-MonSql 'EXEC mon.usp_BuildExecutiveDailyRollup @d' @{ d = [datetime]::UtcNow.Date.AddDays(-1) } -NonQuery | Out-Null
    }
    $null = Invoke-CollectorJob 'Daily:Retention' { Invoke-MonSql 'EXEC mon.usp_PurgeRetention' -NonQuery | Out-Null }
}

$null = Invoke-CollectorJob 'Hourly:Alerts' { & (Join-Path $PSScriptRoot 'Invoke-AlertEvaluation.ps1') }
Write-MonLog ("Hourly run for {0:u} finished" -f $w.Hour)
