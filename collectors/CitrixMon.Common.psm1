#Requires -Version 7.2
<#
    Shared helpers for the Citrix DaaS monitoring collectors.
    Config:   ..\config\settings.json (copy of settings.example.json), thresholds.json
    Secrets:  AWS Secrets Manager (AWS.Tools.SecretsManager), read with the instance role.
#>
Set-StrictMode -Version 1   # Latest would throw on absent OData properties such as @odata.nextLink
$ErrorActionPreference = 'Stop'

$script:Root       = Split-Path $PSScriptRoot -Parent
$script:Config     = $null
$script:Thresholds = $null
$script:Token      = $null
$script:TokenExp   = [datetime]::MinValue
$script:SqlConn    = $null
$script:AllDg      = [guid]::Empty

#region Config, logging, secrets
function Get-MonConfig {
    if (-not $script:Config) {
        $path = Join-Path $script:Root 'config\settings.json'
        if (-not (Test-Path $path)) { throw "Missing $path (copy config\settings.example.json)." }
        $script:Config = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
    }
    $script:Config
}

function Get-MonThresholds {
    if (-not $script:Thresholds) {
        $script:Thresholds = Get-Content (Join-Path $script:Root 'config\thresholds.json') -Raw | ConvertFrom-Json -AsHashtable
    }
    $script:Thresholds
}

function Write-MonLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $dir = Join-Path $script:Root 'logs'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
    $line = '{0:u} [{1}] {2}' -f (Get-Date).ToUniversalTime(), $Level, $Message
    Add-Content -Path (Join-Path $dir ("collector-{0:yyyyMMdd}.log" -f (Get-Date))) -Value $line
    Write-Host $line
}

function Get-MonSecret {
    param([Parameter(Mandatory)][string]$SecretArn)
    Import-Module AWS.Tools.SecretsManager -ErrorAction Stop
    $raw = (Get-SECSecretValue -SecretId $SecretArn -Region (Get-MonConfig).Aws.Region).SecretString
    try { $raw | ConvertFrom-Json -AsHashtable } catch { @{ value = $raw } }
}
#endregion

#region Time & math helpers
function Get-HourWindow {
    <# Returns the last complete UTC hour (or the hour HoursBack before it). #>
    param([int]$HoursBack = 0)
    $now = [datetime]::UtcNow
    $end = [datetime]::new($now.Year, $now.Month, $now.Day, $now.Hour, 0, 0, [DateTimeKind]::Utc).AddHours(-$HoursBack)
    [pscustomobject]@{ Start = $end.AddHours(-1); End = $end; Hour = $end.AddHours(-1) }
}

function ConvertTo-ODataDate { param([datetime]$Date) $Date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

function Get-Percentile {
    param([double[]]$Values, [double]$P)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = $Values | Sort-Object
    $idx = [math]::Ceiling($P / 100 * $s.Count) - 1
    $s[[math]::Max(0, [math]::Min($idx, $s.Count - 1))]
}

function Get-Avg { param([double[]]$Values) if ($Values -and $Values.Count) { ($Values | Measure-Object -Average).Average } else { $null } }

function Get-DurationSec {
    param($Start, $End)
    if ($Start -and $End) { ([datetime]$End - [datetime]$Start).TotalSeconds } else { $null }
}

function Test-IpInCidr {
    param([string]$Ip, [string[]]$Cidrs)
    $addr = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$addr) -or $addr.AddressFamily -ne 'InterNetwork') { return $false }
    $ipBytes = $addr.GetAddressBytes(); [array]::Reverse($ipBytes); $ipInt = [BitConverter]::ToUInt32($ipBytes, 0)
    foreach ($c in $Cidrs) {
        $net, $bits = $c -split '/'
        $nb = ([System.Net.IPAddress]::Parse($net)).GetAddressBytes(); [array]::Reverse($nb)
        $mask = if ([int]$bits -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - [int]$bits) }
        if (($ipInt -band $mask) -eq ([BitConverter]::ToUInt32($nb, 0) -band $mask)) { return $true }
    }
    $false
}

function Get-RagStatus {
    <# Evaluates a value against thresholds.json. Returns Green|Yellow|Red, or Grey if no data / below min volume. #>
    param([Parameter(Mandatory)][string]$Metric, $Value, [int]$Volume = [int]::MaxValue)
    $t = (Get-MonThresholds)[$Metric]
    if (-not $t) { throw "No threshold defined for $Metric" }
    if ($null -eq $Value) { return 'Grey' }
    if ($t.ContainsKey('minVolume') -and $Volume -lt $t.minVolume) { return 'Grey' }
    if ($t.dir -eq 'low') {
        if ($Value -lt $t.crit) { 'Red' } elseif ($Value -lt $t.warn) { 'Yellow' } else { 'Green' }
    } else {
        if ($Value -gt $t.crit) { 'Red' } elseif ($Value -gt $t.warn) { 'Yellow' } else { 'Green' }
    }
}
#endregion

#region Citrix Cloud API
function Get-CitrixToken {
    if ($script:Token -and [datetime]::UtcNow -lt $script:TokenExp) { return $script:Token }
    $cfg = (Get-MonConfig).Citrix
    $sec = Get-MonSecret -SecretArn $cfg.ClientSecretArn          # { "client_id": "...", "client_secret": "..." }
    $resp = Invoke-RestMethod -Method Post -Uri "$($cfg.ApiBase)/cctrustoauth2/$($cfg.CustomerId)/tokens/clients" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'client_credentials'; client_id = $sec.client_id; client_secret = $sec.client_secret }
    $script:Token    = $resp.access_token
    $script:TokenExp = [datetime]::UtcNow.AddSeconds([int]$resp.expires_in - 300)
    $script:Token
}

function Get-CitrixSiteId {
    $cfg = (Get-MonConfig).Citrix
    if ($cfg.SiteId) { return $cfg.SiteId }
    $me = Invoke-CitrixApi -Uri "$($cfg.ApiBase)/cvad/manage/me" -NoInstanceId
    $cfg.SiteId = $me.Customers[0].Sites[0].Id
    $cfg.SiteId
}

function Invoke-CitrixApi {
    <# GET with auth headers, retry on 429/5xx with backoff. #>
    param([Parameter(Mandatory)][string]$Uri, [switch]$NoInstanceId, [int]$MaxRetry = 4)
    $cfg = (Get-MonConfig).Citrix
    $headers = @{
        Authorization       = "CwsAuth Bearer=$(Get-CitrixToken)"
        'Citrix-CustomerId' = $cfg.CustomerId
        Accept              = 'application/json'
    }
    if (-not $NoInstanceId) { $headers['Citrix-InstanceId'] = Get-CitrixSiteId }
    for ($i = 0; ; $i++) {
        try {
            return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -TimeoutSec 120
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($i -ge $MaxRetry -or ($code -and $code -notin 429, 500, 502, 503, 504)) { throw }
            $wait = [math]::Pow(2, $i + 1)
            Write-MonLog "Citrix API $code on $Uri - retry in $wait s" 'WARN'
            Start-Sleep -Seconds $wait
        }
    }
}

function Get-CitrixOData {
    <# Monitor OData v4 query with @odata.nextLink paging. $Query = 'Entity?$filter=...' #>
    param([Parameter(Mandatory)][string]$Query)
    $uri = "$((Get-MonConfig).Citrix.ApiBase)/monitorodata/$Query"
    $all = [System.Collections.Generic.List[object]]::new()
    while ($uri) {
        $r = Invoke-CitrixApi -Uri $uri
        if ($r.value) { $all.AddRange([object[]]$r.value) }
        $uri = $r.'@odata.nextLink'
    }
    , $all
}

function Get-CitrixODataCount {
    param([Parameter(Mandatory)][string]$Entity, [Parameter(Mandatory)][string]$Filter)
    $keySel = @{ Sessions = 'SessionKey'; Machines = 'Id'; Connections = 'Id' }[$Entity]
    $q = "$Entity`?`$filter=$Filter&`$count=true&`$top=1" + $(if ($keySel) { "&`$select=$keySel" })
    [int](Invoke-CitrixApi -Uri "$((Get-MonConfig).Citrix.ApiBase)/monitorodata/$q").'@odata.count'
}

function Get-CitrixRest {
    <# CVAD Manage REST with ContinuationToken paging. $Path = 'Machines' #>
    param([Parameter(Mandatory)][string]$Path, [int]$Limit = 1000)
    $base = "$((Get-MonConfig).Citrix.ApiBase)/cvad/manage/$Path"
    $sep  = if ($Path.Contains('?')) { '&' } else { '?' }
    $all  = [System.Collections.Generic.List[object]]::new()
    $token = $null
    do {
        $uri = "$base$($sep)limit=$Limit" + $(if ($token) { "&continuationToken=$([uri]::EscapeDataString($token))" })
        $r = Invoke-CitrixApi -Uri $uri
        if ($r.Items) { $all.AddRange([object[]]$r.Items) }
        $token = $r.ContinuationToken
    } while ($token)
    , $all
}
#endregion

#region SQL
function Get-MonSqlConnection {
    if ($script:SqlConn -and $script:SqlConn.State -eq 'Open') { return $script:SqlConn }
    $cfg = (Get-MonConfig).Sql
    $cs = $cfg.ConnectionString
    if ($cfg.CredentialSecretArn) {
        $c = Get-MonSecret -SecretArn $cfg.CredentialSecretArn     # { "username": "...", "password": "..." }
        $cs = "$cs;User ID=$($c.username);Password=$($c.password)"
    } else { $cs = "$cs;Integrated Security=SSPI" }
    $script:SqlConn = [System.Data.SqlClient.SqlConnection]::new($cs)
    $script:SqlConn.Open()
    $script:SqlConn
}

function Invoke-MonSql {
    param([Parameter(Mandatory)][string]$Query, [hashtable]$Parameters = @{}, [switch]$NonQuery)
    $cmd = (Get-MonSqlConnection).CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = 120
    foreach ($k in $Parameters.Keys) {
        $v = $Parameters[$k]; [void]$cmd.Parameters.AddWithValue("@$k", $(if ($null -eq $v) { [DBNull]::Value } else { $v }))
    }
    if ($NonQuery) { return $cmd.ExecuteNonQuery() }
    $dt = [System.Data.DataTable]::new()
    $dt.Load($cmd.ExecuteReader())
    , $dt
}

function Write-MonRows {
    <#
        Idempotent load: DELETE FROM <Table> WHERE <DeleteWhere>, then SqlBulkCopy the rows.
        Rows are hashtables/pscustomobjects whose property names match column names.
    #>
    param(
        [Parameter(Mandatory)][string]$Table,
        [AllowEmptyCollection()][object[]]$Rows,
        [string]$DeleteWhere,
        [hashtable]$DeleteParameters = @{}
    )
    $conn = Get-MonSqlConnection
    $tx = $conn.BeginTransaction()
    try {
        if ($DeleteWhere) {
            $cmd = $conn.CreateCommand(); $cmd.Transaction = $tx
            $cmd.CommandText = "DELETE FROM $Table WHERE $DeleteWhere"
            foreach ($k in $DeleteParameters.Keys) { [void]$cmd.Parameters.AddWithValue("@$k", $DeleteParameters[$k]) }
            [void]$cmd.ExecuteNonQuery()
        }
        if ($Rows -and $Rows.Count) {
            # Build DataTable from destination schema so column types/order match.
            $schemaCmd = $conn.CreateCommand(); $schemaCmd.Transaction = $tx
            $schemaCmd.CommandText = "SELECT TOP 0 * FROM $Table"
            $dt = [System.Data.DataTable]::new(); $dt.Load($schemaCmd.ExecuteReader())
            # Let SQL enforce nullability/defaults; the DataTable is only a transport.
            $dt.PrimaryKey = @(); $dt.Constraints.Clear()
            foreach ($col in $dt.Columns) { $col.AllowDBNull = $true; $col.ReadOnly = $false; $col.AutoIncrement = $false }
            foreach ($r in $Rows) {
                $row = $dt.NewRow()
                $props = if ($r -is [hashtable]) { $r.GetEnumerator() } else { $r.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Value = $_.Value } } }
                foreach ($p in $props) {
                    if ($dt.Columns.Contains($p.Key)) { $row[$p.Key] = if ($null -eq $p.Value) { [DBNull]::Value } else { $p.Value } }
                }
                $dt.Rows.Add($row)
            }
            $bc = [System.Data.SqlClient.SqlBulkCopy]::new($conn, [System.Data.SqlClient.SqlBulkCopyOptions]::Default, $tx)
            $bc.DestinationTableName = $Table
            foreach ($col in $dt.Columns) {
                # Skip computed / identity columns (no value supplied on any row)
                if (($dt.Rows | Where-Object { $_[$col.ColumnName] -isnot [DBNull] } | Select-Object -First 1)) {
                    [void]$bc.ColumnMappings.Add($col.ColumnName, $col.ColumnName)
                }
            }
            $bc.WriteToServer($dt)
        }
        $tx.Commit()
    } catch { $tx.Rollback(); throw }
}

function Write-HealthCheck {
    param(
        [Parameter(Mandatory)][string]$Component, [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$CheckName, [Parameter(Mandatory)][ValidateSet('Green','Yellow','Red','Grey')][string]$Status,
        $ValueNum, [string]$Detail, [datetime]$CheckUtc = [datetime]::UtcNow
    )
    $ts = [datetime]::new($CheckUtc.Year, $CheckUtc.Month, $CheckUtc.Day, $CheckUtc.Hour, [math]::Floor($CheckUtc.Minute / 5) * 5, 0, [DateTimeKind]::Utc)
    Write-MonRows -Table 'mon.HealthCheck' -Rows @(@{
            CheckUtc = $ts; Component = $Component; Scope = $Scope; CheckName = $CheckName
            Status = $Status; ValueNum = $ValueNum; Detail = if ($Detail) { $Detail.Substring(0, [math]::Min(2000, $Detail.Length)) }
        }) -DeleteWhere 'CheckUtc=@t AND Component=@c AND Scope=@s AND CheckName=@n' `
        -DeleteParameters @{ t = $ts; c = $Component; s = $Scope; n = $CheckName }
}

function Invoke-CollectorJob {
    <# Wraps a job: records mon.CollectorRun, logs, never lets one job kill the orchestrator. #>
    param([Parameter(Mandatory)][string]$Job, [Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $started = [datetime]::UtcNow
    $runId = (Invoke-MonSql "INSERT mon.CollectorRun (Job, StartedUtc) OUTPUT INSERTED.RunId VALUES (@j, @s)" @{ j = $Job; s = $started }).Rows[0].RunId
    try {
        & $ScriptBlock
        Invoke-MonSql "UPDATE mon.CollectorRun SET EndedUtc=SYSUTCDATETIME(), Succeeded=1 WHERE RunId=@r" @{ r = $runId } -NonQuery | Out-Null
        Write-MonLog "$Job completed in $([int]([datetime]::UtcNow - $started).TotalSeconds)s"
        $true
    } catch {
        $msg = "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"
        Invoke-MonSql "UPDATE mon.CollectorRun SET EndedUtc=SYSUTCDATETIME(), Succeeded=0, Message=@m WHERE RunId=@r" @{ r = $runId; m = $msg.Substring(0, [math]::Min(2000, $msg.Length)) } -NonQuery | Out-Null
        Write-MonLog "$Job FAILED: $msg" 'ERROR'
        $false
    }
}
#endregion

Export-ModuleMember -Function * -Variable AllDg
