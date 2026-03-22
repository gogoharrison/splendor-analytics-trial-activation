-- Layer  : Staging
-- =============================================================================
-- Purpose : Thin view on top of stg_events_raw.
-- Adds days_to_convert — an org-level field needed by all
-- downstream models. Everything else was already derived
-- in Task 1 Python and is present in stg_events_raw.
--
-- Grain : One row per (organization_id, activity_name, event_ts)

DROP VIEW IF EXISTS staging.stg_events CASCADE;

CREATE VIEW staging.stg_events AS

SELECT
    organization_id,
    activity_name,
    event_ts,
    converted,
    converted_at,
    trial_start,
    trial_end,
    days_into_trial,
    trial_length_days,
    event_within_trial,

    -- Days from trial start to conversion (NULL for non-converters)
    CASE
        WHEN converted = TRUE AND converted_at IS NOT NULL
            THEN EXTRACT(EPOCH FROM (converted_at - trial_start)) / 86400.0
        ELSE NULL
    END AS days_to_convert,

    -- Module grouping (re-derived here since it was not saved in the CSV)
    CASE
        WHEN activity_name LIKE 'Scheduling.%'
          OR activity_name IN ('Mobile.Schedule.Loaded',
                               'Shift.View.Opened',
                               'ShiftDetails.View.Opened')
            THEN 'Scheduling'
        WHEN activity_name LIKE 'PunchClock.%'
          OR activity_name LIKE 'Break.Activate.%'
            THEN 'Time & Attendance'
        WHEN activity_name LIKE 'Absence.%'
            THEN 'Absence Management'
        WHEN activity_name IN ('Timesheets.BulkApprove.Confirmed',
                               'Integration.Xero.PayrollExport.Synced',
                               'Revenue.Budgets.Created')
            THEN 'Payroll & Finance'
        WHEN activity_name LIKE 'Communication.%'
            THEN 'Communication'
        ELSE 'Other'
    END AS module_name

FROM staging.stg_events_raw;