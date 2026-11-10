/* =====================================================================
   Citrix DaaS Hourly Monitoring - data model (SQL Server 2019+/RDS)
   All timestamps are UTC. Hourly facts are keyed by HourUtc (top of hour).
   Collectors are idempotent: they DELETE the hour/scope then INSERT.
   ===================================================================== */
IF SCHEMA_ID('mon') IS NULL EXEC('CREATE SCHEMA mon');
GO

/* ---------- Reference ---------- */
CREATE TABLE mon.DeliveryGroup (
    DeliveryGroupId     UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
    Name                NVARCHAR(256)    NOT NULL,
    MaxSessionsPerVda   INT              NULL,   -- from config / load policy
    AutoscaleMaxMachines INT             NULL,
    IsCritical          BIT              NOT NULL DEFAULT 0,
    UpdatedUtc          DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME()
);

/* ---------- 5-minute availability checks (alert fast path) ---------- */
CREATE TABLE mon.HealthCheck (
    CheckUtc        DATETIME2(0)   NOT NULL,
    Component       VARCHAR(32)    NOT NULL,   -- CloudConnector|FAS|AppV|GWaaS|ControlPlane|VDAFleet|AWS|Synthetic|CitrixStatus
    Scope           NVARCHAR(256)  NOT NULL,   -- server name, resource location, probe, etc.
    CheckName       VARCHAR(64)    NOT NULL,
    Status          VARCHAR(8)     NOT NULL,   -- Green|Yellow|Red
    ValueNum        FLOAT          NULL,
    Detail          NVARCHAR(2000) NULL,
    CONSTRAINT PK_HealthCheck PRIMARY KEY (CheckUtc, Component, Scope, CheckName)
);
CREATE INDEX IX_HealthCheck_Component ON mon.HealthCheck (Component, CheckName, CheckUtc DESC) INCLUDE (Status, ValueNum);

/* ---------- Hourly facts ---------- */
CREATE TABLE mon.HourlySessionSummary (
    HourUtc             DATETIME2(0)  NOT NULL,
    DeliveryGroupId     UNIQUEIDENTIFIER NOT NULL,     -- 00000000-... = all
    ActiveSessions      INT  NOT NULL,
    DisconnectedSessions INT NOT NULL,
    ConcurrentUsers     INT  NOT NULL,
    PeakSessions        INT  NULL,
    SessionsStarted     INT  NOT NULL,
    SessionsFailed      INT  NOT NULL,
    Reconnects          INT  NOT NULL,
    IcaRttAvgMs         FLOAT NULL,
    IcaRttP95Ms         FLOAT NULL,
    ConnInternal        INT  NOT NULL DEFAULT 0,
    ConnInternalFailed  INT  NOT NULL DEFAULT 0,
    ConnExternal        INT  NOT NULL DEFAULT 0,
    ConnExternalFailed  INT  NOT NULL DEFAULT 0,
    CONSTRAINT PK_HourlySession PRIMARY KEY (HourUtc, DeliveryGroupId)
);

CREATE TABLE mon.HourlyLogonSummary (
    HourUtc             DATETIME2(0)  NOT NULL,
    DeliveryGroupId     UNIQUEIDENTIFIER NOT NULL,
    LogonAttempts       INT   NOT NULL,
    LogonFailures       INT   NOT NULL,
    FailClient          INT   NOT NULL DEFAULT 0,
    FailMachine         INT   NOT NULL DEFAULT 0,
    FailNoCapacity      INT   NOT NULL DEFAULT 0,
    FailNoLicense       INT   NOT NULL DEFAULT 0,
    FailConfiguration   INT   NOT NULL DEFAULT 0,
    FailOther           INT   NOT NULL DEFAULT 0,
    AvgLogonSec         FLOAT NULL,
    P90LogonSec         FLOAT NULL,
    AvgBrokeringSec     FLOAT NULL,
    AvgVmStartSec       FLOAT NULL,
    AvgHdxSec           FLOAT NULL,
    AvgAuthSec          FLOAT NULL,
    AvgGpoSec           FLOAT NULL,
    AvgScriptsSec       FLOAT NULL,
    AvgProfileSec       FLOAT NULL,
    AvgInteractiveSec   FLOAT NULL,
    SuccessRatePct      AS (CASE WHEN LogonAttempts = 0 THEN NULL
                                 ELSE 100.0 * (LogonAttempts - LogonFailures) / LogonAttempts END) PERSISTED,
    CONSTRAINT PK_HourlyLogon PRIMARY KEY (HourUtc, DeliveryGroupId)
);

CREATE TABLE mon.HourlyApplicationSummary (
    HourUtc             DATETIME2(0)   NOT NULL,
    ApplicationName     NVARCHAR(256)  NOT NULL,
    DeliveryGroupId     UNIQUEIDENTIFIER NOT NULL,
    Launches            INT   NOT NULL,                -- successful launches
    UniqueUsers         INT   NOT NULL,
    LaunchFailures      INT   NOT NULL DEFAULT 0,      -- failed launch attempts
    Faults              INT   NOT NULL DEFAULT 0,      -- ApplicationFaults (crash)
    Errors              INT   NOT NULL DEFAULT 0,      -- ApplicationErrors
    AvgLaunchSec        FLOAT NULL,
    P90LaunchSec        FLOAT NULL,
    IsAppV              BIT   NOT NULL DEFAULT 0,
    CONSTRAINT PK_HourlyApp PRIMARY KEY (HourUtc, ApplicationName, DeliveryGroupId)
);

CREATE TABLE mon.VDAHealth (
    HourUtc             DATETIME2(0)   NOT NULL,
    MachineName         NVARCHAR(256)  NOT NULL,
    DeliveryGroupId     UNIQUEIDENTIFIER NULL,
    Ec2InstanceId       VARCHAR(32)    NULL,
    AvailabilityZone    VARCHAR(32)    NULL,
    RegistrationState   VARCHAR(16)    NULL,           -- Registered|Unregistered|Unknown
    FaultState          VARCHAR(24)    NULL,
    InMaintenance       BIT            NULL,
    PowerState          VARCHAR(16)    NULL,
    SessionCount        INT            NULL,
    MaxSessions         INT            NULL,
    LoadIndexAvg        FLOAT NULL,
    LoadIndexMax        FLOAT NULL,
    CpuAvgPct           FLOAT NULL,
    CpuMaxPct           FLOAT NULL,
    MemAvgPct           FLOAT NULL,
    MemMaxPct           FLOAT NULL,
    DiskFreeMinPct      FLOAT NULL,
    NetInMbps           FLOAT NULL,
    NetOutMbps          FLOAT NULL,
    Ec2StatusCheckFailed BIT NULL,
    FailureEvents       INT  NOT NULL DEFAULT 0,       -- MachineFailureLogs in hour
    AppFaults           INT  NOT NULL DEFAULT 0,
    LastDeregReason     NVARCHAR(128) NULL,
    CONSTRAINT PK_VDAHealth PRIMARY KEY (HourUtc, MachineName)
);
CREATE INDEX IX_VDAHealth_DG ON mon.VDAHealth (HourUtc, DeliveryGroupId);

CREATE TABLE mon.CapacityForecast (
    RunHourUtc          DATETIME2(0) NOT NULL,
    ForecastHourUtc     DATETIME2(0) NOT NULL,
    ForecastSessions    FLOAT NOT NULL,
    SlotsNow            INT   NOT NULL,
    SlotsAtAutoscaleMax INT   NOT NULL,
    CONSTRAINT PK_CapacityForecast PRIMARY KEY (RunHourUtc, ForecastHourUtc)
);

CREATE TABLE mon.CloudConnectorHealth (
    HourUtc             DATETIME2(0)  NOT NULL,
    ServerName          NVARCHAR(128) NOT NULL,
    ResourceLocation    NVARCHAR(128) NOT NULL,
    Reachable           BIT   NOT NULL,
    CloudStatus         VARCHAR(32) NULL,              -- from Citrix Cloud API if available
    ConnectivityOk      BIT   NULL,
    StoppedServices     NVARCHAR(1000) NULL,
    CpuPct              FLOAT NULL,
    MemPct              FLOAT NULL,
    DiskFreePct         FLOAT NULL,
    NetMbps             FLOAT NULL,
    ErrorEvents         INT   NULL,
    Healthy             BIT   NOT NULL,
    CONSTRAINT PK_ConnectorHealth PRIMARY KEY (HourUtc, ServerName)
);

CREATE TABLE mon.FASHealth (
    HourUtc             DATETIME2(0)  NOT NULL,
    ServerName          NVARCHAR(128) NOT NULL,
    ServiceRunning      BIT   NOT NULL,
    CaReachable         BIT   NULL,
    CertIssued          INT   NULL,
    CertFailed          INT   NULL,
    RaCertStatus        VARCHAR(32) NULL,
    RaCertExpiryUtc     DATETIME2(0) NULL,
    CaCertExpiryUtc     DATETIME2(0) NULL,
    CpuPct              FLOAT NULL,
    MemPct              FLOAT NULL,
    DiskFreePct         FLOAT NULL,
    ErrorEvents         INT   NULL,
    Healthy             BIT   NOT NULL,
    CONSTRAINT PK_FASHealth PRIMARY KEY (HourUtc, ServerName)
);

CREATE TABLE mon.AppVHealth (
    HourUtc             DATETIME2(0)  NOT NULL,
    ServerName          NVARCHAR(128) NOT NULL,
    Role                VARCHAR(16)   NOT NULL,        -- Management|Publishing|VDAClientRollup
    EndpointOk          BIT   NULL,
    EndpointLatencyMs   INT   NULL,
    PublishFailures     INT   NULL,
    StreamMountFailures INT   NULL,
    CpuPct              FLOAT NULL,
    MemPct              FLOAT NULL,
    DiskFreePct         FLOAT NULL,
    Healthy             BIT   NOT NULL,
    CONSTRAINT PK_AppVHealth PRIMARY KEY (HourUtc, ServerName, Role)
);

CREATE TABLE mon.AWSInfrastructureHealth (
    HourUtc             DATETIME2(0)  NOT NULL,
    ResourceType        VARCHAR(32)   NOT NULL,        -- EC2|EBS|ASG|Subnet|AZ|NATGW|Account
    ResourceId          VARCHAR(128)  NOT NULL,
    CitrixRole          VARCHAR(32)   NULL,            -- VDA|CloudConnector|FAS|AppV|Monitoring
    AvailabilityZone    VARCHAR(32)   NULL,
    MetricName          VARCHAR(64)   NOT NULL,
    ValueNum            FLOAT NULL,
    Status              VARCHAR(8)    NOT NULL,        -- Green|Yellow|Red
    Detail              NVARCHAR(1000) NULL,
    CONSTRAINT PK_AWSHealth PRIMARY KEY (HourUtc, ResourceType, ResourceId, MetricName)
);

CREATE TABLE mon.SyntheticResult (
    RunUtc              DATETIME2(0)  NOT NULL,
    Probe               NVARCHAR(64)  NOT NULL,
    Path                VARCHAR(8)    NOT NULL,        -- Internal|External
    TestName            VARCHAR(32)   NOT NULL,        -- Reachability|SignIn|Enumerate|Launch
    Passed              BIT           NOT NULL,
    DurationMs          INT           NULL,
    Detail              NVARCHAR(1000) NULL,
    CONSTRAINT PK_Synthetic PRIMARY KEY (RunUtc, Probe, TestName)
);

CREATE TABLE mon.ComponentStatus (
    HourUtc             DATETIME2(0)  NOT NULL,
    Component           VARCHAR(32)   NOT NULL,
    Owner               VARCHAR(16)   NOT NULL,        -- CITRIX|CTX-INFRA|AWS
    Status              VARCHAR(8)    NOT NULL,
    Summary             NVARCHAR(500) NULL,
    CONSTRAINT PK_ComponentStatus PRIMARY KEY (HourUtc, Component)
);

CREATE TABLE mon.AlertHistory (
    AlertKey            BIGINT IDENTITY PRIMARY KEY,
    AlertId             VARCHAR(16)   NOT NULL,        -- ALR-01 ...
    Severity            VARCHAR(16)   NOT NULL,        -- Informational|Warning|Critical
    Component           VARCHAR(32)   NOT NULL,
    Scope               NVARCHAR(256) NOT NULL,
    Owner               VARCHAR(16)   NOT NULL,
    Title               NVARCHAR(256) NOT NULL,
    Detail              NVARCHAR(2000) NULL,
    ExecImpact          NVARCHAR(500) NULL,
    RunbookAction       NVARCHAR(1000) NULL,
    AffectedUsers       INT           NULL,
    OpenedUtc           DATETIME2(0)  NOT NULL,
    LastSeenUtc         DATETIME2(0)  NOT NULL,
    ResolvedUtc         DATETIME2(0)  NULL,
    HealthyStreak       INT           NOT NULL DEFAULT 0,
    NotifiedUtc         DATETIME2(0)  NULL,
    AcknowledgedBy      NVARCHAR(128) NULL
);
CREATE UNIQUE INDEX UX_AlertHistory_Open ON mon.AlertHistory (AlertId, Component, Scope) WHERE ResolvedUtc IS NULL;

CREATE TABLE mon.ExecutiveDailyRollup (
    DayUtc              DATE          NOT NULL PRIMARY KEY,
    PeakConcurrentUsers INT   NULL,
    PeakSessions        INT   NULL,
    LogonAttempts       INT   NULL,
    LogonSuccessPct     FLOAT NULL,
    AvgLogonSec         FLOAT NULL,
    P90LogonSec         FLOAT NULL,
    AppLaunchSuccessPct FLOAT NULL,
    ExternalSuccessPct  FLOAT NULL,
    InternalSuccessPct  FLOAT NULL,
    VdaAvailabilityPct  FLOAT NULL,
    ConnectorAvailabilityPct FLOAT NULL,
    FasAvailabilityPct  FLOAT NULL,
    PeakCapacityPct     FLOAT NULL,
    CriticalAlerts      INT   NULL,
    WarningAlerts       INT   NULL,
    MinutesRed          INT   NULL,
    MinutesYellow       INT   NULL,
    ServiceAvailabilityPct FLOAT NULL                  -- % of 5-min checks where user path was not Red
);

CREATE TABLE mon.CollectorRun (
    RunId       BIGINT IDENTITY PRIMARY KEY,
    Job         VARCHAR(64) NOT NULL,
    StartedUtc  DATETIME2(0) NOT NULL,
    EndedUtc    DATETIME2(0) NULL,
    Succeeded   BIT NULL,
    Message     NVARCHAR(2000) NULL
);
GO

/* ---------- Views for Power BI ---------- */
CREATE OR ALTER VIEW mon.vExecKpiCurrent AS
WITH h AS (SELECT MAX(HourUtc) AS HourUtc FROM mon.HourlySessionSummary)
SELECT
    h.HourUtc,
    s.ConcurrentUsers, s.ActiveSessions,
    l.SuccessRatePct            AS LogonSuccessPct,
    l.AvgLogonSec,
    l.P90LogonSec,
    (SELECT 100.0 * SUM(Launches) / NULLIF(SUM(Launches) + SUM(LaunchFailures),0)
       FROM mon.HourlyApplicationSummary a WHERE a.HourUtc = h.HourUtc)                   AS AppLaunchSuccessPct,
    100.0 * (s.ConnExternal - s.ConnExternalFailed) / NULLIF(s.ConnExternal,0)            AS ExternalSuccessPct,
    (SELECT 100.0 * SUM(CASE WHEN RegistrationState='Registered' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*),0)
       FROM mon.VDAHealth v WHERE v.HourUtc = h.HourUtc AND v.PowerState='On' AND v.InMaintenance=0) AS VdaAvailabilityPct,
    (SELECT CONCAT(SUM(CAST(Healthy AS INT)),'/',COUNT(*)) FROM mon.CloudConnectorHealth c WHERE c.HourUtc = h.HourUtc) AS ConnectorsHealthy,
    (SELECT CONCAT(SUM(CAST(Healthy AS INT)),'/',COUNT(*)) FROM mon.FASHealth f WHERE f.HourUtc = h.HourUtc)           AS FasHealthy,
    (SELECT 100.0 * SUM(SessionCount) / NULLIF(SUM(MaxSessions),0)
       FROM mon.VDAHealth v WHERE v.HourUtc = h.HourUtc AND v.RegistrationState='Registered' AND v.InMaintenance=0)    AS CapacityPct,
    (SELECT COUNT(*) FROM mon.AlertHistory WHERE ResolvedUtc IS NULL AND Severity='Critical') AS OpenCritical,
    (SELECT COUNT(*) FROM mon.AlertHistory WHERE ResolvedUtc IS NULL AND Severity='Warning')  AS OpenWarning
FROM h
JOIN mon.HourlySessionSummary s ON s.HourUtc = h.HourUtc AND s.DeliveryGroupId = '00000000-0000-0000-0000-000000000000'
LEFT JOIN mon.HourlyLogonSummary l ON l.HourUtc = h.HourUtc AND l.DeliveryGroupId = '00000000-0000-0000-0000-000000000000';
GO

CREATE OR ALTER VIEW mon.vTopIssues AS
SELECT AlertId, Severity, Component, Scope, Owner, Title, ExecImpact, RunbookAction, AffectedUsers, OpenedUtc, LastSeenUtc
FROM mon.AlertHistory
WHERE ResolvedUtc IS NULL;
GO

/* ---------- Retention ---------- */
CREATE OR ALTER PROCEDURE mon.usp_PurgeRetention AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM mon.HealthCheck     WHERE CheckUtc < DATEADD(DAY, -30, SYSUTCDATETIME());
    DELETE FROM mon.SyntheticResult WHERE RunUtc   < DATEADD(DAY, -90, SYSUTCDATETIME());
    DELETE FROM mon.VDAHealth       WHERE HourUtc  < DATEADD(DAY, -90, SYSUTCDATETIME());
    DELETE FROM mon.AWSInfrastructureHealth WHERE HourUtc < DATEADD(DAY, -90, SYSUTCDATETIME());
    DELETE FROM mon.CollectorRun    WHERE StartedUtc < DATEADD(DAY, -30, SYSUTCDATETIME());
    -- Hourly summaries & daily rollup: 13 months / indefinite
    DELETE FROM mon.HourlySessionSummary     WHERE HourUtc < DATEADD(MONTH, -13, SYSUTCDATETIME());
    DELETE FROM mon.HourlyLogonSummary       WHERE HourUtc < DATEADD(MONTH, -13, SYSUTCDATETIME());
    DELETE FROM mon.HourlyApplicationSummary WHERE HourUtc < DATEADD(MONTH, -13, SYSUTCDATETIME());
END;
GO

/* ---------- Daily executive rollup ---------- */
CREATE OR ALTER PROCEDURE mon.usp_BuildExecutiveDailyRollup @DayUtc DATE AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s DATETIME2(0) = CAST(@DayUtc AS DATETIME2(0)), @e DATETIME2(0) = DATEADD(DAY, 1, CAST(@DayUtc AS DATETIME2(0)));
    DECLARE @all UNIQUEIDENTIFIER = '00000000-0000-0000-0000-000000000000';

    DELETE FROM mon.ExecutiveDailyRollup WHERE DayUtc = @DayUtc;

    INSERT mon.ExecutiveDailyRollup
    SELECT @DayUtc,
        (SELECT MAX(ConcurrentUsers) FROM mon.HourlySessionSummary WHERE HourUtc >= @s AND HourUtc < @e AND DeliveryGroupId=@all),
        (SELECT MAX(COALESCE(PeakSessions, ActiveSessions + DisconnectedSessions)) FROM mon.HourlySessionSummary WHERE HourUtc >= @s AND HourUtc < @e AND DeliveryGroupId=@all),
        l.Attempts,
        100.0 * (l.Attempts - l.Failures) / NULLIF(l.Attempts, 0),
        l.AvgLogon, l.P90Logon,
        (SELECT 100.0 * SUM(Launches) / NULLIF(SUM(Launches) + SUM(LaunchFailures),0) FROM mon.HourlyApplicationSummary WHERE HourUtc >= @s AND HourUtc < @e),
        (SELECT 100.0 * (SUM(ConnExternal)-SUM(ConnExternalFailed)) / NULLIF(SUM(ConnExternal),0) FROM mon.HourlySessionSummary WHERE HourUtc >= @s AND HourUtc < @e AND DeliveryGroupId=@all),
        (SELECT 100.0 * (SUM(ConnInternal)-SUM(ConnInternalFailed)) / NULLIF(SUM(ConnInternal),0) FROM mon.HourlySessionSummary WHERE HourUtc >= @s AND HourUtc < @e AND DeliveryGroupId=@all),
        (SELECT 100.0 * SUM(CASE WHEN RegistrationState='Registered' THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0) FROM mon.VDAHealth WHERE HourUtc >= @s AND HourUtc < @e AND PowerState='On' AND InMaintenance=0),
        (SELECT 100.0 * AVG(CAST(Healthy AS FLOAT)) FROM mon.CloudConnectorHealth WHERE HourUtc >= @s AND HourUtc < @e),
        (SELECT 100.0 * AVG(CAST(Healthy AS FLOAT)) FROM mon.FASHealth WHERE HourUtc >= @s AND HourUtc < @e),
        (SELECT MAX(p) FROM (SELECT 100.0 * SUM(SessionCount) / NULLIF(SUM(MaxSessions),0) AS p FROM mon.VDAHealth
                             WHERE HourUtc >= @s AND HourUtc < @e AND RegistrationState='Registered' AND InMaintenance=0 GROUP BY HourUtc) x),
        (SELECT COUNT(*) FROM mon.AlertHistory WHERE OpenedUtc >= @s AND OpenedUtc < @e AND Severity='Critical'),
        (SELECT COUNT(*) FROM mon.AlertHistory WHERE OpenedUtc >= @s AND OpenedUtc < @e AND Severity='Warning'),
        (SELECT 5 * COUNT(DISTINCT CheckUtc) FROM mon.HealthCheck WHERE CheckUtc >= @s AND CheckUtc < @e AND Component='Overall' AND Status='Red'),
        (SELECT 5 * COUNT(DISTINCT CheckUtc) FROM mon.HealthCheck WHERE CheckUtc >= @s AND CheckUtc < @e AND Component='Overall' AND Status='Yellow'),
        (SELECT 100.0 * SUM(CASE WHEN Status <> 'Red' THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0) FROM mon.HealthCheck WHERE CheckUtc >= @s AND CheckUtc < @e AND Component='Overall')
    FROM (SELECT SUM(LogonAttempts) Attempts, SUM(LogonFailures) Failures,
                 SUM(AvgLogonSec * LogonAttempts) / NULLIF(SUM(LogonAttempts),0) AvgLogon,
                 MAX(P90LogonSec) P90Logon   -- conservative: worst hourly P90
          FROM mon.HourlyLogonSummary WHERE HourUtc >= @s AND HourUtc < @e AND DeliveryGroupId=@all) l;
END;
GO
