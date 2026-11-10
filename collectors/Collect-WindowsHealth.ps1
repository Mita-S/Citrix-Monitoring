#Requires -Version 7.2
<#
.SYNOPSIS
    Cloud Connector, FAS and App-V server health via WinRM.
      -Mode Fast   : availability only -> mon.HealthCheck            (every 5 min)
      -Mode Hourly : availability + resources + events -> CloudConnectorHealth, FASHealth, AppVHealth
.NOTES
    Runs as a gMSA/service account with WinRM rights on the target servers.
    FAS issuance event IDs vary by FAS version: set FAS.IssuedEventIds / FAS.FailedEventIds in
    settings.json after checking the Application log on a FAS server. Until set, issuance rate = no data
    and all Error-level FAS events count as failures.
#>
param([ValidateSet('Fast', 'Hourly')][string]$Mode = 'Hourly', [int]$HoursBack = 0)

Import-Module (Join-Path $PSScriptRoot 'CitrixMon.Common.psm1') -Force
$cfg = Get-MonConfig
$w   = Get-HourWindow -HoursBack $HoursBack

# ---------- Remote probes ----------
$baseProbe = {
    param([bool]$Full, [datetime]$SinceUtc)
    $r = @{ Computer = $env:COMPUTERNAME }
    $r.StoppedServices = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto'" |
        Where-Object { $_.DisplayName -like 'Citrix*' -and $_.State -ne 'Running' } | ForEach-Object DisplayName)
    if ($Full) {
        $c = (Get-Counter -Counter '\Processor(_Total)\% Processor Time', '\Memory\% Committed Bytes In Use',
                '\LogicalDisk(C:)\% Free Space', '\Network Interface(*)\Bytes Total/sec' -SampleInterval 5 -MaxSamples 3).CounterSamples
        $avg = { param($p) ($c | Where-Object Path -like $p | Measure-Object CookedValue -Average).Average }
        $r.CpuPct      = & $avg '*processor(_total)*'
        $r.MemPct      = & $avg '*% committed bytes in use'
        $r.DiskFreePct = & $avg '*logicaldisk(c:)*'
        $r.NetMbps     = (($c | Where-Object Path -like '*network interface*' | Group-Object Path |
                           ForEach-Object { ($_.Group | Measure-Object CookedValue -Average).Average } | Measure-Object -Sum).Sum) * 8 / 1e6
        $r.ErrorEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application', 'System'; Level = 1, 2; StartTime = $SinceUtc.ToLocalTime() } -ErrorAction SilentlyContinue |
                           Where-Object { $_.ProviderName -like '*Citrix*' -or $_.LogName -eq 'System' }).Count
    }
    $r
}

$connectorProbe = {
    param([bool]$Full, [datetime]$SinceUtc, [string[]]$Endpoints, $Base)
    $r = & ([scriptblock]::Create($Base)) $Full $SinceUtc
    $fails = foreach ($ep in $Endpoints) {
        $h, $p = $ep -split ':'
        if (-not (Test-NetConnection -ComputerName $h -Port ([int]$p) -InformationLevel Quiet -WarningAction SilentlyContinue)) { $ep }
    }
    $r.ConnectivityFailures = @($fails)
    $r
}

$fasProbe = {
    param([bool]$Full, [datetime]$SinceUtc, [string[]]$CAs, [int[]]$IssuedIds, [int[]]$FailedIds, $Base)
    $r = & ([scriptblock]::Create($Base)) $Full $SinceUtc
    $r.ServiceRunning = (Get-Service CitrixFederatedAuthenticationService -ErrorAction SilentlyContinue).Status -eq 'Running'
    $r.CaFailures = @(foreach ($ca in $CAs) { $null = certutil -ping -config $ca 2>&1; if ($LASTEXITCODE -ne 0) { $ca } })
    try {
        Add-PSSnapin Citrix.Authentication.FederatedAuthenticationService.V1 -ErrorAction Stop
        $ra = Get-FasAuthorizationCertificate -Address localhost | Select-Object -First 1
        $r.RaCertStatus = [string]$ra.Status
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq $ra.Thumbprint | Select-Object -First 1
        $r.RaCertExpiryUtc = if ($cert) { $cert.NotAfter.ToUniversalTime() } else { $null }
    } catch { $r.RaCertStatus = 'Unknown'; $r.RaCertError = $_.Exception.Message }
    if ($Full) {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Citrix.Authentication.FederatedAuthenticationService'; StartTime = $SinceUtc.ToLocalTime() } -ErrorAction SilentlyContinue)
        $r.CertIssued = if ($IssuedIds) { @($ev | Where-Object { $IssuedIds -contains $_.Id }).Count } else { $null }
        $r.CertFailed = if ($FailedIds) { @($ev | Where-Object { $FailedIds -contains $_.Id }).Count } else { @($ev | Where-Object Level -le 2).Count }
    }
    $r
}

$appvProbe = {
    param([bool]$Full, [datetime]$SinceUtc, $Base)
    $r = & ([scriptblock]::Create($Base)) $Full $SinceUtc
    if ($Full) {
        $logs = Get-WinEvent -ListLog 'Microsoft-AppV-Server-*' -ErrorAction SilentlyContinue | Where-Object RecordCount
        $r.PublishFailures = @(foreach ($l in $logs) { Get-WinEvent -FilterHashtable @{ LogName = $l.LogName; Level = 1, 2; StartTime = $SinceUtc.ToLocalTime() } -ErrorAction SilentlyContinue }).Count
    }
    $r
}

function Invoke-Probe($Computer, $Block, [object[]]$ArgList) {
    try { Invoke-Command -ComputerName $Computer -ScriptBlock $Block -ArgumentList $ArgList -ErrorAction Stop }
    catch { Write-MonLog "WinRM to $Computer failed: $($_.Exception.Message)" 'WARN'; $null }
}

function Test-HttpEndpoint($Url) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $resp = Invoke-WebRequest -Uri $Url -UseDefaultCredentials -TimeoutSec 15 -SkipHttpErrorCheck; $ok = $resp.StatusCode -lt 400 }
    catch { $ok = $false }
    @{ Ok = $ok; Ms = [int]$sw.ElapsedMilliseconds }
}

$full  = $Mode -eq 'Hourly'
$since = if ($full) { $w.Start } else { [datetime]::UtcNow.AddMinutes(-5) }
$base  = $baseProbe.ToString()
$hourRows = @{ Connector = @(); FAS = @(); AppV = @() }

# ---------- Cloud Connectors ----------
foreach ($rl in $cfg.ResourceLocations) {
    $healthy = 0
    foreach ($cc in $rl.Connectors) {
        $p = Invoke-Probe $cc $connectorProbe @($full, $since, [string[]]$cfg.Citrix.ConnectivityEndpoints, $base)
        $ok = $p -and -not $p.StoppedServices -and -not $p.ConnectivityFailures
        if ($ok) { $healthy++ }
        $detail = if (-not $p) { 'Unreachable (WinRM)' } else { "Stopped: $($p.StoppedServices -join ', '); Connectivity failures: $($p.ConnectivityFailures -join ', ')" }
        Write-HealthCheck -Component 'CloudConnector' -Scope $cc -CheckName 'Healthy' -Status $(if ($ok) { 'Green' } else { 'Red' }) -ValueNum ([int]$ok) -Detail $detail
        if ($full) {
            $hourRows.Connector += @{
                HourUtc = $w.Hour; ServerName = $cc; ResourceLocation = $rl.Name; Reachable = [bool]$p
                ConnectivityOk = if ($p) { -not $p.ConnectivityFailures } else { $null }
                StoppedServices = if ($p) { $p.StoppedServices -join ', ' } else { $null }
                CpuPct = $p.CpuPct; MemPct = $p.MemPct; DiskFreePct = $p.DiskFreePct; NetMbps = $p.NetMbps; ErrorEvents = $p.ErrorEvents
                Healthy = [bool]$ok
            }
        }
    }
    $min = [int]$rl.MinHealthyConnectors
    $st  = if ($healthy -eq 0) { 'Red' } elseif ($healthy -lt $min) { 'Yellow' } else { 'Green' }
    Write-HealthCheck -Component 'CloudConnector' -Scope $rl.Name -CheckName 'HealthyCount' -Status $st -ValueNum $healthy `
        -Detail "$healthy of $(@($rl.Connectors).Count) healthy (minimum $min)"
}

# Optional: Citrix Cloud's own view of connector status (endpoint varies by tenant - see design gap #4)
if ($cfg.Citrix.ConnectorStatusUri) {
    try {
        $cloud = Invoke-CitrixApi -Uri $cfg.Citrix.ConnectorStatusUri -NoInstanceId
        $list = if ($cloud.PSObject.Properties['items']) { $cloud.items } else { $cloud }
        foreach ($c in @($list)) {
            $name   = if ($c.fqdn) { $c.fqdn } else { $c.name }
            $status = if ($c.status) { $c.status } else { $c.state }
            $hourRows.Connector | Where-Object { $_.ServerName -like "$name*" } | ForEach-Object { $_.CloudStatus = [string]$status }
        }
    } catch { Write-MonLog "Connector status API failed: $($_.Exception.Message)" 'WARN' }
}

# ---------- FAS ----------
$fasHealthy = 0
foreach ($fas in $cfg.FAS.Servers) {
    $p = Invoke-Probe $fas $fasProbe @($full, $since, [string[]]$cfg.FAS.CertificateAuthorities,
        [int[]]@($cfg.FAS.IssuedEventIds | Where-Object { $_ }), [int[]]@($cfg.FAS.FailedEventIds | Where-Object { $_ }), $base)
    $caOk = $p -and $p.CaFailures.Count -lt @($cfg.FAS.CertificateAuthorities).Count
    $ok = $p -and $p.ServiceRunning -and $caOk -and $p.RaCertStatus -notin 'Bad', 'Expired', 'Revoked'
    if ($ok) { $fasHealthy++ }
    Write-HealthCheck -Component 'FAS' -Scope $fas -CheckName 'Healthy' -Status $(if ($ok) { 'Green' } else { 'Red' }) -ValueNum ([int]$ok) `
        -Detail $(if ($p) { "Service=$($p.ServiceRunning) CAFailures=$($p.CaFailures -join ',') RA=$($p.RaCertStatus)" } else { 'Unreachable (WinRM)' })
    if ($p -and $p.RaCertExpiryUtc) {
        $days = ([datetime]$p.RaCertExpiryUtc - [datetime]::UtcNow).TotalDays
        Write-HealthCheck -Component 'FAS' -Scope $fas -CheckName 'RaCertDaysToExpiry' -ValueNum $days -Status (Get-RagStatus 'FasCertDaysToExpiry' $days)
    }
    if ($full) {
        $hourRows.FAS += @{
            HourUtc = $w.Hour; ServerName = $fas; ServiceRunning = [bool]($p -and $p.ServiceRunning); CaReachable = if ($p) { [bool]$caOk } else { $null }
            CertIssued = $p.CertIssued; CertFailed = $p.CertFailed; RaCertStatus = $p.RaCertStatus; RaCertExpiryUtc = $p.RaCertExpiryUtc
            CpuPct = $p.CpuPct; MemPct = $p.MemPct; DiskFreePct = $p.DiskFreePct; ErrorEvents = $p.ErrorEvents; Healthy = [bool]$ok
        }
    }
}
$fasTotal = @($cfg.FAS.Servers).Count
Write-HealthCheck -Component 'FAS' -Scope 'All' -CheckName 'HealthyCount' -ValueNum $fasHealthy `
    -Status $(if ($fasTotal -and $fasHealthy -eq 0) { 'Red' } elseif ($fasHealthy -lt [math]::Min(2, $fasTotal)) { 'Yellow' } else { 'Green' }) `
    -Detail "$fasHealthy of $fasTotal healthy"

# ---------- App-V ----------
foreach ($ep in @(@{ Role = 'Management'; Url = $cfg.AppV.ManagementUrl }, @{ Role = 'Publishing'; Url = $cfg.AppV.PublishingUrl }) | Where-Object { $_.Url }) {
    $t = Test-HttpEndpoint $ep.Url
    $st = if (-not $t.Ok) { 'Red' } else { Get-RagStatus 'EndpointLatencyMs' $t.Ms }
    Write-HealthCheck -Component 'AppV' -Scope $ep.Role -CheckName 'Endpoint' -Status $st -ValueNum $t.Ms -Detail $ep.Url
    if ($full) {
        $host_ = ([uri]$ep.Url).Host
        $p = if (@($cfg.AppV.Servers) -contains $host_) { Invoke-Probe $host_ $appvProbe @($true, $since, $base) } else { $null }
        $hourRows.AppV += @{
            HourUtc = $w.Hour; ServerName = $host_; Role = $ep.Role; EndpointOk = $t.Ok; EndpointLatencyMs = $t.Ms
            PublishFailures = $p.PublishFailures; CpuPct = $p.CpuPct; MemPct = $p.MemPct; DiskFreePct = $p.DiskFreePct
            Healthy = [bool]($t.Ok -and $st -ne 'Red' -and -not $p.StoppedServices)
        }
    }
}

if ($full) {
    $dp = @{ h = $w.Hour }
    Write-MonRows -Table 'mon.CloudConnectorHealth' -Rows $hourRows.Connector -DeleteWhere 'HourUtc=@h' -DeleteParameters $dp
    Write-MonRows -Table 'mon.FASHealth'            -Rows $hourRows.FAS       -DeleteWhere 'HourUtc=@h' -DeleteParameters $dp
    Write-MonRows -Table 'mon.AppVHealth'           -Rows $hourRows.AppV      -DeleteWhere 'HourUtc=@h' -DeleteParameters $dp
}
Write-MonLog "Windows ($Mode): connectors/FAS/App-V checked; FAS healthy $fasHealthy/$fasTotal"
