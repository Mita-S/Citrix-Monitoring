#Requires -Version 7.2
<#
.SYNOPSIS
    5-minute availability checks (the alert fast path), then alert evaluation.
    Keeps API usage small: counts and point-in-time state only.
#>
Import-Module (Join-Path $PSScriptRoot 'CitrixMon.Common.psm1') -Force
$cfg = Get-MonConfig

Invoke-CollectorJob 'Fast:ControlPlane' {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Invoke-CitrixApi -Uri "$($cfg.Citrix.ApiBase)/cvad/manage/me" -NoInstanceId -MaxRetry 1
        $ms = $sw.ElapsedMilliseconds
        Write-HealthCheck -Component 'ControlPlane' -Scope 'CvadApi' -CheckName 'Reachable' -ValueNum $ms -Status (Get-RagStatus 'EndpointLatencyMs' $ms)
    } catch {
        Write-HealthCheck -Component 'ControlPlane' -Scope 'CvadApi' -CheckName 'Reachable' -Status 'Red' -Detail $_.Exception.Message
        throw
    }
}

Invoke-CollectorJob 'Fast:CitrixStatus' {
    # Heuristic: any feed item in the last 6 h without "resolved"/"completed" counts as an active incident.
    # Tune to the feed format your tenant's status page publishes (design gap: status feed).
    $feed  = [xml](Invoke-WebRequest -Uri $cfg.Citrix.StatusFeedUrl -TimeoutSec 20).Content
    $items = @($feed.rss.channel.item | Where-Object { [datetime]$_.pubDate -gt (Get-Date).AddHours(-6) })
    $active = @($items | Where-Object { "$($_.title) $($_.description)" -notmatch 'resolved|completed' })
    $major  = @($active | Where-Object { "$($_.title) $($_.description)" -match 'outage|unavailable|major' })
    $st = if ($major) { 'Red' } elseif ($active) { 'Yellow' } else { 'Green' }
    Write-HealthCheck -Component 'CitrixStatus' -Scope 'status.cloud.com' -CheckName 'ActiveIncidents' -Status $st -ValueNum $active.Count `
        -Detail (($active | Select-Object -First 3 -ExpandProperty title) -join ' | ')
}

Invoke-CollectorJob 'Fast:VDAFleet' {
    $machines = Get-CitrixOData 'Machines?$filter=LifecycleState eq 0&$select=Id,Name,DesktopGroupId,CurrentRegistrationState,IsInMaintenanceMode,CurrentPowerState,CurrentSessionCount'
    $usable   = @($machines | Where-Object { $_.CurrentPowerState -eq 3 -and -not $_.IsInMaintenanceMode })
    $reg      = @($usable | Where-Object CurrentRegistrationState -eq 1)
    $regPct   = if ($usable.Count) { 100.0 * $reg.Count / $usable.Count } else { $null }
    $sessions = ($machines | Measure-Object CurrentSessionCount -Sum).Sum

    $dgMax = @{}; foreach ($r in (Invoke-MonSql 'SELECT DeliveryGroupId, MaxSessionsPerVda FROM mon.DeliveryGroup').Rows) { $dgMax[[string]$r.DeliveryGroupId] = $r.MaxSessionsPerVda }
    $slots = 0; foreach ($m in $reg) { $mx = $dgMax[[string]$m.DesktopGroupId]; $slots += $(if ($mx -is [int]) { $mx } else { $cfg.DefaultMaxSessionsPerVda }) }
    $capPct = if ($slots) { 100.0 * $sessions / $slots } else { $null }

    # Newly unregistered vs. the previous check
    $prev = (Invoke-MonSql "SELECT TOP 1 ValueNum FROM mon.HealthCheck WHERE Component='VDAFleet' AND CheckName='Unregistered' ORDER BY CheckUtc DESC").Rows
    $unreg = $usable.Count - $reg.Count
    $delta = if ($prev.Count -and $prev[0].ValueNum -isnot [DBNull]) { $unreg - [int]$prev[0].ValueNum } else { 0 }

    Write-HealthCheck -Component 'VDAFleet' -Scope 'All' -CheckName 'RegisteredPct' -ValueNum $regPct -Status (Get-RagStatus 'VdaRegisteredPct' $regPct) `
        -Detail "$($reg.Count)/$($usable.Count) registered; unregistered: $((@($usable | Where-Object CurrentRegistrationState -ne 1 | Select-Object -First 10 -ExpandProperty Name)) -join ', ')"
    Write-HealthCheck -Component 'VDAFleet' -Scope 'All' -CheckName 'Unregistered' -ValueNum $unreg -Status (Get-RagStatus 'VdaNewlyUnregistered15m' $delta) -Detail "Change since last check: $delta"
    Write-HealthCheck -Component 'VDAFleet' -Scope 'All' -CheckName 'Sessions' -ValueNum $sessions -Status 'Green'
    Write-HealthCheck -Component 'VDAFleet' -Scope 'All' -CheckName 'CapacityPct' -ValueNum $capPct -Status (Get-RagStatus 'CapacityPct' $capPct) -Detail "$sessions sessions / $slots slots"
}

Invoke-CollectorJob 'Fast:Logons' {
    $s = ConvertTo-ODataDate ([datetime]::UtcNow.AddMinutes(-15))
    $ok   = Get-CitrixODataCount -Entity 'Sessions' -Filter "StartDate ge $s and LogOnDuration ne null"
    $fail = @(Get-CitrixOData "ConnectionFailureLogs?`$filter=FailureDate ge $s&`$select=SessionKey").Count
    $att  = $ok + $fail
    $pct  = if ($att) { 100.0 * $ok / $att } else { $null }
    Write-HealthCheck -Component 'UserExperience' -Scope 'All' -CheckName 'LogonSuccess15m' -ValueNum $pct `
        -Status (Get-RagStatus 'LogonSuccessPct' $pct -Volume $att) -Detail "$fail failures / $att attempts (15 min)"
}

Invoke-CollectorJob 'Fast:Windows'   { & (Join-Path $PSScriptRoot 'Collect-WindowsHealth.ps1') -Mode Fast }
Invoke-CollectorJob 'Fast:Synthetic' {
    & (Join-Path $PSScriptRoot 'Invoke-SyntheticTests.ps1') -Action Run
    & (Join-Path $PSScriptRoot 'Invoke-SyntheticTests.ps1') -Action Import
}
Invoke-CollectorJob 'Fast:Alerts'    { & (Join-Path $PSScriptRoot 'Invoke-AlertEvaluation.ps1') }

# Heartbeat for the CloudWatch watchdog alarm (missing data => monitoring is down)
try {
    Import-Module AWS.Tools.CloudWatch -ErrorAction Stop
    Write-CWMetricData -Region $cfg.Aws.Region -Namespace 'CitrixMon' -MetricData @{ MetricName = 'CollectorHeartbeat'; Value = 1; Unit = 'Count' }
} catch { Write-MonLog "Heartbeat publish failed: $($_.Exception.Message)" 'WARN' }
