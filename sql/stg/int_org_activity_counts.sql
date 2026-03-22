-- Layer  : Staging / Intermediate
-- =============================================================================
-- Purpose : Pre-aggregate per-org activity counts. This will centralises all
--           aggregation logic so mart models can stay readable and never
--           re-aggregate raw events directly.
--
--           Both mart tables (mart_trial_goals and mart_trial_activation)
--           build on this intermediate table.
--
-- Grain      : One row per (organization_id, activity_name)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS staging;

DROP TABLE IF EXISTS staging.int_org_activity_counts;

CREATE TABLE staging.int_org_activity_counts AS

WITH

-- Count events per org per activity, with time-window buckets
activity_counts AS (
    SELECT
        organization_id,
        activity_name,
        module_name,

        -- Total event count across the full trial
        COUNT(*)                                                     AS event_count,

        -- First and last occurrence of this activity
        MIN(event_ts)                                                AS first_event_ts,
        MAX(event_ts)                                                AS last_event_ts,

        -- Sub-counts by time window (useful for early-engagement analysis)
        COUNT(*) FILTER (WHERE days_into_trial BETWEEN 0 AND 7)     AS events_first_7_days,
        COUNT(*) FILTER (WHERE days_into_trial BETWEEN 0 AND 14)    AS events_first_14_days,

        -- Count only events that fell within the official 30-day trial window
        COUNT(*) FILTER (WHERE event_within_trial = TRUE)           AS events_within_trial

    FROM staging.stg_events
    GROUP BY 1, 2, 3
),

-- Pull distinct org-level metadata (one row per org)
org_meta AS (
    SELECT DISTINCT ON (organization_id)
        organization_id,
        converted,
        converted_at,
        trial_start,
        trial_end,
        days_to_convert
    FROM staging.stg_events
    ORDER BY organization_id
)

SELECT
    a.organization_id,
    a.activity_name,
    a.module_name,
    a.event_count,
    a.first_event_ts,
    a.last_event_ts,
    a.events_first_7_days,
    a.events_first_14_days,
    a.events_within_trial,
    m.converted,
    m.converted_at,
    m.trial_start,
    m.trial_end,
    m.days_to_convert

FROM activity_counts  a
LEFT JOIN org_meta    m USING (organization_id);

-- Sanity check
DO $$
BEGIN
    RAISE NOTICE '─────────────────────────────────────────────';
    RAISE NOTICE 'staging.int_org_activity_counts created';
    RAISE NOTICE '  Rows (org × activity pairs) : %', (SELECT COUNT(*)                        FROM staging.int_org_activity_counts);
    RAISE NOTICE '  Unique orgs                 : %', (SELECT COUNT(DISTINCT organization_id) FROM staging.int_org_activity_counts);
    RAISE NOTICE '  Unique activities           : %', (SELECT COUNT(DISTINCT activity_name)   FROM staging.int_org_activity_counts);
    RAISE NOTICE '─────────────────────────────────────────────';
END $$;
