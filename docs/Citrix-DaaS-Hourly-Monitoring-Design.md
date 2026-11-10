# Citrix DaaS Hourly Monitoring & Executive Dashboard — Design

**Scope:** Citrix DaaS (Virtual Apps) in Citrix Cloud · multi-session VDAs on AWS EC2 · Citrix Gateway service (GWaaS) for all user access · customer-managed Cloud Connectors, FAS, App-V and AWS resources.
**Cadence:** Dashboard refreshes hourly. Critical availability checks run every 5 minutes so alerts never wait for the hourly cycle.
**Implementation:** see `sql/`, `config/` and `collectors/` in this repository; `README.md` covers deployment.

---

## 0. Ownership model (applies to every panel)

Each metric, alert and component tile carries an **Owner** tag so executives can tell "our problem" from "vendor problem" at a glance.

| Owner tag | Components | What we can do |
|---|---|---|
| **CITRIX** (vendor-managed) | Delivery Controllers / brokering, Monitor service and its database, Gateway service (GWaaS), Citrix Cloud control plane, Workspace platform | Detect, correlate with status.cloud.com, open a Citrix case, tell users |
| **CTX-INFRA** (internal Citrix team) | Cloud Connectors, VDA images and configuration, Delivery Groups / Catalogs, Autoscale, FAS, App-V, published apps | Fix directly using the runbooks |
| **AWS** (internal cloud team, plus AWS) | EC2, EBS, VPC, AZs, Auto Scaling, Directory/DNS dependencies on AWS | Fix directly, or open an AWS case for AZ or hardware issues |

**Attribution rule:** when a user-facing KPI degrades, the alert engine checks the health of the layers it depends on, in order: synthetic path → GWaaS → Citrix Cloud status → Connectors → FAS → VDA → AWS. It assigns the owner of the **lowest unhealthy layer**. If every customer-managed layer is healthy and Citrix status shows an incident, the owner is CITRIX.

---

## 1. Executive dashboard mockup

### 1.1 Page 1 — "Is Citrix working right now?" (executive view)

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│  ● YELLOW   Citrix apps are available. Logons are slower than normal (41s vs 28s target)  │
│             for the Finance delivery group; VDA capacity is being added.                  │
│  Active critical incidents: 0   Warnings: 2   Last refresh: 02-Nov-2026 14:00 UTC (hourly)│
└──────────────────────────────────────────────────────────────────────────────────────────┘
┌────────────┬────────────┬────────────┬────────────┬────────────┬────────────┐
│Active users│Active sess.│Logon succ. │Avg logon   │App launch  │External    │
│   1,284    │   1,512    │  99.4 % ●  │  41 s  ●   │  99.1 % ●  │  98.7 % ●  │
│ ▲6% vs LW  │ ▲4% vs LW  │ target 99% │ target <30s│ target 99% │ target 98% │
├────────────┼────────────┼────────────┼────────────┼────────────┼────────────┤
│VDA avail.  │Connectors  │FAS         │Capacity    │Open crit.  │Synthetic   │
│  97.8 % ●  │  4/4  ●    │  2/2  ●    │  82 %  ●   │    0   ●   │ 12/12 ●    │
│ 2 unregist.│ 2 per site │ certs OK   │ ~6h to full│            │ int+ext OK │
└────────────┴────────────┴────────────┴────────────┴────────────┴────────────┘
 ● green  ● yellow  ● red      LW = same hour last week
```

**Component health matrix**

| Component | Owner | Status | Signal | Last 24h |
|---|---|---|---|---|
| Citrix Cloud control plane | CITRIX | ● Green | status.cloud.com: no incidents; broker API 210 ms | ▁▁▁▁▁▁▁▁ |
| Gateway service (GWaaS) | CITRIX | ● Green | External synthetic 6/6, internal 6/6; conn. success 98.7% | ▁▁▁▂▁▁▁▁ |
| Cloud Connectors | CTX-INFRA | ● Green | 4/4 online, ≥2 per resource location, 0 service faults | ▁▁▁▁▁▁▁▁ |
| VDA fleet | CTX-INFRA | ● Yellow | 2 unregistered, Load Index p95 8,100, CPU p95 86% | ▁▁▂▃▅▆▅▄ |
| FAS | CTX-INFRA | ● Green | 2/2 up, 100% cert issuance, RA cert expires in 211 d | ▁▁▁▁▁▁▁▁ |
| App-V | CTX-INFRA | ● Green | Publishing OK, 0 package failures | ▁▁▁▁▁▁▁▁ |
| AWS infrastructure | AWS | ● Green | 0 failed status checks, AZs healthy, 0 ASG failures | ▁▁▁▁▁▁▁▁ |

**Top issues**

| Sev | Component | Affected | Business impact | Next action | Owner |
|---|---|---|---|---|---|
| ⚠ Warning | VDA fleet / Finance-DG | ~310 users | Logons take ~13 s longer; users notice the delay but can work | Autoscale adding 3 VDAs; check profile-load phase (FSLogix) | CTX-INFRA |
| ⚠ Warning | VDA capacity | All DGs | At the current growth rate, new logons could be refused in about 6 h | Raise the Autoscale max from 40 to 46 before 18:00 UTC | CTX-INFRA |

### 1.2 Page 2 — Trends (last 24 h, hourly; overlay = same hour last week)

| Chart | Type | Series |
|---|---|---|
| Users & sessions | Line | Concurrent users, active sessions, disconnected sessions; last-week overlay (dashed) |
| Logon experience | Line plus bars | Avg and P90 logon duration (line); logon failure % (bars, right axis) |
| Logon phases | Stacked bar per hour | Brokering, VM start, HDX, Authentication, GPO, Scripts, Profile load, Interactive |
| App launches | Stacked bar | Successful versus failed launches; failure % line |
| VDA resources | Small multiples | CPU avg/p95, memory avg/p95, disk free min, Load Index avg/p95 |
| Cloud Connector health | Step line per connector | Healthy (1) or unhealthy (0), plus CPU and memory |
| Internal vs external | Line | Connection success % and connection count by path |
| Capacity forecast (next 24 h) | Line with band | Forecast session demand versus available slots (incl. Autoscale max); exhaustion marker |

### 1.3 Page 3 — Application health

| Panel | Content |
|---|---|
| Top apps by usage | Top 10 by unique users, with launches, avg launch time and failure % |
| Highest failure rate | Apps with ≥20 launches/hour, ranked by failure % (launch failures plus crash/fault events) |
| Slowest launch | Top 10 by P90 launch time, with phase breakdown on drill-through |
| Degraded delivery groups | DGs with any Yellow/Red KPI: logon P90, failure %, Load Index, unregistered VDAs |

### 1.4 Page 4 — Capacity & forecast

| Field | Example | Formula |
|---|---|---|
| Current utilization | 82 % | Active + disconnected sessions ÷ (powered-on registered non-maintenance VDAs × max sessions per VDA) |
| Available capacity now | 274 sessions | Slots − sessions |
| Headroom at Autoscale max | 586 sessions | (Autoscale max machines × max sessions) − sessions |
| Projected exhaustion | ~6 h (20:00 UTC) | Forecast demand crosses headroom at Autoscale max |
| Recommended action | Raise Autoscale max to 46 | Rules table, section 6.7 |

### 1.5 Page 5+ — Operational drill-through (admins)

Per-component pages: VDA list (registration, fault state, Load Index, EC2 status), connector detail, FAS detail, App-V detail, AWS detail, alert history. Every executive tile drills down to the technical metric IDs listed in section 2.

---

## 2. Metric catalog

ID prefixes: **UX** end-user experience · **CC** Citrix Cloud/Gateway · **CN** Cloud Connectors · **VDA** XenApp VDAs · **FAS** · **APV** App-V · **AWS** · **SYN** synthetic.
"Exec" shows where the metric appears on the executive pages (Tile, Chart, Matrix, Issues, App, Cap). "—" means drill-through only.

### 2.1 End-user experience

| ID | Metric | Why it matters to users | Collection | Healthy | Warning | Critical | Exec | Alert / action |
|---|---|---|---|---|---|---|---|---|
| UX-01 | Concurrent users (distinct users with a session) | Shows how many people depend on Citrix right now | OData `Sessions` (EndDate null), distinct UserId, sampled at :00 plus hourly peak | — (context) | −40% vs same hour last week during business hours | −70% vs last week (suggests mass access failure) | Tile, Chart | Unexplained drop: run synthetics and check GWaaS |
| UX-02 | Active sessions / disconnected sessions | Load on the platform; many disconnected sessions waste capacity | OData `Sessions` ConnectionState 5 (Active), 2 (Disconnected) | Disconnected <15% | 15–25% | >25% | Tile, Chart | Review disconnect timers |
| UX-03 | Session availability % | Can users get and keep a session? | (Sessions started − sessions failed) ÷ sessions started, from `Sessions` FailureDate/FailureId | ≥99.5% | 98–99.5% | <98% | — (feeds UX-04) | Correlate with VDA/CN health |
| UX-04 | Logon success rate | Can users sign in to their apps? | 1 − (connection failures ÷ connection attempts); `ConnectionFailureLogs` + `Connections` | ≥99% | 97–99% | <97% | Tile, Chart | ALR-06 |
| UX-05 | Avg & P90 logon duration | How long people wait before they can work | `Sessions.LogOnDuration` (ms) for sessions started in the hour; non-reconnects only | Avg <30 s, P90 <45 s | Avg 30–45 s or P90 45–60 s | Avg >45 s or P90 >60 s | Tile, Chart | ALR-07; drill to UX-06 |
| UX-06 | Logon phase breakdown | Points to the cause: brokering, GPO, profile, scripts, VM start, HDX | `Connections` phase start/end timestamps + `BrokeringDuration`, `AuthenticationDuration` | Profile <10 s, GPO <5 s, Brokering <3 s | Any phase 2× its 7-day baseline | Any phase 3× baseline | Chart | Route by phase: profile → FSLogix/SMB, auth → FAS, brokering → CITRIX/CN |
| UX-07 | App launch success % (by app, by DG) | Can users open the app they clicked? | Launch attempts = `ApplicationInstances` started + session failures that had an app context; plus `ApplicationFaults`/`ApplicationErrors` | ≥99% | 97–99% | <97% (apps with ≥20 launches/h) | Tile, App | ALR-08 |
| UX-08 | App launch time (avg/P90 by app) | Slow apps hurt productivity | Session logon duration for sessions whose first app is X; synthetic SYN-04 for the true end-to-end time | P90 <40 s | 40–60 s | >60 s | App | Check App-V streaming (APV-04) and VDA load |
| UX-09 | Session reliability: auto-reconnects / hour | Network blips users "survive" but feel | `Connections` IsReconnect = true and not user-initiated; Session Reliability events | <2% of sessions | 2–5% | >5% | — | Check network path and GWaaS POP |
| UX-10 | ICA RTT (avg/P95) | Typing and screen lag | `SessionMetrics` IcaRttMS (requires an HDX policy) | P95 <150 ms | 150–250 ms | >250 ms | Chart (by path) | Compare internal/external, GWaaS POP, AWS region |
| UX-11 | Connection success % by path (internal/external) | Separates office problems from remote-access problems | `Connections` classified by ClientAddress / LaunchedViaIPAddress against the corporate CIDR list (see gaps) + SYN-05/06 | ≥98% | 95–98% | <95%, or 0 successes on a path for 10 min | Tile, Chart | ALR-01 |
| UX-12 | Failed authentication attempts | Users locked out or unable to sign in | Workspace/IdP sign-in failure logs (Entra ID/Okta) + FAS failures (FAS-04) + `ConnectionFailureLogs` category Credentials | <1% of sign-ins | 1–3% | >3%, or a spike >5× baseline | Issues | ALR-06 / ALR-09 |
| UX-13 | Published app failures by app and DG | Which business apps are broken | `ApplicationFaults`, `ApplicationErrors` (enable the "application failure monitoring" policy) grouped by ProcessName → app mapping, and DG | <0.5% of launches | 0.5–2% | >2% or new fault signature on a top-10 app | App | ALR-08 |

### 2.2 Citrix Cloud & Gateway (owner: CITRIX, monitored by us)

| ID | Metric | Why | Collection | Healthy | Warning | Critical | Exec | Action |
|---|---|---|---|---|---|---|---|---|
| CC-01 | Citrix Cloud service status | Vendor outage = broad user impact we cannot fix | Poll status.cloud.com feed (components: DaaS, Gateway, Workspace, Monitor) | Operational | Degraded / maintenance | Major outage | Matrix, Banner | Post the vendor incident in the banner; open a Citrix case |
| CC-02 | Control-plane API reachability & latency | Proxy for broker health | Timed `GET /cvad/manage/me` and an OData `$top=1` every 5 min from the monitoring host | 200, <1 s | >2 s or 1 failure | 3 consecutive failures | Matrix | Check status page; check connector outbound path |
| CC-03 | Connector ↔ Citrix Cloud connectivity | VDAs register through connectors | CN-03 run on each connector, summarized | All connectors pass | Any connector fails | All connectors in a resource location fail | Matrix | ALR-02 |
| CC-04 | GWaaS external launch success (synthetic) | Proves remote users can launch | SYN-05 from external probe(s) every 5 min | 100% | 1 of 3 recent probes failed | 2 consecutive failures from ≥2 external probes | Tile, Matrix | ALR-01 |
| CC-05 | GWaaS internal launch success (synthetic) | Proves office users can launch (also via GWaaS) | SYN-06 from an internal probe on AWS/corporate network | 100% | 1 of 3 failed | 2 consecutive failures | Matrix | ALR-01 |
| CC-06 | Gateway connection success rate (real users) | Real-user view of the gateway | UX-11 external path; connection failures with gateway/STA categories | ≥98% | 95–98% | <95% | Tile | Correlate with CC-01 |
| CC-07 | External connection volume trend | Remote-work demand; a sudden drop signals failure | Count of external-path connections per hour vs last week | ±30% | −30 to −60% | <−60% in business hours | Chart | Check synthetics |
| CC-08 | Monitor data freshness | Stale data can hide an outage | Max(`Sessions.ModifiedDate`) age at collection time | <15 min | 15–60 min | >60 min | Banner footnote | Mark tiles "stale"; Citrix case if persistent |

### 2.3 Cloud Connectors (owner: CTX-INFRA)

| ID | Metric | Why | Collection | Healthy | Warning | Critical | Exec | Action |
|---|---|---|---|---|---|---|---|---|
| CN-01 | Connectors online vs expected (per resource location) | No connectors means no new logons in that location | Local WinRM health check + Citrix Cloud connector status API (if available) | All expected online | 1 offline but ≥2 healthy remain | <2 healthy (redundancy lost); **0 = P1** | Tile, Matrix | ALR-02 / ALR-03 |
| CN-02 | Connector registration / status in Citrix Cloud | A connector can be up but not trusted by Citrix Cloud | Citrix Cloud Resource Locations / connector API; fallback: agent event logs | "Connected" | Upgrade pending >24 h | "Disconnected"/"Error" | — | Re-register or reinstall the connector |
| CN-03 | Outbound connectivity test | Proxy, firewall and DNS breaks are common causes | `Test-NetConnection` 443 + HTTPS probe to Citrix Cloud endpoints from each connector | All pass | Latency >500 ms | Any endpoint fails twice in a row | — | Check SG/NACL, proxy, DNS |
| CN-04 | CPU / memory / disk / network | Saturated connectors slow brokering and registrations | Perf counters via WinRM (or CloudWatch Agent) | CPU <70%, Mem <80%, Disk free >20% | CPU 70–85%, Mem 80–90%, Disk 10–20% | CPU >85% 15 min, Mem >90%, Disk <10% | — | ALR-12; resize the instance |
| CN-05 | Citrix service health | Stopped services break specific functions | All `Citrix*` services with StartType=Automatic must be Running | 0 stopped | 1 stopped <15 min (auto-recovery) | Any stopped >15 min, or the Remote Broker Provider service stopped | — | Restart the service; collect CDF trace |
| CN-06 | Event log errors | Early warning of trust, cert or update problems | Count of Level 1–2 events from Citrix sources, last 60 min | <5 | 5–20 | >20, or known-bad IDs | — | Review the events |
| CN-07 | Local Host Cache / outage readiness | Whether brokering would continue during a Citrix control-plane outage | Config sync service state; HighAvailabilityService event entries | Synced in last 24 h | >24 h | Sync errors | — | Validate LHC config |

### 2.4 XenApp multi-session VDAs on AWS (owner: CTX-INFRA, AWS for infrastructure)

| ID | Metric | Why | Collection | Healthy | Warning | Critical | Exec | Action |
|---|---|---|---|---|---|---|---|---|
| VDA-01 | Registered % (powered-on, non-maintenance) | Unregistered servers cannot take users | OData `Machines` CurrentRegistrationState; REST `/Machines` | ≥98% | 95–98% | <95%, or >5 newly unregistered in 15 min | Tile | ALR-04 |
| VDA-02 | Machines in maintenance mode | Capacity removed on purpose or by mistake | REST `/Machines` InMaintenanceMode | ≤ planned count | >10% of fleet | >25% outside a change window | — | Confirm against the change calendar |
| VDA-03 | Machine fault state | Failed-to-start / stuck-on-boot = provisioning issue | OData `Machines.FaultState`, `MachineFailureLogs` | 0 | 1–2 | ≥3 or >5% of fleet | — | ALR-04 / ALR-11 |
| VDA-04 | Capacity: slots available vs in use | Whether new users can get in | Σ(max sessions per VDA) for usable VDAs vs sessions | Utilization <75% | 75–90% | >90% | Tile, Cap | ALR-05 |
| VDA-05 | Session density (sessions per VDA) | Too dense = slow; too sparse = wasted cost | Sessions ÷ usable VDAs, by DG | Within design ±15% | >design +15% | At the max-sessions limit | — | Tune Load Management policy |
| VDA-06 | CPU % (avg, P95 across fleet; max per VDA) | Main driver of slow apps | OData `ResourceUtilization` + CloudWatch CPUUtilization | Fleet P95 <75% | 75–85% | >85% for 15 min, or any VDA >95% for 15 min | Chart | ALR-12 |
| VDA-07 | Memory % | Paging makes sessions freeze | OData `ResourceUtilization` UsedMemory/TotalMemory; CW Agent | <80% | 80–90% | >90% | Chart | ALR-12 |
| VDA-08 | Disk free % (C: and cache/temp) and disk queue | Full disk = logon failures and profile corruption | CW Agent `LogicalDisk % Free Space`, `Avg. Disk Queue Length` | Free >20%, queue <2 | 10–20%, queue 2–5 | <10%, or queue >5 for 15 min | Chart | ALR-12; clean up or extend EBS |
| VDA-09 | Network throughput / ENA allowance exceeded | Bandwidth caps cause HDX lag | CloudWatch NetworkIn/Out; CW Agent ethtool `bw_*_allowance_exceeded`, `pps_allowance_exceeded` | 0 allowance exceeded | >0 sustained | Rising with RTT degradation | — | Larger instance type |
| VDA-10 | Load Index (avg, P95; 0–10,000) | Citrix's own load score; drives load balancing | OData `LoadIndexes` EffectiveLoadIndex; REST `LoadIndex` | P95 <7,000 | 7,000–8,500 | >8,500, or ≥10% of VDAs at 10,000 | Chart | Scale out |
| VDA-11 | EC2 status checks | Hardware or OS hang on the host | CloudWatch `StatusCheckFailed_System/_Instance/_AttachedEBS`; `DescribeInstanceStatus` | 0 failed | 1 VDA failed | >2 VDAs, or >5% of fleet | Matrix (AWS) | ALR-11; stop/start the instance |
| VDA-12 | Power/scale events (Citrix Autoscale & AWS ASG) | Failed scale-out = capacity shortfall | `Get-ASScalingActivity` StatusCode; Citrix power action failures (REST/config logs) | 0 failed | 1 failed | ≥2 failed per hour, or failure while utilization >75% | — | ALR-11 |
| VDA-13 | Reboot / provisioning failures | Servers that don't return after a nightly reboot | `MachineFailureLogs` FailedToStart / StuckOnBoot; MCS provisioning task errors | 0 | 1–2 | ≥3 | — | Check MCS image and AWS quotas |
| VDA-14 | App crash/fault rate | Unstable apps or images | OData `ApplicationFaults` / `ApplicationErrors` per VDA and per process | <0.5% of launches | 0.5–2% | >2% or a new crash signature | App | Image or app owner fix |
| VDA-15 | Top processes by CPU/memory | Finds runaway processes | OData `ProcessUtilization` (premium, policy-enabled) top 10 | — | Single process >25% of host CPU for 30 min | >50% | — | Kill the process or fix the app |
| VDA-16 | Hours to capacity exhaustion | Advance warning before users are refused | Forecast, section 6.7 | >8 h or not within 24 h | 4–8 h | <4 h | Tile, Cap | ALR-05 |

### 2.5 FAS (owner: CTX-INFRA)

| ID | Metric | Why | Collection | Healthy | Warning | Critical | Exec | Action |
|---|---|---|---|---|---|---|---|---|
| FAS-01 | FAS service availability (per server) | Without FAS, SSO into VDAs fails | Service `CitrixFederatedAuthenticationService` Running + TCP 80 listener check | All up | 1 down, ≥1 up | All down | Tile, Matrix | ALR-09 |
| FAS-02 | Certificate issuance success rate | Failed issuance = failed logon | FAS event log (`Citrix.Authentication.FederatedAuthenticationService`) success vs failure events, last 60 min | ≥99% | 95–99% | <95%, or 0 successes with demand present | Tile | ALR-09 |
| FAS-03 | CA reachability | FAS needs the CA to issue certificates | `certutil -ping -config "<CA>"` from each FAS server; RPC/DCOM test | All CAs reply | 1 CA fails (if multiple) | All configured CAs fail | — | ALR-09; check CA service and firewall |
| FAS-04 | Authentication failures caused by FAS | Separates FAS from other auth problems | VDA Security/System logs: smart-card logon errors (Kerberos/KDC events) + FAS rule denials | <0.5% of logons | 0.5–2% | >2% | Issues | Check templates and FAS rules |
| FAS-05 | Certificate expiry: FAS authorization (RA) cert, CA cert, template certs | An expired RA cert takes all of FAS down at once | `Get-FasAuthorizationCertificate` (Status, expiry); CA certificate NotAfter | >60 days | 30–60 days | <14 days, or Status ≠ OK | Matrix | ALR-10; renew |
| FAS-06 | FAS server resources | Overload slows certificate signing | Perf counters (CPU/Mem/Disk) + FAS perf counter set (request rate, signing latency) | CPU <70%, signing <1 s | 70–85%, 1–3 s | >85%, >3 s | — | ALR-12; add a FAS server |
| FAS-07 | Redundancy / failover config | Ensures the second FAS can take over | Count healthy FAS vs GPO-listed FAS addresses (registry `HKLM\Software\Policies\Citrix\Authentication\UserCredentialService\Addresses` on VDAs) | ≥2 healthy and all listed in GPO | 1 healthy | 0 | Matrix | Fix GPO / bring a FAS server up |

### 2.6 App-V (owner: CTX-INFRA)

| ID | Metric | Why | Collection | Healthy | Warning | Critical | Exec | Action |
|---|---|---|---|---|---|---|---|---|
| APV-01 | Management server availability | Admins cannot publish changes when it is down | HTTP(S) GET to the management console URL; IIS app pool state | 200 | Slow >3 s | Down twice in a row | Matrix | Restart the app pool; check SQL |
| APV-02 | Publishing server availability | VDAs cannot refresh entitlements | HTTP(S) GET to the publishing URL returns valid XML | 200 + XML | Slow >3 s | Down twice in a row | Matrix | ALR-10a |
| APV-03 | Package publication success/failure | Users miss apps or get the wrong version | VDA `Microsoft-AppV-Client/Admin` errors on publishing refresh; Citrix "single admin" App-V events | 0 failures | 1–2 VDAs failing | ≥3 VDAs, or any top-10 app package | — | Re-sync publishing |
| APV-04 | Streaming / mounting failures | App fails to open or opens slowly | VDA `Microsoft-AppV-Client/Admin` + `/Operational` error events by package | 0 | 1–5 / hour | >5 / hour, or ≥3 VDAs on the same package | App | Check content share (SMB), package integrity |
| APV-05 | Launch failures tied to App-V packages | Business-app impact | Join UX-13 process names to the App-V package inventory | 0 | Any | >2% of that app's launches | App | Owner: app packaging |
| APV-06 | Server resources + content share | Saturated share = slow streaming | Perf counters; share free space; SMB latency | Free >20% | 10–20% | <10% | — | Extend storage |

### 2.7 AWS infrastructure (owner: AWS)

| ID | Metric | Why | Collection | Healthy | Warning | Critical | Exec | Action |
|---|---|---|---|---|---|---|---|---|
| AWS-01 | EC2 health (all Citrix-tagged instances) | Unhealthy hosts drop sessions | `DescribeInstanceStatus`, CloudWatch status-check metrics | 0 impaired | 1 impaired VDA | Impaired connector or FAS, or >2 VDAs | Matrix | ALR-11 |
| AWS-02 | AZ / regional status | AZ failure removes a share of capacity | AWS Health API (`DescribeEvents`, needs Business/Enterprise support) for EC2/EBS/VPC in the region | No events | Open issue (not our AZ) | Open issue in an AZ we use | Matrix, Banner | Move capacity to a healthy AZ |
| AWS-03 | ASG health (if ASGs are used) | Failed launches block scale-out | `DescribeAutoScalingGroups`, `DescribeScalingActivities` | Desired = InService | Activity failed once | Repeated failures / InService < Desired for 15 min | — | ALR-11; check quotas, AMI, subnet IPs |
| AWS-04 | EBS volume health | Storage stalls freeze VDAs | `DescribeVolumeStatus`; CloudWatch `VolumeStalledIOCheck`, `VolumeQueueLength`, `BurstBalance` (gp2) | Status ok, BurstBalance >50% | Burst 20–50%, queue >4 | Impaired / stalled / Burst <20% | — | Move to gp3, raise IOPS |
| AWS-05 | EBS IOPS / throughput vs provisioned | Throttled disks = slow logons | CloudWatch `VolumeReadOps/WriteOps/Bytes` vs provisioned gp3 IOPS/MBps | <70% | 70–90% | >90% for 15 min | — | Raise gp3 IOPS |
| AWS-06 | Network health indicators | Packet loss = HDX disconnects | ENA allowance metrics; VPC NAT GW `PacketsDropCount`, `ErrorPortAllocation`; Transit GW/VPN tunnel state | 0 drops | Drops >0 | Tunnel down / sustained drops | — | Network team |
| AWS-07 | Subnet free IPs | Scale-out fails when subnets run out of addresses | `DescribeSubnets` AvailableIpAddressCount | >20% free | 10–20% | <10% | — | Add a subnet |
| AWS-08 | Cost anomalies / unexpected instance growth | Runaway scaling or forgotten machines | Running Citrix-tagged instance count vs 7-day max for the same hour; AWS Cost Anomaly Detection | Within +10% | +10–25% | >+25%, or instances with no Citrix machine record | Matrix | Check Autoscale config, orphaned VMs |
| AWS-09 | Capacity & scaling trend | Planning: instance quotas, reserved/Savings Plans fit | Daily peak instances vs vCPU service quota | <70% of quota | 70–85% | >85% | Cap | Request a quota increase |

### 2.8 Synthetic user-experience tests

| ID | Test | Probe locations | Frequency | Pass criteria | Critical |
|---|---|---|---|---|---|
| SYN-01 | Workspace URL reachable & TLS valid | Internal + external | 5 min | HTTP 200, certificate >14 days to expiry, <3 s | 2 consecutive failures |
| SYN-02 | Sign-in (service account) | Internal + external | 15 min | Authenticated in <10 s | 2 consecutive failures |
| SYN-03 | App enumeration | Internal + external | 15 min | ≥ expected app count for the test user | Missing apps or failure |
| SYN-04 | Published app launch (ICA) | Internal + external | 15 min (5 min for critical apps) | Session established and app window detected in <60 s | 2 consecutive failures |
| SYN-05 | External path via GWaaS | ≥2 external probes (different networks) | 5 min | SYN-01 + SYN-04 pass | ≥2 probes fail twice in a row → ALR-01 |
| SYN-06 | Internal path via GWaaS | Internal probe (AWS VPC and/or office) | 5 min | As above | 2 consecutive failures |

---

## 3. Alert definitions

Notification channels: **P1 page** = PagerDuty/Opsgenie + SMS to the on-call engineer + Teams #citrix-incidents · **Teams** = Teams #citrix-alerts webhook · **Email** = daily digest to the CTX-INFRA distribution list. Critical alerts also post the executive impact statement to the dashboard banner.

| ID | Alert | Severity | Trigger condition | Eval freq. | Channel | Runbook action | Executive impact statement |
|---|---|---|---|---|---|---|---|
| ALR-01 | Total loss of external connectivity via GWaaS | Critical | SYN-05 fails on ≥2 external probes for 2 consecutive runs **and/or** external connections = 0 for 10 min during business hours | 5 min | P1 page | 1) Check status.cloud.com (Gateway). 2) Test from a 3rd network. 3) Validate Workspace URL DNS/TLS. 4) If Citrix-side: open a Sev1 Citrix case. 5) If only the internal path works, tell remote users. | "Remote users cannot open Citrix apps. Office users may be unaffected." |
| ALR-01b | External connection success degraded | Warning | UX-11 external <95% for 1 h, or SYN-05 single-probe failures | Hourly | Teams | Compare with internal; check RTT by region | "Some remote users are having trouble connecting." |
| ALR-02 | All Cloud Connectors offline in a resource location | Critical | CN-01 healthy count = 0 for any resource location for 2 consecutive checks | 5 min | P1 page | 1) Check the EC2 instances. 2) Check outbound 443/proxy. 3) Restart Citrix services. 4) Confirm LHC/brokering state. | "New logons in <location> will fail; existing sessions continue for now." |
| ALR-03 | Fewer than two healthy Cloud Connectors | Warning (Critical if outage overlaps business hours >1 h) | CN-01 healthy count = 1 for any resource location | 5 min | Teams (P1 if escalated) | Restore the failed connector; check pending upgrades | "Citrix access works, but we have no backup connector. One more failure causes an outage." |
| ALR-04 | VDA registration failure spike | Critical / Warning | Critical: registered % <95% or ≥5 VDAs deregister in 15 min. Warning: 95–98% | 5 min | P1 / Teams | 1) Group by DG/AZ. 2) Check connectors (CN-01). 3) Check DNS/time/AD. 4) Read the deregistration reason. | "Fewer servers are available; some users may wait or be refused." |
| ALR-05 | VDA capacity exhaustion risk | Critical / Warning | Critical: utilization >90% or hours-to-exhaustion <4. Warning: >75% or <8 h | Hourly (5 min when >85%) | P1 / Teams | Raise Autoscale max / power on spares; check for stuck or maintenance VDAs | "We may run out of capacity in about N hours; new users could be refused." |
| ALR-06 | Logon failure rate above threshold | Critical / Warning | Critical: UX-04 <97% (≥50 attempts) in the hour or 15-min window. Warning: 97–99% | 15 min | P1 / Teams | Check failure categories: capacity → ALR-05; credential → FAS/IdP; machine → VDA; config → recent changes | "N% of logon attempts are failing." |
| ALR-07 | Average logon duration above threshold | Warning / Critical | Warning: avg >30 s or P90 >45 s for 1 h. Critical: avg >45 s or P90 >60 s for 1 h | Hourly | Teams / P1 (Critical, business hours) | Drill into phases (UX-06): profile → FSLogix/SMB; GPO → GP changes; auth → FAS; brokering → CITRIX/CN | "Logons are taking N seconds instead of the 30 s target." |
| ALR-08 | Application launch failure rate above threshold | Warning / Critical | Per app with ≥20 launches/h: Warning 1–3%, Critical >3% or any top-10 app >2% | Hourly | Teams / P1 | Check app faults, App-V package, DG health | "<App> fails to open for N% of users." |
| ALR-09 | FAS unavailable or certificate issuance failing | Critical | All FAS servers down, **or** issuance success <95% (≥10 requests), **or** all CAs unreachable | 5 min | P1 page | 1) Check the FAS service. 2) Run certutil -ping against the CA. 3) Check RA cert status. 4) Fail over the GPO list. | "Users cannot complete sign-in to Citrix apps (single sign-on is failing)." |
| ALR-09b | FAS redundancy lost | Warning | 1 FAS healthy out of ≥2 | 5 min | Teams | Restore the second server | "Sign-in works but has no backup." |
| ALR-10 | FAS/CA certificate near expiry | Warning (<60 d) / Critical (<14 d or Status ≠ OK) | FAS-05 | Daily | Email / Teams | Renew the RA cert and update the FAS authorization | "Planned work required before <date> to avoid a sign-in outage." |
| ALR-10a | App-V publishing failures | Warning / Critical | Warning: publishing server slow, or 1–2 VDAs failing refresh. Critical: publishing server down twice in a row, or ≥3 VDAs / a top-10 app failing | 15 min | Teams / P1 | Check IIS and SQL; re-sync; validate the content share | "Some packaged apps may be missing or fail to open." |
| ALR-11 | AWS instance or Auto Scaling failure | Warning / Critical | Warning: 1 VDA status-check failure, or 1 failed scaling activity. Critical: connector/FAS impaired, >2 VDAs impaired, AZ event, or scale-out failing while utilization >75% | 5 min | Teams / P1 | Stop/start the instance; check quotas, subnet IPs, AMI; AWS case if hardware | "A cloud infrastructure problem is reducing Citrix capacity." |
| ALR-12 | Resource saturation (VDA, Connector, FAS) | Warning / Critical | Thresholds in CN-04, VDA-06/07/08, FAS-06, sustained 15 min | 5 min | Teams / P1 (Critical on connector or FAS) | Identify the process (VDA-15), drain or replace the VDA, resize the server | Usually informational to executives unless user KPIs degrade |
| ALR-13 | Citrix Cloud vendor incident | Informational / Critical | CC-01 not "Operational" for a component we use; Critical if user KPIs also degrade | 5 min | Teams (P1 if KPIs degrade) | Track the vendor ETA; communicate to users | "Citrix (the vendor) is reporting a service problem: <summary>." |
| ALR-14 | Monitoring data stale | Warning | CC-08 >60 min, or any collector job fails twice | Hourly | Teams | Check collector host, credentials, API rate limits | "Dashboard data may be out of date." |
| ALR-15 | Unexpected instance growth (cost) | Informational / Warning | AWS-08 >+25% | Hourly | Email / Teams | Review Autoscale and orphaned machines | "Cloud spend is trending above normal." |

**Alert hygiene:** de-duplicate on (AlertId, Component, Scope) while an alert is open. Auto-resolve after 2 consecutive healthy evaluations. Suppress during maintenance windows (`config/maintenance.json`). Hold Warning-level alerts that depend on a component that is already Critical. For example, while ALR-02 is open, suppress ALR-04 for that location.

---

## 4. Data-source mapping

| Source | Access method | Data obtained | Feeds metrics | Cadence | Notes |
|---|---|---|---|---|---|
| **Citrix Monitor OData v4** (`https://api[-eu/-ap-s].cloud.com/monitorodata/`) | OAuth2 client credentials (Citrix Cloud API client) → `Authorization: CwsAuth Bearer=<token>`, headers `Citrix-CustomerId`, `Citrix-InstanceId` | `Sessions`, `Connections`, `ConnectionFailureLogs`, `Machines`, `MachineFailureLogs`, `ResourceUtilization`, `LoadIndexes`, `ProcessUtilization`, `ApplicationInstances`, `Applications`, `ApplicationFaults`, `ApplicationErrors`, `SessionMetrics`, `DesktopGroups`, `Users`, `LogOnSummaries` | UX-01..13, VDA-01/03/06/07/10/13/14/15, CC-08 | Hourly (incremental window); key counts every 5 min | Respect the API rate limits and use `$select`/`$filter`. Retention depends on licence edition. Process/app-failure data needs policies enabled. |
| **Citrix DaaS REST (CVAD Manage)** (`https://api.cloud.com/cvad/manage/`) | Same token + `Citrix-InstanceId` | `/Machines`, `/DeliveryGroups`, `/MachineCatalogs`, `/Applications`, `/Zones` | VDA-01/02/04/05/10/12, UX-07 (app enabled state), capacity config | Hourly; `/Machines` every 5 min for the alert path | Paginate with `ContinuationToken`. Store DG max-sessions settings for capacity. |
| **Citrix Cloud platform APIs** (resource locations / connectors) | Same token | Connector status, version, resource location | CN-01/02 | 5 min | Verify the endpoint for your tenant (see gaps); the WinRM check is the primary source |
| **status.cloud.com** | HTTPS poll of the status feed | Vendor incidents per component | CC-01, ALR-13 | 5 min | Also subscribe the on-call mailbox |
| **AWS CloudWatch** (`GetMetricData`) | IAM role on the collector (read-only) | AWS/EC2, AWS/EBS, CWAgent (memory, disk, ENA), AWS/NATGateway | VDA-06..09/11, AWS-01/04/05/06 | Hourly (1-min/5-min stats aggregated); 5-min for status checks | One `GetMetricData` call can include up to 500 queries |
| **AWS EC2 / AutoScaling / Health / Cost APIs** | AWS.Tools PowerShell | Instance status, volume status, scaling activities, subnet IPs, AZ events, cost anomalies | AWS-01..09, VDA-12 | Hourly; status every 5 min | Health API needs Business/Enterprise support |
| **CloudWatch Agent on VDAs** | Agent config (SSM Parameter Store) | Memory %, LogicalDisk free %, disk queue, ENA ethtool metrics; optional Windows event log streaming to CW Logs | VDA-07/08/09, APV-03/04 | 1-min | Push model scales better than WinRM to a large VDA fleet |
| **Windows perf counters & event logs** (Connectors, FAS, App-V servers) | PowerShell remoting (WinRM, Kerberos) from the collector, or SSM Run Command | CPU/Mem/Disk/Net, service state, event counts, FAS cert status, certutil ping, App-V HTTP checks | CN-03..07, FAS-01..07, APV-01..06 | 5 min (availability), hourly (resources/events) | Small fixed server count, so remoting is fine |
| **Identity provider logs** (Entra ID / Okta / AD) | Graph API sign-in logs / Okta System Log | Workspace sign-in failures | UX-12 | Hourly | Depends on the Workspace auth method (see gaps) |
| **Synthetic probes** | Scheduled task on probe hosts; commercial tool optional | Pass/fail + timings per step | SYN-01..06, CC-04/05, UX-08 | 5–15 min | ≥2 external probes on different networks |

---

## 5. Technology & architecture

### 5.1 Recommendation

| Layer | Recommendation | Why |
|---|---|---|
| Collectors | **PowerShell 7** scripts (this repo) on a dedicated, hardened **monitoring EC2** (Windows, t3.medium) in the Citrix VPC, run by Windows Task Scheduler | Windows-native access to WinRM, FAS cmdlets, certutil and AWS.Tools. No extra platform to run. |
| Secrets | **AWS Secrets Manager** (Citrix API client secret, SQL credentials) read with the instance role | No secrets on disk. Rotate the Citrix client secret every 90 days. |
| Storage | **Amazon RDS for SQL Server** (or an existing SQL Server). Schema `mon`. Hourly fact tables plus a 5-min `HealthCheck` table. 13 months of hourly data, 30 days of 5-min data. | Power BI connects natively, the volume is small (<5 GB/year), and the team already knows T-SQL |
| Executive dashboard | **Power BI** (Service, hourly scheduled refresh via an on-premises data gateway on the monitoring EC2, or Import with 8×/day on Pro, hourly on Premium/PPU) | Executive-friendly, works on mobile and in Teams, supports row-level ownership filters |
| Ops dashboard (optional) | **Grafana** (Amazon Managed Grafana) on the same SQL + CloudWatch data sources, 5-min refresh | Live drill-down for admins without Power BI refresh limits |
| Alerting | `Invoke-AlertEvaluation.ps1` (rules in `config/thresholds.json`) → `AlertHistory` → **Teams webhook** + **PagerDuty Events v2** (or Opsgenie). **CloudWatch Alarms → SNS** as an independent backstop for EC2 status checks of connectors and FAS. | One rule engine with de-duplication and ownership attribution. The CloudWatch backstop keeps working if the collector host fails. |
| Automation | Phase 3: SSM Automation / Citrix REST actions triggered by specific alerts (restart a connector service, put a broken VDA into maintenance mode and restart it, power on spare VDAs) | Safe, auditable, reversible |
| Watchdog | A CloudWatch alarm on the collector heartbeat metric (`CitrixMon/CollectorHeartbeat`), plus ALR-14 | Detects a failed monitoring system |

### 5.2 Architecture

```
                         Citrix Cloud (CITRIX-managed)
   ┌───────────────────────────────────────────────────────────────────┐
   │  Monitor OData v4     CVAD REST     Connector/RL API   status feed│
   └──────────▲───────────────▲──────────────▲──────────────────▲──────┘
              │ HTTPS 443 (OAuth2 client credentials)           │
┌─────────────┴───────────────┴──────────────┴──────────────────┴─────────────────┐
│ AWS VPC (customer-managed)                                                       │
│  ┌──────────────────────────────── Monitoring EC2 ───────────────────────────┐   │
│  │ Task Scheduler                                                            │   │
│  │  every 5 min : Invoke-FastChecks  (connectors, FAS, VDA reg, SYN, status) │   │
│  │  hourly :05  : Invoke-HourlyRun   (OData, REST, CloudWatch, WinRM, rollup)│   │
│  │  every 5 min : Invoke-AlertEvaluation → Teams / PagerDuty                 │   │
│  │  daily 00:30 : ExecutiveDailyRollup, cert expiry, retention purge         │   │
│  └───────┬──────────────────────┬─────────────────────┬──────────────────────┘   │
│   WinRM  │               AWS APIs│(IAM role)       SQL│1433                       │
│  ┌───────▼────────┐  ┌───────────▼──────────┐  ┌──────▼──────────┐               │
│  │Cloud Connectors│  │CloudWatch / EC2 / ASG│  │ RDS SQL Server  │◄── Power BI GW │
│  │FAS · App-V     │  │Health / Cost / EBS   │  │ schema "mon"    │◄── Grafana     │
│  └────────────────┘  └───────────▲──────────┘  └─────────────────┘               │
│  ┌────────────────┐              │ CW Agent (memory/disk/ENA/event logs)         │
│  │ XenApp VDAs    ├──────────────┘                                               │
│  └────────────────┘                                                              │
└──────────────────────────────────────────────────────────────────────────────────┘
   External synthetic probes (≥2 networks) ──HTTPS──► Workspace / GWaaS ──► results to SQL (API/HTTPS)
```

### 5.3 Health roll-up logic (banner and matrix)

1. Each metric evaluates to Green, Yellow or Red against `config/thresholds.json`.
2. **Component status** = the worst status among that component's *availability* metrics. Resource-only metrics (CPU and similar) can raise a component to at most Yellow, unless a related user KPI is also Yellow or Red.
3. **Overall status**:
   - **Red** if any Critical alert is open on a user-path component (GWaaS, Cloud Control Plane, Connectors, FAS, VDA availability/capacity), or if any user KPI (UX-04, UX-07, UX-11) is Red.
   - **Yellow** if any Warning alert is open, or any KPI is Yellow.
   - **Green** otherwise.
4. **One-sentence status** is generated from a template: `<availability phrase>. <worst KPI phrase> for <scope>; <action in progress>.` The phrases come from the executive impact statements of the highest-severity open alert.

### 5.4 Traceability (executive tile → technical metric)

| Executive tile | Primary metric | Drill-through metrics |
|---|---|---|
| Active users / sessions | UX-01, UX-02 | DG breakdown, VDA-05 |
| Logon success rate | UX-04 | UX-03, UX-12, failure categories, FAS-02, VDA-01, CN-01 |
| Avg logon duration | UX-05 | UX-06 phases, VDA-06/07/08, FAS-06, APV-04 |
| App launch success | UX-07 | UX-13, VDA-14, APV-05, SYN-04 |
| External connection success | UX-11 (external) | CC-04, CC-06, CC-07, UX-10, CC-01 |
| VDA availability | VDA-01 | VDA-02/03/11/13, CN-01 |
| Cloud Connector availability | CN-01 | CN-02..07 |
| FAS availability | FAS-01 + FAS-02 | FAS-03..07 |
| Capacity utilization | VDA-04 | VDA-10/12/16, AWS-03/07/09 |
| Open critical alerts | AlertHistory | Alert detail with runbook link |

---

## 6. Hourly collection logic

The production implementation is in `collectors/`. The queries and pseudocode below are the reference.

### 6.1 Authentication (all Citrix calls)

```http
POST https://api.cloud.com/cctrustoauth2/{customerId}/tokens/clients
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials&client_id={id}&client_secret={secret}
```
Use `access_token` as `Authorization: CwsAuth Bearer=<token>`. Add `Citrix-CustomerId: {customerId}` and, for the CVAD and Monitor APIs, `Citrix-InstanceId: {siteId}`. The siteId comes from `GET /cvad/manage/me`. Tokens last about 1 hour, so cache and refresh them.

### 6.2 Hourly window

```
$end   = floor(UtcNow to the hour)      # e.g. 14:00:00Z
$start = $end - 1h                      # 13:00:00Z
# Collector runs at :05 so Monitor has ingested the late data. It also re-collects the
# previous hour (idempotent delete+insert) to pick up late-arriving records.
```

### 6.3 Citrix Monitor OData v4 queries

Base: `https://api.cloud.com/monitorodata/`. All `$filter` dates are ISO-8601 UTC without quotes.

| Purpose | Query |
|---|---|
| **Active sessions (now)** | `Sessions?$filter=EndDate eq null and ConnectionState eq 5&$count=true&$top=1&$select=SessionKey` → read `@odata.count` |
| Disconnected sessions | `Sessions?$filter=EndDate eq null and ConnectionState eq 2&$count=true&$top=1&$select=SessionKey` |
| Concurrent users + per-DG sessions | `Sessions?$filter=EndDate eq null and (ConnectionState eq 5 or ConnectionState eq 2)&$select=SessionKey,UserId,ConnectionState&$expand=Machine($select=DesktopGroupId)` → distinct UserId, group by DG |
| **Logon duration** (sessions started in window) | `Sessions?$filter=StartDate ge {start} and StartDate lt {end} and LogOnDuration ne null&$select=SessionKey,LogOnDuration,UserId&$expand=Machine($select=DesktopGroupId),CurrentConnection($select=IsReconnect,ClientAddress,BrokeringDuration,AuthenticationDuration,GpoStartDate,GpoEndDate,ProfileLoadStartDate,ProfileLoadEndDate,LogOnScriptsStartDate,LogOnScriptsEndDate,InteractiveStartDate,InteractiveEndDate,HdxStartDate,HdxEndDate,VMStartStartDate,VMStartEndDate)` |
| Connection attempts (denominator) | `Connections?$filter=BrokeringDate ge {start} and BrokeringDate lt {end}&$select=Id,IsReconnect,ClientAddress,LaunchedViaIPAddress,SessionKey` |
| **Failed logons / connections** | `ConnectionFailureLogs?$filter=FailureDate ge {start} and FailureDate lt {end}&$select=SessionKey,FailureDate,ConnectionFailureEnumValue,UserId&$expand=Machine($select=Name,DesktopGroupId)` |
| Session failures with category | `Sessions?$filter=FailureDate ge {start} and FailureDate lt {end}&$select=SessionKey,FailureId,FailureDate&$expand=Failure($select=Category),Machine($select=DesktopGroupId)` (category: 1 client/connection, 2 machine, 3 no capacity, 4 no license, 5 configuration) |
| **VDA machine state** | `Machines?$filter=LifecycleState eq 0&$select=Id,Name,DnsName,DesktopGroupId,CatalogId,CurrentRegistrationState,FaultState,IsInMaintenanceMode,CurrentPowerState,CurrentSessionCount,CurrentLoadIndexId,HostedMachineName` |
| **VDA machine failures** | `MachineFailureLogs?$filter=FailureStartDate ge {start} and FailureStartDate lt {end}&$select=MachineId,FailureStartDate,FailureEndDate,FaultState&$expand=Machine($select=Name,DesktopGroupId)` |
| **VDA CPU & memory** | `ResourceUtilization?$filter=CollectedDate ge {start} and CollectedDate lt {end}&$select=MachineId,CollectedDate,PercentCpu,UsedMemory,TotalMemory,SessionCount` → per machine avg/max; fleet avg/P95 |
| **Load Index** | `LoadIndexes?$filter=CreatedDate ge {start} and CreatedDate lt {end}&$select=MachineId,CreatedDate,EffectiveLoadIndex,Cpu,Memory,Disk,Network,SessionCount` |
| Process utilization | `ProcessUtilization?$filter=CollectedDate ge {start} and CollectedDate lt {end}&$select=ProcessName,PercentCpu,UsedMemory,MachineId&$orderby=PercentCpu desc&$top=200` |
| **App launches** | `ApplicationInstances?$filter=StartDate ge {start} and StartDate lt {end}&$select=Id,StartDate,SessionKey&$expand=Application($select=Id,Name,PublishedName),Session($select=LogOnDuration,UserId;$expand=Machine($select=DesktopGroupId))` |
| **Application failures** | `ApplicationFaults?$filter=FaultReportingDate ge {start} and FaultReportingDate lt {end}&$select=ProcessName,MachineId,FaultReportingDate` and `ApplicationErrors?$filter=ErrorReportingDate ge {start} and ErrorReportingDate lt {end}&$select=ProcessName,MachineId,ErrorReportingDate` |
| ICA RTT | `SessionMetrics?$filter=CollectedDate ge {start} and CollectedDate lt {end}&$select=SessionId,IcaRttMS,CollectedDate` |
| Data freshness | `Sessions?$orderby=ModifiedDate desc&$top=1&$select=ModifiedDate` |

Pagination: follow `@odata.nextLink` until it is absent. For large tenants, split the hour into 15-min windows.

### 6.4 Citrix DaaS REST

```
GET /cvad/manage/Machines?limit=1000[&continuationToken=...]
    → Name, DeliveryGroup.Name, RegistrationState, InMaintenanceMode, PowerState,
      SessionCount, LoadIndex, FaultState, LastDeregistrationReason, Zone.Name
GET /cvad/manage/DeliveryGroups      → Name, Enabled, InMaintenanceMode, TotalMachines,
                                       Sessions, (session limit per machine from the load policy)
GET /cvad/manage/Applications        → Name, Enabled, Visible, DeliveryGroups
GET /cvad/manage/Zones               → resource location ↔ zone mapping
```

### 6.5 AWS CloudWatch (one batched call)

```powershell
$q = foreach ($i in $citrixInstances) {
  @{ Id="cpu_$n";  MetricStat=@{Metric=@{Namespace='AWS/EC2';MetricName='CPUUtilization';
       Dimensions=@(@{Name='InstanceId';Value=$i})}; Period=300; Stat='Average'} }
  @{ Id="sck_$n";  ... MetricName='StatusCheckFailed' ... Stat='Maximum' }
  @{ Id="mem_$n";  Namespace='CWAgent'; MetricName='Memory % Committed Bytes In Use' ... }
  @{ Id="dsk_$n";  Namespace='CWAgent'; MetricName='LogicalDisk % Free Space' (instance=C:) ... Stat='Minimum' }
}
Get-CWMetricData -MetricDataQuery $q -UtcStartTime $start -UtcEndTime $end
Get-EC2InstanceStatus -IncludeAllInstance $true -Filter @{Name='tag:CitrixRole';Values='*'}
Get-ASScalingActivity -AutoScalingGroupName $asg -MaxRecord 50   # StatusCode -ne 'Successful'
Get-EC2VolumeStatus ; Get-EC2Subnet ; Get-HLTHEvent (us-east-1 endpoint)
```

### 6.6 Windows (connectors, FAS, App-V) via WinRM

```powershell
Invoke-Command -ComputerName $servers -ScriptBlock {
  $c = Get-Counter '\Processor(_Total)\% Processor Time','\Memory\% Committed Bytes In Use',
                   '\LogicalDisk(C:)\% Free Space','\Network Interface(*)\Bytes Total/sec' -SampleInterval 5 -MaxSamples 3
  $svc = Get-CimInstance Win32_Service -Filter "StartMode='Auto'" | ? { $_.DisplayName -like 'Citrix*' -and $_.State -ne 'Running' }
  $ev  = Get-WinEvent -FilterHashtable @{LogName='Application','System'; Level=1,2; StartTime=(Get-Date).AddHours(-1)} -EA 0
  # Role-specific: FAS → Get-FasAuthorizationCertificate, certutil -ping; App-V → HTTP probe of publishing URL
}
```

### 6.7 Capacity forecast (pseudocode)

```
slots_now      = Σ over usable VDAs (registered, powered-on, not maintenance) of MaxSessionsPerVDA[DG]
slots_max      = Σ over DGs of AutoscaleMaxMachines[DG] × MaxSessionsPerVDA[DG]   (falls back to slots_now)
demand_t       = sessions (active + disconnected) per hour, last 14 days
baseline(h)    = median(demand at the same weekday+hour over the last 4 weeks)
trend_ratio    = mean(demand_last_3h / baseline_last_3h)          # today vs normal
forecast(h+k)  = baseline(h+k) × trend_ratio                       # k = 1..24
exhaust_hours  = first k where forecast(h+k) > slots_max × 0.95  (else null)
autoscale_lag  = first k where forecast(h+k) > slots_now   (shows when Autoscale must add VDAs)
recommendation =
   exhaust_hours < 4  → "Raise Autoscale max / power on N spares now"       N = ceil((peak_forecast − slots_max×0.9)/MaxSessions)
   exhaust_hours < 8  → "Schedule capacity increase before <time>"
   utilization < 40% at forecast peak for 7 days → "Reduce Autoscale min (cost)"
```
Phase 2 can replace the seasonal-naive model with Prophet or SQL linear regression once 8+ weeks of history exist.

### 6.8 Synthetic test (pseudocode)

```
for each probe in [internal-aws, external-1, external-2]:
  t0; GET https://<tenant>.cloud.com         → assert 200, TLS cert valid, latency
  sign-in with service account (non-MFA, conditional access limited to probe IPs)
  GET Workspace store resources              → assert expected apps present
  request ICA for test app → launch via Workspace app (wfica32 / Login Enterprise)
  wait for window "<TestApp>" or a marker file written by a VDA logon script ≤ 60 s
  logoff; post {probe, path, step timings, pass/fail} to mon.SyntheticResult
```
`collectors/Invoke-SyntheticTests.ps1` implements the reachability/TLS tier and the result plumbing. Full sign-in and launch use a commercial engine (recommended: Login Enterprise, ControlUp Scoutbees or Goliath) whose results the script ingests through a common schema.

---

## 7. 30 / 60 / 90-day roadmap

| Window | Phase | Deliverables | Exit criteria |
|---|---|---|---|
| **Days 0–30** | **Phase 1: Core availability & user experience** | Citrix API client and siteId; monitoring EC2, Secrets Manager, RDS schema (`sql/schema.sql`); OData + REST collectors (sessions, logons, connection failures, machines); connector WinRM checks; status-feed poll; external HTTP/TLS synthetic from 2 probes; alerts ALR-01/02/03/04/06/07/13/14; Power BI pages 1 & 3 (banner, KPIs, matrix, top issues, app health); CloudWatch backstop alarms for connector/FAS EC2 | Dashboard refreshes hourly for 7 consecutive days; each Critical alert test-fired in a game day; executives sign off on wording and thresholds |
| **Days 31–60** | **Phase 2: Capacity, performance & forecasting** | CloudWatch Agent on VDAs via SSM; CloudWatch collector (EC2/EBS/ENA/ASG/subnets/Health); ResourceUtilization, LoadIndexes, ProcessUtilization; capacity model + 24 h forecast; alerts ALR-05/11/12/15; trend and capacity pages; thresholds re-baselined on 30 days of data (switch logon thresholds to baseline-relative); Grafana ops view | Forecast within ±15% of actual peak on 80% of weekdays; false-positive rate <1 per week per alert |
| **Days 61–90** | **Phase 3: FAS, App-V, synthetic launch & automated remediation** | FAS checks (service, issuance, CA ping, RA cert expiry); App-V checks (management/publishing, client event channels); full synthetic sign-in/enumerate/launch internal + external every 15 min; alerts ALR-08/09/09b/10/10a; automated remediation (SSM: restart connector services; Citrix REST: maintenance mode + restart for VDAs unregistered >15 min; power on spare VDAs on ALR-05) with approval gate and audit; ExecutiveDailyRollup email; runbooks published | Synthetic launch MTTD <10 min; ≥50% of VDA registration incidents remediated automatically; monthly executive report generated from ExecutiveDailyRollup |

---

## 8. Assumptions & gaps to confirm

| # | Item | Assumption made | Confirm / decision needed |
|---|---|---|---|
| 1 | Citrix licence edition | Premium/Advanced Plus, which gives Monitor OData retention and ProcessUtilization | Edition and Monitor retention (affects ProcessUtilization and app-failure data) |
| 2 | Monitor policies | The policies for process monitoring, application failure monitoring and ICA RTT are enabled | Enable them in the Citrix policy if not; validate entity/field names against your tenant `$metadata` |
| 3 | API region | US control plane (`api.cloud.com`) | EU/APS tenants use `api-eu.cloud.com` / `api-ap-s.cloud.com` |
| 4 | Connector status API | A Citrix Cloud API exposes connector status per resource location | Confirm the endpoint and permissions for your tenant. Until then the WinRM check plus the Citrix Cloud console are authoritative. |
| 5 | Internal vs external classification | All users go through GWaaS, so the path is classified by **client IP ranges** (`config/settings.json → InternalClientCidrs`) | Confirm what `ClientAddress` shows via GWaaS in your tenant (client-reported LAN IP versus public egress). If it is ambiguous, rely on synthetic paths and Workspace/IdP logs. Also confirm whether internal users really use GWaaS or a direct path. |
| 6 | Workspace authentication | Entra ID (or another SAML IdP) + FAS for SSO into VDAs | IdP type, and whether sign-in logs can be exported for UX-12 |
| 7 | Synthetic service account | A non-MFA account restricted by conditional access to probe IPs is allowed | Security approval, or use a commercial tool that supports MFA (TOTP) |
| 8 | Scaling mechanism | Citrix Autoscale power-manages MCS VDAs. AWS ASGs may exist for other workloads only. | Autoscale vs AWS ASG vs custom; Autoscale min/max per DG for capacity |
| 9 | Max sessions per VDA | Taken from the Load Management policy, recorded in `config/settings.json → DeliveryGroups` | The actual value per DG |
| 10 | Resource locations / connectors | ≥2 connectors per resource location, tagged `CitrixRole=CloudConnector` in EC2 | Inventory and AZ placement (connectors should be in different AZs) |
| 11 | App-V model | App-V Management/Publishing servers (full infrastructure), not only Citrix single-admin App-V from a share | Which model; publishing URL; content share path |
| 12 | FAS topology | 2+ FAS servers, enterprise CA(s), FAS addresses distributed by GPO | Server/CA names; whether `Citrix.Authentication.FederatedAuthenticationService.V1` is installed on the FAS hosts |
| 13 | AWS support plan | Business or Enterprise, so the AWS Health API is available | If not, use the AWS Health Dashboard RSS and EC2 scheduled events only |
| 14 | Network | WinRM (5985/5986) open from the monitoring host to connectors/FAS/App-V; outbound 443 to Citrix Cloud and AWS APIs | Firewall/SG approval |
| 15 | Business hours / time zone | Thresholds marked "business hours" = Mon–Fri 07:00–19:00 in the primary user time zone | Hours and time zone for the dashboard (stored data stays UTC) |
| 16 | Notification tooling | Teams + PagerDuty | Actual tools (ServiceNow incident creation is a common addition) |
| 17 | Power BI licensing | Pro (8 refreshes/day) is not enough for hourly refresh | Premium/PPU/Fabric capacity for hourly refresh, or DirectQuery against SQL |
| 18 | Thresholds | Industry-typical starting values | Re-baseline after 30 days; agree executive SLOs (e.g. logon success 99%, logon P90 <45 s) |
| 20 | Citrix status feed | `StatusFeedUrl` points to an RSS feed of status.cloud.com incidents, parsed with keyword heuristics | Confirm the feed URL/format your tenant's status page publishes and tune the parser in `Invoke-FastChecks.ps1` |
| 21 | FAS issuance event IDs | Unknown until checked, so the issuance rate shows no data and all FAS Error events count as failures | Read the FAS Application log on a FAS server; set `FAS.IssuedEventIds` / `FailedEventIds` |
| 22 | App ↔ process mapping | App crash/fault attribution needs the process names of each published app | Fill in `config/app-process-map.json` for the top 20 apps |
| 23 | EC2 ↔ Citrix machine mapping | `Machines.HostedMachineId` in Monitor holds the EC2 instance ID for MCS-on-AWS catalogs | Verify on one machine; otherwise map by hostname tag |
| 19 | Data residency / PII | User names are stored hashed for executive views; UPNs only in the ops tables | Privacy and retention requirements |
