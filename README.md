# Citrix DaaS Hourly Monitoring

Hourly monitoring for Citrix DaaS (Virtual Apps) on AWS with Citrix Gateway service, with an executive dashboard. It collects Citrix Monitor OData, DaaS REST, AWS CloudWatch/EC2, Windows (Cloud Connectors, FAS, App-V) and synthetic data into SQL Server. It evaluates alerts every 5 minutes and feeds a Power BI executive dashboard.

**Start here:** [docs/Citrix-DaaS-Hourly-Monitoring-Design.md](docs/Citrix-DaaS-Hourly-Monitoring-Design.md). It contains the dashboard mockup, metric catalog, alert definitions, data-source map, architecture, collection logic, 30/60/90 roadmap and the assumptions to confirm.

## Layout

| Path | Purpose |
|---|---|
| `docs/` | Design document |
| `sql/schema.sql` | `mon` schema: hourly facts, 5-min `HealthCheck`, `AlertHistory`, `ExecutiveDailyRollup`, Power BI views, retention and rollup procs |
| `config/settings.example.json` | Tenant, AWS, server inventory, delivery-group capacity, CIDRs, notification secrets → copy to `settings.json` |
| `config/thresholds.json` | Healthy/Warning/Critical thresholds (single source for collectors and alerts) |
| `config/maintenance.json` | Alert notification suppression windows |
| `config/app-process-map.example.json` | Process → published-app mapping for crash attribution → copy to `app-process-map.json` |
| `collectors/CitrixMon.Common.psm1` | Auth (Citrix Cloud OAuth), OData/REST paging + retry, SQL bulk load, RAG evaluation |
| `collectors/Invoke-FastChecks.ps1` | **Every 5 min:** control plane, Citrix status, VDA registration/capacity, 15-min logon success, connectors/FAS/App-V availability, synthetics, alert evaluation, heartbeat |
| `collectors/Invoke-HourlyRun.ps1` | **Hourly at :05:** REST → OData (+ late-data refresh) → AWS → Windows → 24 h capacity forecast → daily rollup/retention → alerts |
| `collectors/Collect-*.ps1` | Individual collectors; each runs on its own with `-HoursBack N` for backfill |
| `collectors/Invoke-AlertEvaluation.ps1` | Rules ALR-01…15, de-dup/auto-resolve, owner attribution, Teams + PagerDuty, banner status |
| `collectors/Invoke-SyntheticTests.ps1` | Workspace reachability/TLS probe; imports external-probe or launch-engine results |
| `collectors/Register-MonitoringTasks.ps1` | Scheduled tasks on the monitoring host |

## Deploy

1. **Citrix Cloud:** create an API client (Identity and Access Management → API Access) with read-only admin scope. Store `{"client_id":"…","client_secret":"…"}` in AWS Secrets Manager.
2. **Database:** create the database on RDS for SQL Server (2016 SP1+) and run `sql/schema.sql`. Create a login for the collector with `db_datareader`/`db_datawriter`/`EXECUTE` on `mon`, and a read-only login for Power BI.
3. **Monitoring host** (Windows Server EC2, host time zone **UTC**, domain-joined):
   - PowerShell 7.2+, and `Install-Module AWS.Tools.Installer; Install-AWSToolsModule AWS.Tools.CloudWatch,AWS.Tools.EC2,AWS.Tools.AutoScaling,AWS.Tools.SecretsManager,AWS.Tools.AWSHealth`
   - Instance role: `secretsmanager:GetSecretValue` (these secrets only), `cloudwatch:GetMetricData`, `cloudwatch:PutMetricData` (namespace `CitrixMon`), `ec2:Describe*`, `autoscaling:Describe*`, `health:DescribeEvents`
   - A gMSA with WinRM access to the Cloud Connectors, FAS and App-V servers
4. **Configure:** copy `config/settings.example.json` → `config/settings.json` and fill in the inventory. Tag EC2 instances `CitrixRole=VDA|CloudConnector|FAS|AppV`.
5. **VDAs:** deploy the CloudWatch Agent via SSM, with `Memory % Committed Bytes In Use` and `LogicalDisk % Free Space` (append `InstanceId`). Enable the Citrix policies for process monitoring and application failure monitoring.
6. **Smoke test** each collector by hand, for example `pwsh .\collectors\Collect-CitrixMonitorOData.ps1`, then check `logs\` and the `mon.*` tables.
7. **Schedule:** `.\collectors\Register-MonitoringTasks.ps1 -RunAsGmsa 'CORP\svc-citrixmon$'`
8. **Backstops:** create a CloudWatch alarm on `CitrixMon/CollectorHeartbeat` (missing data for 15 min goes to SNS/PagerDuty), plus EC2 status-check alarms on the connector and FAS instances.
9. **External probes:** on ≥2 machines outside the corporate network, run `Invoke-SyntheticTests.ps1 -Action Run -Probe external-1 -Path External -WorkspaceUrl https://<tenant>.cloud.com -OutFile <file>.json` every 5 min and ship the files to `Synthetic.ExternalResultFolder` (for example, S3 sync).
10. **Power BI:** connect to `mon.vExecKpiCurrent`, `mon.vTopIssues`, `mon.ComponentStatus`, the hourly tables, `mon.CapacityForecast` and `mon.ExecutiveDailyRollup`. Lay out the pages as described in design section 1 and schedule an hourly refresh.

## Validation status

- All `.ps1`/`.psm1` files parse cleanly. The pure helpers (CIDR classification, percentiles, RAG thresholds, hour window, OData dates) pass unit tests.
- **Not yet run against a live tenant.** Before go-live, check the OData entity, field and enum names against `https://api.cloud.com/monitorodata/$metadata`. Also work through design section 8 (assumptions & gaps), especially #4 (connector status API), #5 (internal/external classification), #20 (status feed) and #21 (FAS event IDs).
- `sql/schema.sql` has been reviewed but has **not yet been executed** against SQL Server.
