#Requires -Version 7.2
<#
.SYNOPSIS
    Evaluates alert rules (design section 3) against mon.HealthCheck and the hourly tables,
    reconciles with open alerts in mon.AlertHistory, notifies Teams / PagerDuty, and writes
    the Overall + per-component status used by the executive banner and health matrix.
#>
Import-Module (Join-Path $PSScriptRoot 'CitrixMon.Common.psm1') -Force
$cfg   = Get-MonConfig
$now   = [datetime]::UtcNow
$found = [System.Collections.Generic.List[hashtable]]::new()

#region Helpers
function Get-Latest([string]$Component, [string]$CheckName, [int]$N = 2, [int]$MaxAgeMin = 20) {
    <# Latest N checks per Scope, newest first, as @{ Scope = @(rows) } #>
    $dt = Invoke-MonSql @'
SELECT Scope, CheckUtc, Status, ValueNum, Detail FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY Scope ORDER BY CheckUtc DESC) rn
  FROM mon.HealthCheck WHERE Component=@c AND CheckName=@n AND CheckUtc >= DATEADD(MINUTE, -@age, SYSUTCDATETIME())) x
WHERE rn <= @k ORDER BY Scope, CheckUtc DESC
'@ @{ c = $Component; n = $CheckName; k = $N; age = $MaxAgeMin }
    $h = @{}; foreach ($r in $dt.Rows) { if (-not $h[$r.Scope]) { $h[$r.Scope] = @() }; $h[$r.Scope] += $r }
    $h
}
function All-Status($rows, [string]$Status) { $rows.Count -gt 0 -and @($rows | Where-Object Status -ne $Status).Count -eq 0 }
function Num($v) { if ($v -is [DBNull] -or $null -eq $v) { $null } else { [double]$v } }

function Add-Alert {
    param([string]$Id, [ValidateSet('Informational', 'Warning', 'Critical')][string]$Severity, [string]$Component, [string]$Scope,
          [string]$Owner, [string]$Title, [string]$Detail, [string]$Impact, [string]$Runbook, $AffectedUsers = $null)
    $found.Add(@{ AlertId = $Id; Severity = $Severity; Component = $Component; Scope = $Scope; Owner = $Owner; Title = $Title
                  Detail = $Detail; ExecImpact = $Impact; RunbookAction = $Runbook; AffectedUsers = $AffectedUsers })
}

function Resolve-Owner {
    <# Lowest unhealthy layer wins (design section 0). #>
    $red = { param($c) (Invoke-MonSql "SELECT COUNT(*) n FROM mon.HealthCheck WHERE Component=@c AND Status='Red' AND CheckUtc >= DATEADD(MINUTE,-15,SYSUTCDATETIME())" @{ c = $c }).Rows[0].n -gt 0 }
    if (& $red 'AWS')            { return 'AWS' }
    if (& $red 'CloudConnector') { return 'CTX-INFRA' }
    if (& $red 'FAS')            { return 'CTX-INFRA' }
    if (& $red 'VDAFleet')       { return 'CTX-INFRA' }
    $cs = Get-Latest 'CitrixStatus' 'ActiveIncidents' 1
    if ($cs.Values | ForEach-Object { $_ } | Where-Object Status -ne 'Green') { return 'CITRIX' }
    if (& $red 'ControlPlane')   { return 'CITRIX' }
    'CTX-INFRA'
}
#endregion

#region Rules - fast path (HealthCheck)
# ALR-01 / 01b - external connectivity via GWaaS (synthetics)
$syn = Get-Latest 'Synthetic' 'Reachability' 2
$ext = @($syn.Keys | Where-Object { $_ -like '*|External' })
$extDown = @($ext | Where-Object { All-Status $syn[$_] 'Red' -and $syn[$_].Count -ge 2 })
if ($ext.Count -ge 2 -and $extDown.Count -ge 2) {
    Add-Alert 'ALR-01' Critical 'GWaaS' 'External' 'CITRIX' 'Total loss of external connectivity via Gateway service' `
        "Failing probes: $($extDown -join ', ')" 'Remote users cannot open Citrix apps. Office users may be unaffected.' `
        'Check status.cloud.com (Gateway); test from a 3rd network; validate Workspace DNS/TLS; open Sev1 Citrix case if Citrix-side.'
} elseif ($extDown.Count -ge 1 -or ($ext | Where-Object { $syn[$_][0].Status -eq 'Red' })) {
    Add-Alert 'ALR-01b' Warning 'GWaaS' 'External' 'CITRIX' 'External synthetic check failing on a probe' `
        "Probes: $(($ext | Where-Object { $syn[$_][0].Status -eq 'Red' }) -join ', ')" 'Some remote users may be having trouble connecting.' `
        'Compare internal vs external; check probe network; check RTT by region.'
}
$int = @($syn.Keys | Where-Object { $_ -like '*|Internal' } | Where-Object { All-Status $syn[$_] 'Red' -and $syn[$_].Count -ge 2 })
if ($int) {
    Add-Alert 'ALR-01i' Critical 'GWaaS' 'Internal' 'CITRIX' 'Internal path via Gateway service failing' "Probes: $($int -join ', ')" `
        'Office users cannot open Citrix apps.' 'Check internal DNS/proxy to Workspace; check status.cloud.com; compare with external probes.'
}

# ALR-02 / 03 - Cloud Connectors per resource location
$cc = Get-Latest 'CloudConnector' 'HealthyCount' 2
foreach ($rl in $cfg.ResourceLocations) {
    $r = $cc[$rl.Name]; if (-not $r) { continue }
    if ((All-Status $r 'Red') -and $r.Count -ge 2) {
        Add-Alert 'ALR-02' Critical 'CloudConnector' $rl.Name 'CTX-INFRA' "All Cloud Connectors offline in $($rl.Name)" $r[0].Detail `
            "New logons in $($rl.Name) will fail; existing sessions continue for now." 'Check EC2 state; outbound 443/proxy; restart Citrix services; confirm LHC state.'
    } elseif ($r[0].Status -ne 'Green') {
        Add-Alert 'ALR-03' Warning 'CloudConnector' $rl.Name 'CTX-INFRA' "Cloud Connector redundancy lost in $($rl.Name)" $r[0].Detail `
            'Citrix works, but there is no backup connector. One more failure would cause an outage.' 'Restore the failed connector; check pending upgrades.'
    }
}

# ALR-04 - VDA registration
$reg = (Get-Latest 'VDAFleet' 'RegisteredPct' 1)['All']
$unr = (Get-Latest 'VDAFleet' 'Unregistered' 3 20)['All']
if ($reg) {
    $spike = $unr -and $unr.Count -ge 3 -and ((Num $unr[0].ValueNum) - (Num $unr[-1].ValueNum)) -ge (Get-MonThresholds).VdaNewlyUnregistered15m.crit
    if ($reg[0].Status -eq 'Red' -or $spike) {
        Add-Alert 'ALR-04' Critical 'VDAFleet' 'All' 'CTX-INFRA' 'VDA registration failure spike' $reg[0].Detail `
            'Fewer servers are available; some users may wait or be refused.' 'Group by DG/AZ; check connectors; DNS/time/AD; read deregistration reason.'
    } elseif ($reg[0].Status -eq 'Yellow') {
        Add-Alert 'ALR-04' Warning 'VDAFleet' 'All' 'CTX-INFRA' 'VDAs unregistered above normal' $reg[0].Detail `
            'Slightly reduced capacity; no user impact expected yet.' 'Review unregistered VDAs and deregistration reasons.'
    }
}

# ALR-05 - capacity
$cap = (Get-Latest 'VDAFleet' 'CapacityPct' 1)['All']
$hte = (Get-Latest 'VDAFleet' 'HoursToExhaustion' 1 90)['All']
$capSev = @($cap, $hte | Where-Object { $_ } | ForEach-Object { $_[0].Status })
if ($capSev -contains 'Red' -or $capSev -contains 'Yellow') {
    $sev = if ($capSev -contains 'Red') { 'Critical' } else { 'Warning' }
    $hrs = if ($hte) { Num $hte[0].ValueNum } else { $null }
    Add-Alert 'ALR-05' $sev 'VDAFleet' 'Capacity' 'CTX-INFRA' 'VDA capacity exhaustion risk' `
        "$(if ($cap) { $cap[0].Detail }); hours to exhaustion: $(if ($null -ne $hrs) { [math]::Round($hrs,1) } else { 'n/a' })" `
        $(if ($null -ne $hrs) { "We may run out of capacity in about $([math]::Round($hrs)) hours; new users could be refused." } else { 'Capacity is nearly fully used; new users could be refused.' }) `
        $(if ($hte) { $hte[0].Detail } else { 'Raise Autoscale max / power on spare VDAs; check stuck or maintenance-mode VDAs.' })
}

# ALR-06 - logon failure rate (15-min window)
$lg = (Get-Latest 'UserExperience' 'LogonSuccess15m' 1)['All']
if ($lg -and $lg[0].Status -in 'Red', 'Yellow') {
    $pct = [math]::Round((Num $lg[0].ValueNum), 1)
    Add-Alert 'ALR-06' $(if ($lg[0].Status -eq 'Red') { 'Critical' } else { 'Warning' }) 'UserExperience' 'Logons' (Resolve-Owner) `
        "Logon success $pct% (15 min)" $lg[0].Detail "$([math]::Round(100 - $pct, 1))% of logon attempts are failing." `
        'Check failure categories: capacity -> ALR-05; credential -> FAS/IdP; machine -> VDA; configuration -> recent changes.'
}

# ALR-09 / 09b / 10 - FAS
$fas = (Get-Latest 'FAS' 'HealthyCount' 1)['All']
if ($fas -and $fas[0].Status -eq 'Red') {
    Add-Alert 'ALR-09' Critical 'FAS' 'All' 'CTX-INFRA' 'FAS unavailable' $fas[0].Detail 'Users cannot complete sign-in to Citrix apps (single sign-on is failing).' `
        'Check FAS service; certutil -ping CA; RA certificate status; fail over GPO FAS list.'
} elseif ($fas -and $fas[0].Status -eq 'Yellow') {
    Add-Alert 'ALR-09b' Warning 'FAS' 'All' 'CTX-INFRA' 'FAS redundancy lost' $fas[0].Detail 'Sign-in works but has no backup.' 'Restore the second FAS server.'
}
$ra = Get-Latest 'FAS' 'RaCertDaysToExpiry' 1 1500
foreach ($k in $ra.Keys) {
    $x = $ra[$k][0]; if ($x.Status -eq 'Green') { continue }
    Add-Alert 'ALR-10' $(if ($x.Status -eq 'Red') { 'Critical' } else { 'Warning' }) 'FAS' $k 'CTX-INFRA' "FAS authorization certificate expires in $([int](Num $x.ValueNum)) days" '' `
        "Planned work is needed before $($now.AddDays((Num $x.ValueNum)).ToString('dd-MMM-yyyy')) to avoid a sign-in outage." 'Renew the FAS RA certificate and re-authorize FAS.'
}

# ALR-10a - App-V endpoints
$av = Get-Latest 'AppV' 'Endpoint' 2
foreach ($k in $av.Keys) {
    if ((All-Status $av[$k] 'Red') -and $av[$k].Count -ge 2) {
        Add-Alert 'ALR-10a' $(if ($k -eq 'Publishing') { 'Critical' } else { 'Warning' }) 'AppV' $k 'CTX-INFRA' "App-V $k server unavailable" $av[$k][0].Detail `
            'Some packaged apps may be missing or fail to open.' 'Check IIS app pool and SQL; re-sync publishing; validate content share.'
    }
}

# ALR-12 (servers) - connector/FAS saturation from latest hour
# ALR-13 - Citrix vendor incident
$cs = (Get-Latest 'CitrixStatus' 'ActiveIncidents' 1)['status.cloud.com']
if ($cs -and $cs[0].Status -ne 'Green') {
    $uxBad = $lg -and $lg[0].Status -eq 'Red'
    Add-Alert 'ALR-13' $(if ($uxBad -or $cs[0].Status -eq 'Red') { 'Critical' } else { 'Informational' }) 'ControlPlane' 'CitrixCloud' 'CITRIX' `
        'Citrix Cloud vendor incident' $cs[0].Detail "Citrix (the vendor) is reporting a service problem: $($cs[0].Detail)" 'Track vendor ETA; communicate to users.'
}

# ALR-14 - stale monitoring data / collector failures
$age = (Get-Latest 'ControlPlane' 'DataAgeMin' 1 90)['MonitorService']
$failedJobs = (Invoke-MonSql @'
SELECT Job FROM (SELECT Job, Succeeded, ROW_NUMBER() OVER (PARTITION BY Job ORDER BY StartedUtc DESC) rn FROM mon.CollectorRun
                 WHERE StartedUtc >= DATEADD(HOUR,-3,SYSUTCDATETIME()) AND Succeeded IS NOT NULL) x
WHERE rn <= 2 GROUP BY Job HAVING SUM(CASE WHEN Succeeded=0 THEN 1 ELSE 0 END) = 2
'@).Rows | ForEach-Object Job
if (($age -and $age[0].Status -eq 'Red') -or $failedJobs) {
    Add-Alert 'ALR-14' Warning 'Monitoring' 'Collectors' 'CTX-INFRA' 'Monitoring data stale or collector failing' `
        "Failed twice: $($failedJobs -join ', '); Monitor data age: $(if ($age) { [int](Num $age[0].ValueNum) } else { 'n/a' }) min" `
        'Dashboard data may be out of date.' 'Check collector host, API credentials, rate limits; see logs\collector-*.log.'
}
#endregion

#region Rules - hourly tables (last complete hour)
$h = (Get-HourWindow).Hour
$allDg = [guid]::Empty

# ALR-07 - logon duration (per DG + all)
foreach ($r in (Invoke-MonSql @'
SELECT l.DeliveryGroupId, COALESCE(d.Name,'All delivery groups') Name, l.AvgLogonSec, l.P90LogonSec, l.LogonAttempts, l.AvgProfileSec, l.AvgGpoSec, l.AvgAuthSec, l.AvgBrokeringSec
FROM mon.HourlyLogonSummary l LEFT JOIN mon.DeliveryGroup d ON d.DeliveryGroupId = l.DeliveryGroupId
WHERE l.HourUtc=@h AND l.LogonAttempts >= 10
'@ @{ h = $h }).Rows) {
    $sa = Get-RagStatus 'AvgLogonSec' (Num $r.AvgLogonSec); $sp = Get-RagStatus 'P90LogonSec' (Num $r.P90LogonSec)
    $lst = @($sa, $sp)
    if ($lst -contains 'Red' -or $lst -contains 'Yellow') {
        $phases = @{ Profile = (Num $r.AvgProfileSec); GPO = (Num $r.AvgGpoSec); Auth = (Num $r.AvgAuthSec); Brokering = (Num $r.AvgBrokeringSec) }
        $worst = $phases.GetEnumerator() | Where-Object Value | Sort-Object Value -Descending | Select-Object -First 1
        Add-Alert 'ALR-07' $(if ($lst -contains 'Red') { 'Critical' } else { 'Warning' }) 'UserExperience' $r.Name (Resolve-Owner) `
            "Slow logons: avg $([int](Num $r.AvgLogonSec)) s, P90 $([int](Num $r.P90LogonSec)) s" "Largest phase: $($worst.Key) $([math]::Round($worst.Value,1)) s" `
            "Logons in $($r.Name) take $([int](Num $r.AvgLogonSec)) seconds instead of the 30 s target." `
            'Drill into logon phases: profile -> FSLogix/SMB; GPO -> recent GP changes; auth -> FAS; brokering -> Citrix/connectors.' $r.LogonAttempts
    }
}

# ALR-08 - application launch failure / fault rate
$appTh = (Get-MonThresholds).AppLaunchSuccessPct
foreach ($r in (Invoke-MonSql @'
SELECT ApplicationName, SUM(Launches) L, SUM(LaunchFailures) F, SUM(Faults + Errors) X, SUM(UniqueUsers) U
FROM mon.HourlyApplicationSummary WHERE HourUtc=@h GROUP BY ApplicationName
'@ @{ h = $h }).Rows) {
    $att = [int]$r.L + [int]$r.F
    $pct = if ($att) { 100.0 * ([int]$r.L - [int]$r.X) / $att } else { $null }   # launches that neither failed nor crashed
    $st = Get-RagStatus 'AppLaunchSuccessPct' $pct -Volume $att
    if ($st -in 'Red', 'Yellow') {
        Add-Alert 'ALR-08' $(if ($st -eq 'Red') { 'Critical' } else { 'Warning' }) 'Application' $r.ApplicationName (Resolve-Owner) `
            "$($r.ApplicationName): $([math]::Round(100 - $pct, 1))% launches failing" "Launches $($r.L), launch failures $($r.F), crashes/errors $($r.X)" `
            "$($r.ApplicationName) fails to open for $([math]::Round(100 - $pct, 1))% of attempts." 'Check app faults on VDAs, App-V package, delivery group health.' $r.U
    }
}

# ALR-11 - AWS
foreach ($r in (Invoke-MonSql "SELECT ResourceType, ResourceId, CitrixRole, MetricName, Status, Detail FROM mon.AWSInfrastructureHealth WHERE HourUtc=@h AND Status IN ('Red','Yellow') AND MetricName IN ('StatusCheckFailed','FailedActivities','OpenHealthEvents','VolumeStatus','InServiceVsDesired','FreeIpPct')" @{ h = $h }).Rows) {
    Add-Alert 'ALR-11' $(if ($r.Status -eq 'Red') { 'Critical' } else { 'Warning' }) 'AWS' "$($r.ResourceType):$($r.ResourceId)" 'AWS' `
        "AWS $($r.MetricName) on $($r.ResourceId)$(if ($r.CitrixRole -isnot [DBNull]) { " ($($r.CitrixRole))" })" ([string]$r.Detail) `
        'A cloud infrastructure problem is reducing Citrix capacity or resilience.' 'Stop/start instance; check quotas, subnet IPs, AMI; open AWS case if hardware/AZ.'
}

# ALR-12 - saturation: VDA fleet P95 + servers
$v = (Invoke-MonSql @'
SELECT TOP 1 PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY CpuAvgPct) OVER () Cpu,
             PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY MemAvgPct) OVER () Mem,
             MIN(DiskFreeMinPct) OVER () Disk
FROM mon.VDAHealth WHERE HourUtc=@h AND PowerState='On'
'@ @{ h = $h }).Rows
if ($v.Count) {
    $st = @((Get-RagStatus 'VdaCpuP95Pct' (Num $v[0].Cpu)), (Get-RagStatus 'VdaMemP95Pct' (Num $v[0].Mem)), (Get-RagStatus 'VdaDiskFreeMinPct' (Num $v[0].Disk)))
    if ($st -contains 'Red' -or $st -contains 'Yellow') {
        Add-Alert 'ALR-12' $(if ($st -contains 'Red') { 'Critical' } else { 'Warning' }) 'VDAFleet' 'Resources' 'CTX-INFRA' 'VDA resource saturation' `
            "CPU P95 $([int](Num $v[0].Cpu))%, Mem P95 $([int](Num $v[0].Mem))%, min disk free $([int](Num $v[0].Disk))%" `
            'Users on busy servers may see slow apps.' 'Identify top processes (ProcessUtilization); drain/replace hot VDAs; review session density.'
    }
}
foreach ($r in (Invoke-MonSql @'
SELECT 'CloudConnector' C, ServerName, CpuPct, MemPct, DiskFreePct FROM mon.CloudConnectorHealth WHERE HourUtc=@h
UNION ALL SELECT 'FAS', ServerName, CpuPct, MemPct, DiskFreePct FROM mon.FASHealth WHERE HourUtc=@h
'@ @{ h = $h }).Rows) {
    $st = @((Get-RagStatus 'ServerCpuPct' (Num $r.CpuPct)), (Get-RagStatus 'ServerMemPct' (Num $r.MemPct)), (Get-RagStatus 'ServerDiskFreePct' (Num $r.DiskFreePct)))
    if ($st -contains 'Red' -or $st -contains 'Yellow') {
        Add-Alert 'ALR-12' $(if ($st -contains 'Red') { 'Critical' } else { 'Warning' }) $r.C $r.ServerName 'CTX-INFRA' "$($r.C) $($r.ServerName) resource saturation" `
            "CPU $([int](Num $r.CpuPct))%, Mem $([int](Num $r.MemPct))%, disk free $([int](Num $r.DiskFreePct))%" `
            'No user impact yet; reduced headroom on a critical server.' 'Investigate process usage; resize instance; clean disk.'
    }
}

# ALR-15 - unexpected instance growth
$g = (Invoke-MonSql "SELECT ValueNum, Status FROM mon.AWSInfrastructureHealth WHERE HourUtc=@h AND MetricName='InstanceGrowthPct'" @{ h = $h }).Rows
if ($g.Count -and $g[0].Status -in 'Red', 'Yellow') {
    Add-Alert 'ALR-15' $(if ($g[0].Status -eq 'Red') { 'Warning' } else { 'Informational' }) 'AWS' 'Cost' 'AWS' "Running VDA instances +$([int](Num $g[0].ValueNum))% vs last week" '' `
        'Cloud spend is trending above normal.' 'Review Autoscale schedules and orphaned machines.'
}
#endregion

#region Reconcile with AlertHistory, notify
function Test-InMaintenance([string]$Component) {
    $mpath = Join-Path $PSScriptRoot '..\config\maintenance.json'
    if (-not (Test-Path $mpath)) { return $false }
    $t = $now.TimeOfDay
    foreach ($m in (Get-Content $mpath -Raw | ConvertFrom-Json).Windows) {
        if ($m.Component -ne $Component -and $m.Component -ne '*') { continue }
        if ($t -ge [timespan]$m.StartUtc -and $t -le [timespan]$m.EndUtc) { return $true }
    }
    $false
}

function Send-Notification([hashtable]$A, [ValidateSet('trigger', 'resolve')][string]$Action) {
    $n = $cfg.Notifications
    $icon = @{ Critical = '🔴'; Warning = '🟡'; Informational = '🔵' }[$A.Severity]
    $text = if ($Action -eq 'resolve') { "✅ RESOLVED $($A.AlertId) $($A.Title) [$($A.Scope)]" }
            else { "$icon **$($A.Severity) $($A.AlertId)** $($A.Title) [$($A.Scope)]`n`n**Impact:** $($A.ExecImpact)`n`n**Owner:** $($A.Owner)  **Action:** $($A.RunbookAction)`n`n$($A.Detail)`n`n[Dashboard]($($n.DashboardUrl))" }
    try {
        if ($n.TeamsWebhookSecretArn) {
            $hook = (Get-MonSecret $n.TeamsWebhookSecretArn).value
            Invoke-RestMethod -Method Post -Uri $hook -ContentType 'application/json' -Body (@{ text = $text } | ConvertTo-Json) | Out-Null
        }
        if ($A.Severity -eq 'Critical' -and $n.PagerDutyRoutingKeySecretArn) {
            $key = (Get-MonSecret $n.PagerDutyRoutingKeySecretArn).value
            $body = @{ routing_key = $key; event_action = $Action; dedup_key = "$($A.AlertId)|$($A.Component)|$($A.Scope)"
                       payload = @{ summary = "$($A.AlertId) $($A.Title) [$($A.Scope)]"; severity = 'critical'; source = 'citrix-mon'; component = $A.Component
                                    custom_details = @{ impact = $A.ExecImpact; owner = $A.Owner; action = $A.RunbookAction; detail = $A.Detail } } }
            Invoke-RestMethod -Method Post -Uri 'https://events.pagerduty.com/v2/enqueue' -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5) | Out-Null
        }
    } catch { Write-MonLog "Notification failed for $($A.AlertId): $($_.Exception.Message)" 'ERROR' }
}

$open = @{}
foreach ($r in (Invoke-MonSql 'SELECT * FROM mon.AlertHistory WHERE ResolvedUtc IS NULL').Rows) { $open["$($r.AlertId)|$($r.Component)|$($r.Scope)"] = $r }
$sevRank = @{ Informational = 1; Warning = 2; Critical = 3 }

# Dependency suppression: while ALR-02 is open for a location, don't page for VDA registration
$suppressVda = @($found | Where-Object { $_.AlertId -eq 'ALR-02' }).Count -gt 0

foreach ($a in $found) {
    $key = "$($a.AlertId)|$($a.Component)|$($a.Scope)"
    $quiet = (Test-InMaintenance $a.Component) -or ($suppressVda -and $a.AlertId -eq 'ALR-04')
    if ($open.ContainsKey($key)) {
        $o = $open[$key]; $open.Remove($key)
        $escalated = $sevRank[$a.Severity] -gt $sevRank[$o.Severity]
        Invoke-MonSql 'UPDATE mon.AlertHistory SET LastSeenUtc=@n, HealthyStreak=0, Severity=@s, Detail=@d, ExecImpact=@i, Owner=@o, AffectedUsers=@u WHERE AlertKey=@k' `
            @{ n = $now; s = $a.Severity; d = $a.Detail; i = $a.ExecImpact; o = $a.Owner; u = $a.AffectedUsers; k = $o.AlertKey } -NonQuery | Out-Null
        if ($escalated -and -not $quiet) { Send-Notification $a 'trigger' }
    } else {
        $row = $a.Clone(); $row.OpenedUtc = $now; $row.LastSeenUtc = $now; $row.HealthyStreak = 0
        if (-not $quiet -and $a.Severity -ne 'Informational') { $row.NotifiedUtc = $now; Send-Notification $a 'trigger' }
        Write-MonRows -Table 'mon.AlertHistory' -Rows @($row)
    }
}
# Not found this run: count healthy evaluations; resolve after 2
foreach ($o in $open.Values) {
    $streak = [int]$o.HealthyStreak + 1
    if ($streak -ge 2) {
        Invoke-MonSql 'UPDATE mon.AlertHistory SET ResolvedUtc=@n, HealthyStreak=@s WHERE AlertKey=@k' @{ n = $now; s = $streak; k = $o.AlertKey } -NonQuery | Out-Null
        if ($o.NotifiedUtc -isnot [DBNull]) {
            Send-Notification @{ AlertId = $o.AlertId; Severity = $o.Severity; Component = $o.Component; Scope = $o.Scope; Title = $o.Title } 'resolve'
        }
    } else {
        Invoke-MonSql 'UPDATE mon.AlertHistory SET HealthyStreak=@s WHERE AlertKey=@k' @{ s = $streak; k = $o.AlertKey } -NonQuery | Out-Null
    }
}
#endregion

#region Component + overall status (banner / matrix)
$components = [ordered]@{
    ControlPlane   = @{ Owner = 'CITRIX';    Alerts = 'ALR-13', 'ALR-14' }
    GWaaS          = @{ Owner = 'CITRIX';    Alerts = 'ALR-01', 'ALR-01b', 'ALR-01i' }
    CloudConnector = @{ Owner = 'CTX-INFRA'; Alerts = 'ALR-02', 'ALR-03', 'ALR-12' }
    VDAFleet       = @{ Owner = 'CTX-INFRA'; Alerts = 'ALR-04', 'ALR-05', 'ALR-12' }
    FAS            = @{ Owner = 'CTX-INFRA'; Alerts = 'ALR-09', 'ALR-09b', 'ALR-10', 'ALR-12' }
    AppV           = @{ Owner = 'CTX-INFRA'; Alerts = 'ALR-10a' }
    AWS            = @{ Owner = 'AWS';       Alerts = 'ALR-11', 'ALR-15' }
}
$openNow = @((Invoke-MonSql 'SELECT AlertId, Component, Severity, Title, ExecImpact FROM mon.AlertHistory WHERE ResolvedUtc IS NULL').Rows)
$statusRows = foreach ($c in $components.Keys) {
    $mine = @($openNow | Where-Object { $_.Component -eq $c -and $components[$c].Alerts -contains $_.AlertId })
    # Resource-only alerts (ALR-12, ALR-15) cap a component at Yellow
    $hard = @($mine | Where-Object { $_.AlertId -notin 'ALR-12', 'ALR-15' })
    $st = if ($hard | Where-Object Severity -eq 'Critical') { 'Red' } elseif ($mine | Where-Object Severity -in 'Critical', 'Warning') { 'Yellow' } else { 'Green' }
    @{ HourUtc = (Get-HourWindow -HoursBack -1).Hour; Component = $c; Owner = $components[$c].Owner; Status = $st
       Summary = if ($mine) { ($mine | Sort-Object { $sevRank[$_.Severity] } -Descending | Select-Object -First 2 -ExpandProperty Title) -join '; ' } else { 'Healthy' } }
}
Write-MonRows -Table 'mon.ComponentStatus' -Rows @($statusRows) -DeleteWhere 'HourUtc=@h' -DeleteParameters @{ h = (Get-HourWindow -HoursBack -1).Hour }

$userPath = 'ControlPlane', 'GWaaS', 'CloudConnector', 'VDAFleet', 'FAS'
$uxCrit = @($openNow | Where-Object { $_.AlertId -in 'ALR-06', 'ALR-07', 'ALR-08' -and $_.Severity -eq 'Critical' })
$overall = if (($statusRows | Where-Object { $_.Component -in $userPath -and $_.Status -eq 'Red' }) -or $uxCrit) { 'Red' }
           elseif ($openNow | Where-Object Severity -in 'Critical', 'Warning') { 'Yellow' } else { 'Green' }
$top = $openNow | Sort-Object { $sevRank[$_.Severity] } -Descending | Select-Object -First 1
$sentence = switch ($overall) {
    'Green'  { 'All Citrix services are healthy.' }
    'Yellow' { "Citrix apps are available. $($top.ExecImpact)" }
    'Red'    { "Service disruption: $($top.ExecImpact)" }
}
Write-HealthCheck -Component 'Overall' -Scope 'Service' -CheckName 'Status' -Status $overall -ValueNum @($openNow | Where-Object Severity -eq 'Critical').Count -Detail $sentence
#endregion

Write-MonLog "Alerts: $($found.Count) active findings, overall $overall"
