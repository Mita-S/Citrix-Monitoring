#Requires -Version 7.2
<#
.SYNOPSIS
    Synthetic user-experience checks.
      -Action Run    : run the built-in tier-1 tests (Workspace reachability + TLS) from this probe.
                       Internal probe -> writes mon.SyntheticResult directly.
                       External probe (no SQL access) -> use -OutFile; ship the JSON to the inbox (e.g. via S3 sync).
      -Action Import : load JSON results from the inbox folder (external probes and/or a commercial
                       launch-test engine such as Login Enterprise / ControlUp Scoutbees exported to the same schema).
.NOTES
    Result schema (one JSON array per file):
      [{ "RunUtc":"2026-11-02T14:05:00Z", "Probe":"external-1", "Path":"External",
         "TestName":"Reachability|SignIn|Enumerate|Launch", "Passed":true, "DurationMs":1234, "Detail":"..." }]
    Full sign-in / enumeration / ICA launch is intentionally delegated to a launch engine: it needs an
    interactive Workspace app session and MFA handling that a scheduled script can't do reliably.
#>
param(
    [ValidateSet('Run', 'Import')][string]$Action = 'Run',
    [string]$OutFile,
    [string]$Probe,
    [ValidateSet('Internal', 'External')][string]$Path,
    [string]$WorkspaceUrl
)

$settingsPresent = Test-Path (Join-Path $PSScriptRoot '..\config\settings.json')
if ($settingsPresent) { Import-Module (Join-Path $PSScriptRoot 'CitrixMon.Common.psm1') -Force; $syn = (Get-MonConfig).Synthetic } else { $syn = @{} }
if (-not $Probe)        { $Probe = $syn.ProbeName }
if (-not $Path)         { $Path = $syn.Path }
if (-not $WorkspaceUrl) { $WorkspaceUrl = $syn.WorkspaceUrl }

function Get-TlsCertificate([string]$HostName, [int]$Port = 443) {
    # Synchronous SslStream so the validation callback runs on this thread (safe for PowerShell scriptblocks).
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $tcp.ConnectAsync($HostName, $Port).Wait(10000) | Out-Null
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($HostName)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
        $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
        @{ NotAfter = $cert.NotAfter.ToUniversalTime(); ChainOk = $chain.Build($cert); Subject = $cert.Subject }
    } finally { $tcp.Dispose() }
}

function Invoke-Tier1 {
    $now = [datetime]::UtcNow
    $results = @()
    $uri = [uri]$WorkspaceUrl
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest -Uri $WorkspaceUrl -TimeoutSec 20 -MaximumRedirection 5 -SkipHttpErrorCheck
        $ms = [int]$sw.ElapsedMilliseconds
        $tls = Get-TlsCertificate $uri.Host
        $days = ($tls.NotAfter - $now).TotalDays
        $pass = $resp.StatusCode -lt 400 -and $tls.ChainOk -and $days -gt 14 -and $ms -lt 10000
        $results += @{ RunUtc = $now; Probe = $Probe; Path = $Path; TestName = 'Reachability'; Passed = $pass; DurationMs = $ms
                       Detail = "HTTP $($resp.StatusCode); TLS chain ok=$($tls.ChainOk); cert expires in $([int]$days) d" }
    } catch {
        $results += @{ RunUtc = $now; Probe = $Probe; Path = $Path; TestName = 'Reachability'; Passed = $false
                       DurationMs = [int]$sw.ElapsedMilliseconds; Detail = $_.Exception.Message }
    }
    $results
}

switch ($Action) {
    'Run' {
        $r = Invoke-Tier1
        if ($OutFile) {
            $r | ForEach-Object { $_.RunUtc = $_.RunUtc.ToString('o') }
            ConvertTo-Json @($r) -Depth 3 | Set-Content -Path $OutFile -Encoding utf8
        } else {
            Write-MonRows -Table 'mon.SyntheticResult' -Rows $r
            foreach ($x in $r) {
                Write-HealthCheck -Component 'Synthetic' -Scope "$($x.Probe)|$($x.Path)" -CheckName $x.TestName `
                    -Status $(if ($x.Passed) { 'Green' } else { 'Red' }) -ValueNum $x.DurationMs -Detail $x.Detail
            }
        }
    }
    'Import' {
        $inbox = $syn.ExternalResultFolder
        if (-not (Test-Path $inbox)) { return }
        $done = Join-Path $inbox 'processed'; if (-not (Test-Path $done)) { New-Item -ItemType Directory $done | Out-Null }
        foreach ($f in Get-ChildItem $inbox -Filter *.json -File) {
            try {
                $rows = @(Get-Content $f.FullName -Raw | ConvertFrom-Json -AsHashtable)
                foreach ($x in $rows) {
                    $x.RunUtc = ([datetimeoffset]$x.RunUtc).UtcDateTime
                    $x.RunUtc = $x.RunUtc.AddSeconds(-$x.RunUtc.Second)
                    Write-MonRows -Table 'mon.SyntheticResult' -Rows @($x) -DeleteWhere 'RunUtc=@r AND Probe=@p AND TestName=@t' `
                        -DeleteParameters @{ r = $x.RunUtc; p = $x.Probe; t = $x.TestName }
                    Write-HealthCheck -Component 'Synthetic' -Scope "$($x.Probe)|$($x.Path)" -CheckName $x.TestName -CheckUtc $x.RunUtc `
                        -Status $(if ($x.Passed) { 'Green' } else { 'Red' }) -ValueNum $x.DurationMs -Detail $x.Detail
                }
                Move-Item $f.FullName (Join-Path $done $f.Name) -Force
            } catch { Write-MonLog "Synthetic import failed for $($f.Name): $($_.Exception.Message)" 'ERROR' }
        }
    }
}
