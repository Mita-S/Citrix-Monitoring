#Requires -Version 7.2
<#
.SYNOPSIS
    Hourly Citrix Monitor OData v4 collection -> HourlySessionSummary, HourlyLogonSummary,
    HourlyApplicationSummary, VDAHealth (Citrix-side columns).
.NOTES
    Enum values follow the Monitor OData v4 schema. Validate them against
    https://api.cloud.com/monitorodata/$metadata for your tenant before go-live.
#>
param([int]$HoursBack = 0)

Import-Module (Join-Path $PSScriptRoot 'CitrixMon.Common.psm1') -Force
$cfg = Get-MonConfig
$w   = Get-HourWindow -HoursBack $HoursBack
$s   = ConvertTo-ODataDate $w.Start
$e   = ConvertTo-ODataDate $w.End
$all = [guid]::Empty
Write-MonLog ("OData collection for {0:u} - {1:u}" -f $w.Start, $w.End)

$RegState   = @{ 0 = 'Unknown'; 1 = 'Registered'; 2 = 'Unregistered' }
$FaultState = @{ 0 = 'Unknown'; 1 = 'None'; 2 = 'FailedToStart'; 3 = 'StuckOnBoot'; 4 = 'Unregistered'; 5 = 'MaxCapacity' }
$PowerState = @{ 0 = 'Unknown'; 1 = 'Unavailable'; 2 = 'Off'; 3 = 'On'; 4 = 'Suspended'; 5 = 'TurningOn'; 6 = 'TurningOff'; 7 = 'Suspending'; 8 = 'Resuming' }
# ConnectionFailureCategories.Category: 0 None, 1 Connection(client), 2 Machine, 3 NoCapacity, 4 NoLicense, 5 Configuration
$CatColumn  = @{ 1 = 'FailClient'; 2 = 'FailMachine'; 3 = 'FailNoCapacity'; 4 = 'FailNoLicense'; 5 = 'FailConfiguration' }

# ---------- Reference data ----------
$dgRows   = Get-CitrixOData 'DesktopGroups?$select=Id,Name'
$dgName   = @{}; foreach ($d in $dgRows) { $dgName[[guid]$d.Id] = $d.Name }
$dgCfg    = @{}; foreach ($d in $cfg.DeliveryGroups) { $dgCfg[$d.Name] = $d }
$failCat  = @{}; foreach ($c in (Get-CitrixOData 'ConnectionFailureCategories')) { $failCat[[int]$c.ConnectionFailureEnumValue] = [int]$c.Category }

$machines = Get-CitrixOData ('Machines?$filter=LifecycleState eq 0&$select=Id,Name,DnsName,DesktopGroupId,HostedMachineId,' +
    'CurrentRegistrationState,FaultState,IsInMaintenanceMode,CurrentPowerState,CurrentSessionCount')
$machineDg = @{}; foreach ($m in $machines) { $machineDg[[string]$m.Id] = if ($m.DesktopGroupId) { [guid]$m.DesktopGroupId } else { $all } }
function DgOf($machineId) { if ($machineId -and $machineDg.ContainsKey([string]$machineId)) { $machineDg[[string]$machineId] } else { $all } }

# ---------- Sessions (point-in-time at collection) ----------
$live = Get-CitrixOData 'Sessions?$filter=EndDate eq null and (ConnectionState eq 5 or ConnectionState eq 2)&$select=SessionKey,UserId,ConnectionState,MachineId'

# Sessions started in window (logon duration + phases)
$started = Get-CitrixOData ("Sessions?`$filter=StartDate ge $s and StartDate lt $e" +
    '&$select=SessionKey,UserId,MachineId,LogOnDuration,FailureDate' +
    '&$expand=CurrentConnection($select=IsReconnect,ClientAddress,BrokeringDuration,AuthenticationDuration,VMStartStartDate,VMStartEndDate,' +
    'HdxStartDate,HdxEndDate,GpoStartDate,GpoEndDate,LogOnScriptsStartDate,LogOnScriptsEndDate,ProfileLoadStartDate,ProfileLoadEndDate,' +
    'InteractiveStartDate,InteractiveEndDate)')

$connections = Get-CitrixOData "Connections?`$filter=BrokeringDate ge $s and BrokeringDate lt $e&`$select=Id,SessionKey,IsReconnect,ClientAddress"
$failures    = Get-CitrixOData "ConnectionFailureLogs?`$filter=FailureDate ge $s and FailureDate lt $e&`$select=SessionKey,FailureDate,ConnectionFailureEnumValue,UserId,MachineId"
$rtt         = Get-CitrixOData "SessionMetrics?`$filter=CollectedDate ge $s and CollectedDate lt $e&`$select=SessionId,IcaRttMS"

# Path classification (see design gap #5)
$cidrs = [string[]]$cfg.InternalClientCidrs
$pathBySession = @{}
foreach ($c in $connections) { if ($c.ClientAddress) { $pathBySession[[string]$c.SessionKey] = if (Test-IpInCidr $c.ClientAddress $cidrs) { 'Internal' } else { 'External' } } }
$sessMachine = @{}
foreach ($x in @($live) + @($started) + @($failures)) { if ($x.MachineId) { $sessMachine[[string]$x.SessionKey] = $x.MachineId } }

# ---------- HourlySessionSummary ----------
$sessionRows = foreach ($grp in @($all) + @($dgName.Keys)) {
    $inDg   = { param($mid) $grp -eq $all -or (DgOf $mid) -eq $grp }
    $l      = $live        | Where-Object { & $inDg $_.MachineId }
    $st     = $started     | Where-Object { & $inDg $_.MachineId }
    $fl     = $failures    | Where-Object { & $inDg $_.MachineId }
    $flKeys = @($fl | ForEach-Object { [string]$_.SessionKey })
    $cn     = $connections | Where-Object { $grp -eq $all -or (DgOf $sessMachine[[string]$_.SessionKey]) -eq $grp }
    $int    = @($cn | Where-Object { $pathBySession[[string]$_.SessionKey] -eq 'Internal' })
    $ext    = @($cn | Where-Object { $pathBySession[[string]$_.SessionKey] -eq 'External' })
    $rttVals = if ($grp -eq $all) { [double[]]@($rtt | Where-Object IcaRttMS | ForEach-Object IcaRttMS) } else { @() }
    @{
        HourUtc              = $w.Hour
        DeliveryGroupId      = $grp
        ActiveSessions       = @($l | Where-Object ConnectionState -eq 5).Count
        DisconnectedSessions = @($l | Where-Object ConnectionState -eq 2).Count
        ConcurrentUsers      = @($l | Select-Object -ExpandProperty UserId -Unique).Count
        SessionsStarted      = @($st).Count
        SessionsFailed       = @($fl).Count
        Reconnects           = @($cn | Where-Object IsReconnect).Count
        IcaRttAvgMs          = Get-Avg $rttVals
        IcaRttP95Ms          = Get-Percentile $rttVals 95
        ConnInternal         = $int.Count
        ConnInternalFailed   = @($int | Where-Object { $flKeys -contains [string]$_.SessionKey }).Count
        ConnExternal         = $ext.Count
        ConnExternalFailed   = @($ext | Where-Object { $flKeys -contains [string]$_.SessionKey }).Count
    }
}
# Peak sessions in the hour from the 5-min fast-check history (if present)
$peak = (Invoke-MonSql "SELECT MAX(ValueNum) AS P FROM mon.HealthCheck WHERE Component='VDAFleet' AND CheckName='Sessions' AND CheckUtc >= @s AND CheckUtc < @e" @{ s = $w.Start; e = $w.End }).Rows[0].P
($sessionRows | Where-Object { $_.DeliveryGroupId -eq $all })[0].PeakSessions = if ($peak -is [DBNull]) { $null } else { [int]$peak }
Write-MonRows -Table 'mon.HourlySessionSummary' -Rows $sessionRows -DeleteWhere 'HourUtc=@h' -DeleteParameters @{ h = $w.Hour }

# ---------- HourlyLogonSummary ----------
function PhaseAvg($rows, [scriptblock]$sel) { Get-Avg ([double[]]@($rows | ForEach-Object $sel | Where-Object { $null -ne $_ -and $_ -ge 0 })) }
$logonRows = foreach ($grp in @($all) + @($dgName.Keys)) {
    $st = @($started  | Where-Object { ($grp -eq $all -or (DgOf $_.MachineId) -eq $grp) -and $_.LogOnDuration -and -not $_.CurrentConnection.IsReconnect })
    $fl = @($failures | Where-Object { $grp -eq $all -or (DgOf $_.MachineId) -eq $grp })
    if ($grp -ne $all -and $st.Count -eq 0 -and $fl.Count -eq 0) { continue }
    $durSec = [double[]]@($st | ForEach-Object { $_.LogOnDuration / 1000 })
    $row = @{
        HourUtc = $w.Hour; DeliveryGroupId = $grp
        LogonAttempts = $st.Count + $fl.Count; LogonFailures = $fl.Count
        FailClient = 0; FailMachine = 0; FailNoCapacity = 0; FailNoLicense = 0; FailConfiguration = 0; FailOther = 0
        AvgLogonSec = Get-Avg $durSec; P90LogonSec = Get-Percentile $durSec 90
        AvgBrokeringSec   = PhaseAvg $st { if ($_.CurrentConnection.BrokeringDuration) { $_.CurrentConnection.BrokeringDuration / 1000 } }
        AvgAuthSec        = PhaseAvg $st { if ($_.CurrentConnection.AuthenticationDuration) { $_.CurrentConnection.AuthenticationDuration / 1000 } }
        AvgVmStartSec     = PhaseAvg $st { Get-DurationSec $_.CurrentConnection.VMStartStartDate $_.CurrentConnection.VMStartEndDate }
        AvgHdxSec         = PhaseAvg $st { Get-DurationSec $_.CurrentConnection.HdxStartDate $_.CurrentConnection.HdxEndDate }
        AvgGpoSec         = PhaseAvg $st { Get-DurationSec $_.CurrentConnection.GpoStartDate $_.CurrentConnection.GpoEndDate }
        AvgScriptsSec     = PhaseAvg $st { Get-DurationSec $_.CurrentConnection.LogOnScriptsStartDate $_.CurrentConnection.LogOnScriptsEndDate }
        AvgProfileSec     = PhaseAvg $st { Get-DurationSec $_.CurrentConnection.ProfileLoadStartDate $_.CurrentConnection.ProfileLoadEndDate }
        AvgInteractiveSec = PhaseAvg $st { Get-DurationSec $_.CurrentConnection.InteractiveStartDate $_.CurrentConnection.InteractiveEndDate }
    }
    foreach ($f in $fl) {
        $col = $CatColumn[$failCat[[int]$f.ConnectionFailureEnumValue]]
        if ($col) { $row[$col]++ } else { $row.FailOther++ }
    }
    $row
}
Write-MonRows -Table 'mon.HourlyLogonSummary' -Rows $logonRows -DeleteWhere 'HourUtc=@h' -DeleteParameters @{ h = $w.Hour }

# ---------- HourlyApplicationSummary ----------
$appInst = Get-CitrixOData ("ApplicationInstances?`$filter=StartDate ge $s and StartDate lt $e&`$select=Id,SessionKey" +
    '&$expand=Application($select=Name,PublishedName),Session($select=UserId,MachineId,LogOnDuration)')
$faults  = Get-CitrixOData "ApplicationFaults?`$filter=FaultReportingDate ge $s and FaultReportingDate lt $e&`$select=ProcessName,MachineId"
$errors  = Get-CitrixOData "ApplicationErrors?`$filter=ErrorReportingDate ge $s and ErrorReportingDate lt $e&`$select=ProcessName,MachineId"

# Map process name -> published app via config\app-process-map.json (optional; e.g. {"EXCEL.EXE":"Microsoft Excel"})
$procMapPath = Join-Path $PSScriptRoot '..\config\app-process-map.json'
$procMap = if (Test-Path $procMapPath) { Get-Content $procMapPath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
$appvApps = @($cfg.AppV.Packages | Where-Object { $_ })   # optional list of App-V-delivered app names

$appRows = [System.Collections.Generic.List[hashtable]]::new()
$appInst | Group-Object { "{0}|{1}" -f $(if ($_.Application.PublishedName) { $_.Application.PublishedName } else { $_.Application.Name }), (DgOf $_.Session.MachineId) } | ForEach-Object {
    $name, $dg = $_.Name -split '\|'
    $launch = [double[]]@($_.Group | Where-Object { $_.Session.LogOnDuration } | ForEach-Object { $_.Session.LogOnDuration / 1000 })
    $dgMachines = @($machineDg.GetEnumerator() | Where-Object { $_.Value -eq [guid]$dg } | ForEach-Object Key)
    $procs = @($procMap.GetEnumerator() | Where-Object Value -eq $name | ForEach-Object Key)
    $appRows.Add(@{
        HourUtc = $w.Hour; ApplicationName = $name; DeliveryGroupId = [guid]$dg
        Launches = $_.Count; UniqueUsers = @($_.Group.Session.UserId | Select-Object -Unique).Count
        LaunchFailures = 0
        Faults = @($faults | Where-Object { $procs -contains $_.ProcessName -and $dgMachines -contains [string]$_.MachineId }).Count
        Errors = @($errors | Where-Object { $procs -contains $_.ProcessName -and $dgMachines -contains [string]$_.MachineId }).Count
        AvgLaunchSec = Get-Avg $launch; P90LaunchSec = Get-Percentile $launch 90
        IsAppV = [bool]($appvApps -contains $name)
    })
}
# Session launch failures cannot be reliably attributed to an app in OData; record them per DG
# so the fleet-level App Launch Success KPI is correct. Per-app failures come from synthetics.
$failures | Group-Object { DgOf $_.MachineId } | ForEach-Object {
    $appRows.Add(@{ HourUtc = $w.Hour; ApplicationName = '(launch failure - unattributed)'; DeliveryGroupId = [guid]$_.Name
                    Launches = 0; UniqueUsers = @($_.Group.UserId | Select-Object -Unique).Count; LaunchFailures = $_.Count })
}
Write-MonRows -Table 'mon.HourlyApplicationSummary' -Rows $appRows -DeleteWhere 'HourUtc=@h' -DeleteParameters @{ h = $w.Hour }

# ---------- VDAHealth (Citrix columns; AWS collector enriches later) ----------
$ru  = Get-CitrixOData "ResourceUtilization?`$filter=CollectedDate ge $s and CollectedDate lt $e&`$select=MachineId,PercentCpu,UsedMemory,TotalMemory"
$li  = Get-CitrixOData "LoadIndexes?`$filter=CreatedDate ge $s and CreatedDate lt $e&`$select=MachineId,EffectiveLoadIndex"
$mfl = Get-CitrixOData "MachineFailureLogs?`$filter=FailureStartDate ge $s and FailureStartDate lt $e&`$select=MachineId,FaultState"
$ruBy  = $ru  | Group-Object { [string]$_.MachineId } -AsHashTable -AsString
$liBy  = $li  | Group-Object { [string]$_.MachineId } -AsHashTable -AsString
$mflBy = $mfl | Group-Object { [string]$_.MachineId } -AsHashTable -AsString
$fltBy = @($faults) + @($errors) | Group-Object { [string]$_.MachineId } -AsHashTable -AsString
foreach ($h in 'ruBy', 'liBy', 'mflBy', 'fltBy') { if (-not (Get-Variable $h -ValueOnly)) { Set-Variable $h @{} } }

$vdaRows = foreach ($m in $machines) {
    $id   = [string]$m.Id
    $dgN  = if ($m.DesktopGroupId) { $dgName[[guid]$m.DesktopGroupId] }
    $cpu  = [double[]]@($ruBy[$id] | Where-Object { $_ } | ForEach-Object PercentCpu)
    $mem  = [double[]]@($ruBy[$id] | Where-Object { $_ -and $_.TotalMemory } | ForEach-Object { 100.0 * $_.UsedMemory / $_.TotalMemory })
    $load = [double[]]@($liBy[$id] | Where-Object { $_ } | ForEach-Object EffectiveLoadIndex)
    @{
        HourUtc = $w.Hour; MachineName = $m.Name; DeliveryGroupId = if ($m.DesktopGroupId) { [guid]$m.DesktopGroupId } else { $null }
        Ec2InstanceId     = $m.HostedMachineId
        RegistrationState = $RegState[[int]$m.CurrentRegistrationState]
        FaultState        = $FaultState[[int]$m.FaultState]
        InMaintenance     = [bool]$m.IsInMaintenanceMode
        PowerState        = $PowerState[[int]$m.CurrentPowerState]
        SessionCount      = [int]$m.CurrentSessionCount
        MaxSessions       = if ($dgN -and $dgCfg[$dgN]) { $dgCfg[$dgN].MaxSessionsPerVda } else { $cfg.DefaultMaxSessionsPerVda }
        LoadIndexAvg = Get-Avg $load; LoadIndexMax = ($load | Measure-Object -Maximum).Maximum
        CpuAvgPct    = Get-Avg $cpu;  CpuMaxPct    = ($cpu  | Measure-Object -Maximum).Maximum
        MemAvgPct    = Get-Avg $mem;  MemMaxPct    = ($mem  | Measure-Object -Maximum).Maximum
        FailureEvents = @($mflBy[$id] | Where-Object { $_ }).Count
        AppFaults     = @($fltBy[$id] | Where-Object { $_ }).Count
    }
}
Write-MonRows -Table 'mon.VDAHealth' -Rows $vdaRows -DeleteWhere 'HourUtc=@h' -DeleteParameters @{ h = $w.Hour }

# ---------- Data freshness ----------
$latest = (Get-CitrixOData 'Sessions?$orderby=ModifiedDate desc&$top=1&$select=ModifiedDate') | Select-Object -First 1
if ($latest) {
    $ageMin = ([datetime]::UtcNow - ([datetimeoffset]$latest.ModifiedDate).UtcDateTime).TotalMinutes
    Write-HealthCheck -Component 'ControlPlane' -Scope 'MonitorService' -CheckName 'DataAgeMin' -ValueNum $ageMin -Status (Get-RagStatus 'MonitorDataAgeMin' $ageMin)
}
Write-MonLog "OData: $(@($live).Count) live sessions, $(@($started).Count) started, $(@($failures).Count) failures, $(@($machines).Count) machines"
