#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers the scheduled tasks on the monitoring EC2 host.
    Run as a gMSA (recommended) so WinRM to connectors/FAS/App-V uses Kerberos without stored passwords.
.EXAMPLE
    .\Register-MonitoringTasks.ps1 -RunAsGmsa 'CORP\svc-citrixmon$'
#>
param(
    [Parameter(Mandatory)][string]$RunAsGmsa,
    [string]$Pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
)
$dir = $PSScriptRoot
$principal = New-ScheduledTaskPrincipal -UserId $RunAsGmsa -LogonType Password -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 50) -StartWhenAvailable

function New-MonTask($Name, $Script, $Trigger, $Limit) {
    $s = $settings.Clone(); if ($Limit) { $s.ExecutionTimeLimit = "PT$($Limit)M" }
    $action = New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File `"$dir\$Script`"" -WorkingDirectory $dir
    Register-ScheduledTask -TaskPath '\CitrixMon\' -TaskName $Name -Action $action -Trigger $Trigger -Principal $principal -Settings $s -Force | Out-Null
    Write-Host "Registered \CitrixMon\$Name"
}

# Times are local to the host; set the host time zone to UTC so :05 aligns with the UTC hour.
$fast = New-ScheduledTaskTrigger -Once -At (Get-Date -Minute 0 -Second 0) -RepetitionInterval (New-TimeSpan -Minutes 5)
$hour = New-ScheduledTaskTrigger -Once -At (Get-Date -Minute 5 -Second 0) -RepetitionInterval (New-TimeSpan -Hours 1)

New-MonTask 'FastChecks-5min' 'Invoke-FastChecks.ps1' $fast 4
New-MonTask 'HourlyRun'       'Invoke-HourlyRun.ps1'  $hour 50
