-- Layer  : Marts
-- =============================================================================
-- Purpose : One row per organisation. Tracks whether each trialist
--           has completed each of the 5 defined trial goals.
--           This is the primary "in-trial health check" table.
--
-- Grain      : organization_id (exactly one row per organisation)
--
-- ─────────────────────────────────────────────────────────────────────────────
-- TRIAL GOAL DEFINITIONS
-- (grounded in Random Forest feature importance + product-value logic)
-- ─────────────────────────────────────────────────────────────────────────────
--   Goal 1 — Core Scheduling     : ≥3 shifts created
--             Rationale: Proves active recurring scheduling, not just a test.
--             RF importance rank #1. Completion rate: 58.3% of orgs.
--
--   Goal 2 — Schedule Visibility : ≥3 schedule views (Mobile.Schedule.Loaded)
--             Rationale: Team members checking their schedule daily — not
--             just admin configuration. RF importance rank #2. Rate: 36.0%.
--
--   Goal 3 — Time Tracking       : ≥1 punch-in (PunchClock.PunchedIn)
--             Rationale: Live time tracking is operational, not just set up.
--             RF importance rank #5. Completion rate: 21.8%.
--
--   Goal 4 — Payroll Approval    : ≥1 shift approved (Scheduling.Shift.Approved)
--             Rationale: Admin has closed the core end-to-end workflow loop:
--             schedule → work → approve → pay. Rate: 20.7%.
--
--   Goal 5 — Team Communications : ≥1 message (Communication.Message.Created)
--             Rationale: Platform used as unified workforce tool, not just
--             a scheduler. RF importance rank #6. Rate: 15.0%.
--
--   We must note that Goals are analytical hypotheses. No single goal is statistically
--   significant (all p > 0.05, CV AUC ≈ 0.50). We must validate via A/B test
--    before using as operational KPIs.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS marts;

DROP TABLE IF EXISTS marts.mart_trial_goals;

CREATE TABLE marts.mart_trial_goals AS

WITH

-- ── One row per org: distinct org-level metadata ──────────────────────────
org_base AS (
    SELECT DISTINCT ON (organization_id)
        organization_id,
        converted,
        converted_at,
        trial_start,
        trial_end,
        days_to_convert
    FROM staging.int_org_activity_counts
    ORDER BY organization_id
),

-- Pivot: sum each goal-relevant activity count per org
-- Sourced from int_org_activity_counts so we never re-aggregate raw events.
activity_pivot AS (
    SELECT
        organization_id,

        -- Goal 1 driver: shift creation
        COALESCE(SUM(CASE WHEN activity_name = 'Scheduling.Shift.Created'
                          THEN event_count ELSE 0 END), 0)    AS shifts_created,

        -- Goal 2 driver: schedule views
        COALESCE(SUM(CASE WHEN activity_name = 'Mobile.Schedule.Loaded'
                          THEN event_count ELSE 0 END), 0)    AS schedule_views,

        -- Goal 3 driver: punch-ins
        COALESCE(SUM(CASE WHEN activity_name = 'PunchClock.PunchedIn'
                          THEN event_count ELSE 0 END), 0)    AS punch_ins,

        -- Goal 4 driver: shift approvals
        COALESCE(SUM(CASE WHEN activity_name = 'Scheduling.Shift.Approved'
                          THEN event_count ELSE 0 END), 0)    AS shifts_approved,

        -- Goal 5 driver: team messages
        COALESCE(SUM(CASE WHEN activity_name = 'Communication.Message.Created'
                          THEN event_count ELSE 0 END), 0)    AS messages_sent,

        -- Supplementary counts (context for analysts)
        COALESCE(SUM(CASE WHEN activity_name = 'PunchClock.PunchedOut'
                          THEN event_count ELSE 0 END), 0)    AS punch_outs,
        COALESCE(SUM(CASE WHEN activity_name = 'Timesheets.BulkApprove.Confirmed'
                          THEN event_count ELSE 0 END), 0)    AS timesheets_approved,
        COALESCE(SUM(CASE WHEN activity_name = 'Integration.Xero.PayrollExport.Synced'
                          THEN event_count ELSE 0 END), 0)    AS payroll_exports,
        COALESCE(SUM(CASE WHEN activity_name = 'Absence.Request.Created'
                          THEN event_count ELSE 0 END), 0)    AS absence_requests,
        COALESCE(SUM(CASE WHEN activity_name = 'Scheduling.Template.ApplyModal.Applied'
                          THEN event_count ELSE 0 END), 0)    AS templates_applied,
        COALESCE(SUM(CASE WHEN activity_name = 'Scheduling.Shift.AssignmentChanged'
                          THEN event_count ELSE 0 END), 0)    AS shift_assignments_changed,

        -- Engagement breadth
        COUNT(DISTINCT activity_name)                          AS unique_activities_used,
        SUM(event_count)                                       AS total_events

    FROM staging.int_org_activity_counts
    GROUP BY organization_id
)

SELECT
    -- Identity 
    b.organization_id,

    -- Trial metadata 
    b.trial_start,
    b.trial_end,
    b.converted,
    b.converted_at,
    b.days_to_convert,

    -- Raw activity counts (transparent inputs to goal logic)
    a.shifts_created,
    a.schedule_views,
    a.punch_ins,
    a.shifts_approved,
    a.messages_sent,
    a.punch_outs,
    a.timesheets_approved,
    a.payroll_exports,
    a.absence_requests,
    a.templates_applied,
    a.shift_assignments_changed,
    a.unique_activities_used,
    a.total_events,

    -- GOAL FLAGS (primary outputs of this our model)
    (a.shifts_created >= 3)           AS goal_1_core_scheduling,
    (a.schedule_views >= 3)           AS goal_2_schedule_visibility,
    (a.punch_ins >= 1)                AS goal_3_time_tracking,
    (a.shifts_approved >= 1)          AS goal_4_payroll_approval,
    (a.messages_sent >= 1)            AS goal_5_team_comms,

    -- Summary: goals completed count (0–5)
    (  (a.shifts_created >= 3)::INT
     + (a.schedule_views >= 3)::INT
     + (a.punch_ins >= 1)::INT
     + (a.shifts_approved >= 1)::INT
     + (a.messages_sent >= 1)::INT )  AS goals_completed_count,

    -- ── Audit ────────────────────────────────────
    NOW()                             AS created_at

FROM org_base        b
LEFT JOIN activity_pivot a USING (organization_id)
ORDER BY organization_id;

-- Primary key
ALTER TABLE marts.mart_trial_goals ADD PRIMARY KEY (organization_id);

-- Sanity check
DO $$
BEGIN
    RAISE NOTICE '─────────────────────────────────────────────';
    RAISE NOTICE 'marts.mart_trial_goals created';
    RAISE NOTICE '  Total orgs             : %  (expected: 966)', (SELECT COUNT(*) FROM marts.mart_trial_goals);
    RAISE NOTICE '  G1 Core Scheduling     : %  (expected: 563)', (SELECT COUNT(*) FROM marts.mart_trial_goals WHERE goal_1_core_scheduling);
    RAISE NOTICE '  G2 Schedule Visibility : %  (expected: 348)', (SELECT COUNT(*) FROM marts.mart_trial_goals WHERE goal_2_schedule_visibility);
    RAISE NOTICE '  G3 Time Tracking       : %  (expected: 211)', (SELECT COUNT(*) FROM marts.mart_trial_goals WHERE goal_3_time_tracking);
    RAISE NOTICE '  G4 Payroll Approval    : %  (expected: 200)', (SELECT COUNT(*) FROM marts.mart_trial_goals WHERE goal_4_payroll_approval);
    RAISE NOTICE '  G5 Team Comms          : %  (expected: 145)', (SELECT COUNT(*) FROM marts.mart_trial_goals WHERE goal_5_team_comms);
    RAISE NOTICE '  All 5 goals completed  : %  (expected:  65)', (SELECT COUNT(*) FROM marts.mart_trial_goals WHERE goals_completed_count = 5);
    RAISE NOTICE '─────────────────────────────────────────────';
END $$;
