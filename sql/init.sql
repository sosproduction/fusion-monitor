-- =============================================================================
-- init.sql
-- Mounted into TimescaleDB container at:
--   /docker-entrypoint-initdb.d/init.sql
-- Runs automatically on first container start.
-- =============================================================================

-- Enable the TimescaleDB extension
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- =============================================================================
-- SCHEMA 1: tsdb  — hot/warm time-series storage (TimescaleDB hypertable)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS tsdb;

CREATE TABLE IF NOT EXISTS tsdb.metrics (
    time        TIMESTAMPTZ      NOT NULL,
    origin      TEXT             NOT NULL,   -- 'fusion-reactor' | 'kubernetes' | 'h200-cluster' | 'systemd'
    subsystem   TEXT             NOT NULL,   -- 'plasma' | 'magnetic' | 'gpu' | 'pod' etc.
    metric_name TEXT             NOT NULL,
    value       DOUBLE PRECISION NOT NULL,
    unit        TEXT             DEFAULT '',
    tags        JSONB            DEFAULT '{}'::jsonb
);

-- Convert to hypertable — partitioned by time in 1-day chunks
SELECT create_hypertable(
    'tsdb.metrics',
    'time',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists       => TRUE
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_metrics_origin_name_time
    ON tsdb.metrics (origin, metric_name, time DESC);

CREATE INDEX IF NOT EXISTS idx_metrics_subsystem_time
    ON tsdb.metrics (subsystem, time DESC);

-- GIN index for JSONB tag queries  e.g. tags @> '{"reactor_id":"FRP-001"}'
CREATE INDEX IF NOT EXISTS idx_metrics_tags
    ON tsdb.metrics USING GIN (tags);

-- Compression: chunks older than 7 days are compressed (~15x smaller)
ALTER TABLE tsdb.metrics SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'origin, metric_name',
    timescaledb.compress_orderby   = 'time DESC'
);
SELECT add_compression_policy('tsdb.metrics', INTERVAL '7 days',   if_not_exists => TRUE);

-- Retention: drop chunks older than 1 year
SELECT add_retention_policy('tsdb.metrics',  INTERVAL '365 days',  if_not_exists => TRUE);

-- =============================================================================
-- SCHEMA 2: meta  — cold relational / permanent metadata (plain PostgreSQL)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS meta;

-- Registered data sources
CREATE TABLE IF NOT EXISTS meta.sources (
    id            SERIAL PRIMARY KEY,
    origin_tag    TEXT        UNIQUE NOT NULL,
    display_name  TEXT,
    description   TEXT,
    location      TEXT,
    registered_at TIMESTAMPTZ DEFAULT NOW(),
    active        BOOLEAN     DEFAULT TRUE
);

INSERT INTO meta.sources (origin_tag, display_name, description, location) VALUES
    ('fusion-reactor', 'Fusion Reactor FRP-001', 'Tokamak prototype at NFRC',    'Building-4, Bay-2'),
    ('kubernetes',     'K8s Cluster',            'Production Kubernetes cluster', 'DC-East'),
    ('h200-cluster',   'H200 GPU Cluster',        'NVIDIA H200 HPC cluster',      'DC-West'),
    ('systemd',        'System Services',         'Host systemd journal metrics',  'All nodes')
ON CONFLICT (origin_tag) DO NOTHING;

-- Alert / threshold definitions (what value triggers an alert per metric)
CREATE TABLE IF NOT EXISTS meta.thresholds (
    id          SERIAL PRIMARY KEY,
    origin      TEXT    NOT NULL,
    metric_name TEXT    NOT NULL,
    warn_value  DOUBLE PRECISION,
    crit_value  DOUBLE PRECISION,
    unit        TEXT,
    description TEXT,
    updated_at  TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (origin, metric_name)
);

INSERT INTO meta.thresholds (origin, metric_name, warn_value, crit_value, unit, description) VALUES
    ('fusion-reactor', 'fusion_plasma_temperature_keV',       18.0,   22.0,  'keV',    'Plasma overtemperature'),
    ('fusion-reactor', 'fusion_mag_disruption_risk_percent',  40.0,   70.0,  '%',      'Disruption imminent'),
    ('fusion-reactor', 'fusion_divertor_temp_outer_C',      1100.0, 1600.0,  '°C',    'Divertor overtemp'),
    ('fusion-reactor', 'fusion_tritium_breeding_ratio',        1.05,   1.0,  '',       'TBR below minimum'),
    ('fusion-reactor', 'fusion_rad_gamma_control_room_mSv_hr',0.005, 0.01,  'mSv/hr','Control room radiation'),
    ('h200-cluster',   'gpu_temperature_C',                   80.0,   90.0,  '°C',    'GPU overtemperature'),
    ('h200-cluster',   'gpu_utilization_percent',             90.0,   98.0,  '%',      'GPU saturation'),
    ('kubernetes',     'pod_restart_count',                    5.0,   20.0,  '',       'Pod crash-loop')
ON CONFLICT (origin, metric_name) DO NOTHING;

-- Alert history — every fired alert is logged here permanently
CREATE TABLE IF NOT EXISTS meta.alert_history (
    id              SERIAL PRIMARY KEY,
    fired_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ,
    origin          TEXT        NOT NULL,
    subsystem       TEXT,
    metric_name     TEXT        NOT NULL,
    severity        TEXT        CHECK (severity IN ('warning','critical','emergency')),
    value_at_fire   DOUBLE PRECISION,
    threshold_used  DOUBLE PRECISION,
    message         TEXT,
    acknowledged_by TEXT,
    notes           TEXT
);

CREATE INDEX IF NOT EXISTS idx_alert_origin_fired
    ON meta.alert_history (origin, fired_at DESC);

CREATE INDEX IF NOT EXISTS idx_alert_unresolved
    ON meta.alert_history (resolved_at)
    WHERE resolved_at IS NULL;

-- Planned maintenance windows (suppress alerts during maintenance)
CREATE TABLE IF NOT EXISTS meta.maintenance_windows (
    id          SERIAL PRIMARY KEY,
    origin      TEXT,                      -- NULL means all origins
    starts_at   TIMESTAMPTZ NOT NULL,
    ends_at     TIMESTAMPTZ NOT NULL,
    reason      TEXT,
    created_by  TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Audit log — who changed what threshold/config
CREATE TABLE IF NOT EXISTS meta.audit_log (
    id          SERIAL PRIMARY KEY,
    event_time  TIMESTAMPTZ DEFAULT NOW(),
    actor       TEXT,
    action      TEXT,        -- 'threshold_update', 'source_register', etc.
    target_table TEXT,
    target_id   TEXT,
    old_value   JSONB,
    new_value   JSONB
);

-- =============================================================================
-- Useful views
-- =============================================================================

-- Latest value per metric per origin (handy for dashboards)
CREATE OR REPLACE VIEW tsdb.latest_metrics AS
SELECT DISTINCT ON (origin, metric_name)
    time, origin, subsystem, metric_name, value, unit, tags
FROM tsdb.metrics
ORDER BY origin, metric_name, time DESC;

-- Active (unresolved) alerts
CREATE OR REPLACE VIEW meta.active_alerts AS
SELECT * FROM meta.alert_history
WHERE resolved_at IS NULL
ORDER BY fired_at DESC;

-- Metrics currently breaching their warn threshold
CREATE OR REPLACE VIEW meta.current_breaches AS
SELECT
    lm.time,
    lm.origin,
    lm.metric_name,
    lm.value,
    lm.unit,
    th.warn_value,
    th.crit_value,
    CASE
        WHEN lm.value >= th.crit_value THEN 'critical'
        WHEN lm.value >= th.warn_value THEN 'warning'
        ELSE 'nominal'
    END AS severity
FROM tsdb.latest_metrics lm
JOIN meta.thresholds th
    ON lm.origin = th.origin AND lm.metric_name = th.metric_name
WHERE lm.value >= th.warn_value;

-- =============================================================================
-- Grant permissions
-- =============================================================================
GRANT USAGE  ON SCHEMA tsdb TO PUBLIC;
GRANT USAGE  ON SCHEMA meta TO PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA tsdb TO PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA meta TO PUBLIC;