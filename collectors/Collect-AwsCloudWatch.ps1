#Requires -Version 7.2
#Requires -Modules AWS.Tools.CloudWatch, AWS.Tools.EC2, AWS.Tools.AutoScaling
<#
.SYNOPSIS
    Hourly AWS collection for Citrix-tagged resources -> mon.AWSInfrastructureHealth,
    and enrichment of mon.VDAHealth (AZ, disk, network, status checks).
    Credentials: EC2 instance role (read-only: cloudwatch:GetMetricData, ec2:Describe*,
    autoscaling:Describe*, health:DescribeEvents).
#>
param([int]$HoursBack = 0)

Import-Module (Join-Path $PSScriptRoot 'CitrixMon.Common.psm1') -Force
$cfg    = Get-MonConfig
$region = $cfg.Aws.Region
$tagKey = $cfg.Aws.CitrixTagKey
$w      = Get-HourWindow -HoursBack $HoursBack
$rows   = [System.Collections.Generic.List[hashtable]]::new()

function Add-AwsRow($type, $id, $metric, $value, $status, $role = $null, $az = $null, $detail = $null) {
    $rows.Add(@{ HourUtc = $w.Hour; ResourceType = $type; ResourceId = $id; MetricName = $metric; ValueNum = $value
                 Status = $status; CitrixRole = $role; AvailabilityZone = $az; Detail = $detail })
}

# ---------- Inventory ----------
$instances = (Get-EC2Instance -Region $region -Filter @{ Name = "tag-key"; Values = $tagKey }).Instances |
    Where-Object { $_.State.Name -ne 'terminated' }
$roleOf = @{}; $azOf = @{}
foreach ($i in $instances) {
    $roleOf[$i.InstanceId] = ($i.Tags | Where-Object Key -eq $tagKey).Value
    $azOf[$i.InstanceId]   = $i.Placement.AvailabilityZone
}
$running = @($instances | Where-Object { $_.State.Name -eq 'running' })
if (-not $running) { Write-MonLog "No running instances tagged $tagKey in $region" 'WARN'; return }

# ---------- Status checks (current) ----------
$statuses = Get-EC2InstanceStatus -Region $region -InstanceId $running.InstanceId -IncludeAllInstance $true
foreach ($st in $statuses) {
    $bad = $st.SystemStatus.Status -eq 'impaired' -or $st.Status.Status -eq 'impaired'
    $role = $roleOf[$st.InstanceId]
    $sev = if (-not $bad) { 'Green' } elseif ($role -in 'CloudConnector', 'FAS') { 'Red' } else { 'Yellow' }
    Add-AwsRow 'EC2' $st.InstanceId 'StatusCheckFailed' ([int]$bad) $sev $role $st.AvailabilityZone "System=$($st.SystemStatus.Status) Instance=$($st.Status.Status)"
    if ($st.Events) { Add-AwsRow 'EC2' $st.InstanceId 'ScheduledEvent' $st.Events.Count 'Yellow' $role $st.AvailabilityZone (($st.Events | ForEach-Object { "{0} {1:u}" -f $_.Code, $_.NotBefore }) -join '; ') }
}

# ---------- CloudWatch metrics (batched, 500 queries per call) ----------
function New-Query($id, $ns, $metric, $dims, $stat, $period = 300) {
    $q = [Amazon.CloudWatch.Model.MetricDataQuery]::new()
    $q.Id = $id
    $q.MetricStat = [Amazon.CloudWatch.Model.MetricStat]@{
        Metric = [Amazon.CloudWatch.Model.Metric]@{
            Namespace = $ns; MetricName = $metric
            Dimensions = [Amazon.CloudWatch.Model.Dimension[]]@($dims.GetEnumerator() | ForEach-Object { [Amazon.CloudWatch.Model.Dimension]@{ Name = $_.Key; Value = $_.Value } })
        }
        Period = $period; Stat = $stat
    }
    $q
}
$queries = [System.Collections.Generic.List[object]]::new(); $qMap = @{}
$n = 0
foreach ($i in $running) {
    $n++; $id = $i.InstanceId
    $defs = @(
        @("cpu$n", 'AWS/EC2', 'CPUUtilization',  @{ InstanceId = $id }, 'Average'),
        @("cpx$n", 'AWS/EC2', 'CPUUtilization',  @{ InstanceId = $id }, 'Maximum'),
        @("nin$n", 'AWS/EC2', 'NetworkIn',       @{ InstanceId = $id }, 'Sum'),
        @("nou$n", 'AWS/EC2', 'NetworkOut',      @{ InstanceId = $id }, 'Sum'),
        # CloudWatch Agent metrics: dimensions must match the agent config (append_dimensions: InstanceId)
        @("mem$n", 'CWAgent', 'Memory % Committed Bytes In Use', @{ InstanceId = $id; objectname = 'Memory' }, 'Maximum'),
        @("dsk$n", 'CWAgent', 'LogicalDisk % Free Space', @{ InstanceId = $id; objectname = 'LogicalDisk'; instance = 'C:' }, 'Minimum')
    )
    foreach ($d in $defs) { $queries.Add((New-Query @d)); $qMap[$d[0]] = @{ Instance = $id; Metric = $d[2]; Stat = $d[4] } }
}
$results = @{}
for ($k = 0; $k -lt $queries.Count; $k += 500) {
    $batch = $queries.GetRange($k, [math]::Min(500, $queries.Count - $k))
    $token = $null
    do {
        $resp = Get-CWMetricData -Region $region -MetricDataQuery $batch -UtcStartTime $w.Start -UtcEndTime $w.End -NextToken $token -Select '*'
        foreach ($r in $resp.MetricDataResults) { $results[$r.Id] = @($results[$r.Id]) + @($r.Values) | Where-Object { $null -ne $_ } }
        $token = $resp.NextToken
    } while ($token)
}
function Agg($id, [ValidateSet('avg','max','min','sum')]$how) {
    $v = [double[]]@($results[$id]); if (-not $v.Count) { return $null }
    $m = $v | Measure-Object -Average -Maximum -Minimum -Sum
    switch ($how) { 'avg' { $m.Average } 'max' { $m.Maximum } 'min' { $m.Minimum } 'sum' { $m.Sum } }
}

$n = 0
foreach ($i in $running) {
    $n++; $id = $i.InstanceId; $role = $roleOf[$id]; $az = $azOf[$id]
    $cpuAvg = Agg "cpu$n" avg; $cpuMax = Agg "cpx$n" max; $mem = Agg "mem$n" max; $disk = Agg "dsk$n" min
    $netIn  = Agg "nin$n" sum; $netOut = Agg "nou$n" sum
    if ($role -ne 'VDA') {
        Add-AwsRow 'EC2' $id 'CPUUtilization' $cpuAvg (Get-RagStatus 'ServerCpuPct' $cpuAvg) $role $az
        Add-AwsRow 'EC2' $id 'MemoryPct' $mem (Get-RagStatus 'ServerMemPct' $mem) $role $az
        Add-AwsRow 'EC2' $id 'DiskFreeMinPct' $disk (Get-RagStatus 'ServerDiskFreePct' $disk) $role $az
    } else {
        $sc = ($rows | Where-Object { $_.ResourceId -eq $id -and $_.MetricName -eq 'StatusCheckFailed' } | Select-Object -First 1).ValueNum
        Invoke-MonSql @'
UPDATE mon.VDAHealth SET AvailabilityZone=@az, DiskFreeMinPct=@disk,
       NetInMbps=@nin, NetOutMbps=@nout, Ec2StatusCheckFailed=@sc,
       CpuMaxPct = CASE WHEN CpuMaxPct IS NULL OR CpuMaxPct < @cpx THEN @cpx ELSE CpuMaxPct END,
       CpuAvgPct = COALESCE(CpuAvgPct, @cpu),
       MemMaxPct = COALESCE(MemMaxPct, @mem)
WHERE HourUtc=@h AND Ec2InstanceId=@id
'@ @{ az = $az; disk = $disk; nin = $(if ($null -ne $netIn) { $netIn * 8 / 3600 / 1e6 } else { $null })
      nout = $(if ($null -ne $netOut) { $netOut * 8 / 3600 / 1e6 } else { $null }); sc = $sc
      cpx = $cpuMax; cpu = $cpuAvg; mem = $mem; h = $w.Hour; id = $id } -NonQuery | Out-Null
    }
}

# ---------- EBS ----------
$volIds = @($running.BlockDeviceMappings.Ebs.VolumeId)
if ($volIds) {
    foreach ($vs in Get-EC2VolumeStatus -Region $region -VolumeId $volIds) {
        $ok = $vs.VolumeStatus.Status -eq 'ok'
        Add-AwsRow 'EBS' $vs.VolumeId 'VolumeStatus' ([int](-not $ok)) $(if ($ok) { 'Green' } else { 'Red' }) $null $vs.AvailabilityZone $vs.VolumeStatus.Status
    }
}

# ---------- Auto Scaling (only if ASGs are used) ----------
foreach ($asgName in @($cfg.Aws.AutoScalingGroups)) {
    $asg = Get-ASAutoScalingGroup -Region $region -AutoScalingGroupName $asgName
    $inSvc = @($asg.Instances | Where-Object LifecycleState -eq 'InService').Count
    Add-AwsRow 'ASG' $asgName 'InServiceVsDesired' ($inSvc - $asg.DesiredCapacity) $(if ($inSvc -lt $asg.DesiredCapacity) { 'Yellow' } else { 'Green' }) 'VDA' $null "InService=$inSvc Desired=$($asg.DesiredCapacity)"
    $failed = @(Get-ASScalingActivity -Region $region -AutoScalingGroupName $asgName -MaxRecord 50 |
        Where-Object { $_.StartTime.ToUniversalTime() -ge $w.Start -and $_.StatusCode -in 'Failed', 'Cancelled' })
    Add-AwsRow 'ASG' $asgName 'FailedActivities' $failed.Count $(if ($failed.Count -ge 2) { 'Red' } elseif ($failed.Count) { 'Yellow' } else { 'Green' }) 'VDA' $null (($failed | Select-Object -First 3 -ExpandProperty StatusMessage) -join ' | ')
}

# ---------- Subnet free IPs ----------
foreach ($sn in Get-EC2Subnet -Region $region -SubnetId @($running.SubnetId | Select-Object -Unique)) {
    $total = [math]::Pow(2, 32 - [int]($sn.CidrBlock -split '/')[1]) - 5
    $pct = 100.0 * $sn.AvailableIpAddressCount / $total
    Add-AwsRow 'Subnet' $sn.SubnetId 'FreeIpPct' $pct $(if ($pct -lt 10) { 'Red' } elseif ($pct -lt 20) { 'Yellow' } else { 'Green' }) $null $sn.AvailabilityZone
}

# ---------- Instance growth vs 7-day max for same hour (cost anomaly) ----------
$vdaRunning = @($running | Where-Object { $roleOf[$_.InstanceId] -eq 'VDA' }).Count
$hist = (Invoke-MonSql @'
SELECT MAX(ValueNum) AS M FROM mon.AWSInfrastructureHealth
WHERE ResourceType='Account' AND MetricName='RunningVdaInstances'
  AND HourUtc >= DATEADD(DAY,-7,@h) AND HourUtc < @h AND DATEPART(HOUR,HourUtc)=DATEPART(HOUR,@h)
'@ @{ h = $w.Hour }).Rows[0].M
$growth = if ($hist -isnot [DBNull] -and $hist -gt 0) { 100.0 * ($vdaRunning - $hist) / $hist } else { $null }
Add-AwsRow 'Account' $region 'RunningVdaInstances' $vdaRunning 'Green' 'VDA'
Add-AwsRow 'Account' $region 'InstanceGrowthPct' $growth (Get-RagStatus 'InstanceGrowthPct' $growth) 'VDA'

# ---------- AWS Health (requires Business/Enterprise support) ----------
try {
    Import-Module AWS.Tools.AWSHealth -ErrorAction Stop
    $azs = @($azOf.Values | Select-Object -Unique)
    $ev = Get-HLTHEvent -Region us-east-1 -Filter_Region $region -Filter_EventStatusCode open -Filter_Service EC2, EBS, VPC
    $ours = @($ev | Where-Object { -not $_.AvailabilityZone -or $azs -contains $_.AvailabilityZone })
    Add-AwsRow 'AZ' $region 'OpenHealthEvents' $ours.Count $(if ($ours | Where-Object EventTypeCategory -eq 'issue') { 'Red' } elseif ($ours) { 'Yellow' } else { 'Green' }) $null $null (($ours | Select-Object -First 3 | ForEach-Object { "$($_.Service) $($_.EventTypeCode) $($_.AvailabilityZone)" }) -join '; ')
} catch {
    Write-MonLog "AWS Health API unavailable ($($_.Exception.Message)); AZ status not collected" 'WARN'
}

Write-MonRows -Table 'mon.AWSInfrastructureHealth' -Rows $rows -DeleteWhere 'HourUtc=@h' -DeleteParameters @{ h = $w.Hour }
Write-MonLog "AWS: $($running.Count) running instances, $($rows.Count) health rows"
