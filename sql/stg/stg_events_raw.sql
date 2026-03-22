-- Layer  : Staging
-- =============================================================================
-- Purpose: Create the raw staging table to receive stg_events_clean.csv
--          (output of Task 1 Python cleaning).
--          Data is loaded separately via pgAdmin Import/Export tool.

CREATE SCHEMA IF NOT EXISTS staging;

DROP TABLE IF EXISTS staging.stg_events_raw CASCADE;

CREATE TABLE staging.stg_events_raw (
    organization_id      TEXT,
    activity_name        TEXT,
    event_ts             TIMESTAMP,
    converted            BOOLEAN,
    converted_at         TIMESTAMP,
    trial_start          TIMESTAMP,
    trial_end            TIMESTAMP,
    days_into_trial      NUMERIC,
    trial_length_days    INTEGER,
    event_within_trial   BOOLEAN,
    module_name          TEXT
);

