-- Layer  : mart
-- =============================================================================
-- Purpose : One row per organisation. This will track whether the org achieved
--           full Trial Activation, plus bottleneck diagnosis, funnel
--           stage, and activation × conversion segmentation.
--
-- Grain      : organization_id (exactly one row per organisation)
-- ─────────────────────────────────────────────────────────────────────────────
-- ACTIVATION DEFINITION:
--   An organisation is "Trial Activated" when ALL 5 trial goals are completed:
--     Goal 1 — Core Scheduling      (≥3 shifts created)
--     Goal 2 — Schedule Visibility  (≥3 schedule views)
--     Goal 3 — Time Tracking        (≥1 punch-in)
--     Goal 4 — Payroll Approval     (≥1 shift approved)
--     Goal 5 — Team Communications  (≥1 message sent)
--
--   Activation rate (current data): 65 / 966 orgs = 6.7%
-- =============================================================================

DROP TABLE IF EXISTS marts.mart_trial_activation;

CREATE TABLE marts.mart_trial_activation AS

WITH

-- ── Pull goal flags and derive activation flag ────────────────────────────
activation AS (
    SELECT
        organization_id,
        converted,
        converted_at,
        trial_start,
        trial_end,
        days_to_convert,
        goal_1_core_scheduling,
        goal_2_schedule_visibility,
        goal_3_time_tracking,
        goal_4_payroll_approval,
        goal_5_team_comms,
        goals_completed_count,
        unique_activities_used,
        total_events,

        -- ── TRIAL ACTIVATION FLAG ─────────────────────────────────────────
        -- AND-logic: partial completion = partial value, not full activation
        (    goal_1_core_scheduling
         AND goal_2_schedule_visibility
         AND goal_3_time_tracking
         AND goal_4_payroll_approval
         AND goal_5_team_comms
        )                                   AS trial_activated,

        -- Cohort month — for time-series / monthly reporting
        DATE_TRUNC('month', trial_start)    AS trial_cohort_month,

        -- Engagement tier — for product segmentation
        CASE
            WHEN unique_activities_used = 1             THEN 'Minimal'
            WHEN unique_activities_used BETWEEN 2 AND 3 THEN 'Low'
            WHEN unique_activities_used BETWEEN 4 AND 6 THEN 'Medium'
            ELSE                                             'High'
        END                                 AS engagement_tier

    FROM marts.mart_trial_goals
),

-- ── Bottleneck: identify where each org fell out of the funnel ────────────
bottleneck AS (
    SELECT
        organization_id,

        -- Goals evaluated in product-logic order:
        -- Scheduling → Visibility → Time Tracking → Payroll → Comms
        -- The first FALSE goal is the activation bottleneck.
        CASE
            WHEN NOT goal_1_core_scheduling
                THEN 'Goal 1: Core Scheduling (≥3 shifts)'
            WHEN NOT goal_2_schedule_visibility
                THEN 'Goal 2: Schedule Visibility (≥3 views)'
            WHEN NOT goal_3_time_tracking
                THEN 'Goal 3: Time Tracking (≥1 punch-in)'
            WHEN NOT goal_4_payroll_approval
                THEN 'Goal 4: Payroll Approval (≥1 shift)'
            WHEN NOT goal_5_team_comms
                THEN 'Goal 5: Team Comms (≥1 message)'
            ELSE
                'None — Fully Activated'
        END                                 AS first_incomplete_goal,

        -- Sequential funnel stage: how far did this org get?
        -- 0 = stuck at Goal 1, 5 = fully activated
        CASE
            WHEN NOT goal_1_core_scheduling     THEN 0
            WHEN NOT goal_2_schedule_visibility THEN 1
            WHEN NOT goal_3_time_tracking       THEN 2
            WHEN NOT goal_4_payroll_approval    THEN 3
            WHEN NOT goal_5_team_comms          THEN 4
            ELSE                                     5
        END                                 AS sequential_funnel_stage

    FROM marts.mart_trial_goals
)

SELECT
    -- ── Identity ─────────────────────────────────────────────────────────
    a.organization_id,

    -- ── Trial metadata ────────────────────────────────────────────────────
    a.trial_start,
    a.trial_end,
    a.trial_cohort_month,

    -- ── Conversion ────────────────────────────────────────────────────────
    a.converted,
    a.converted_at,
    a.days_to_convert,

    -- ── Activation (primary outputs of this model) ────────────────────────
    a.trial_activated,
    CASE WHEN a.trial_activated
        THEN 'Activated'
        ELSE 'Not Activated'
    END                                     AS activation_status,

    -- 4-way cross-segment: activation × conversion
    CASE
        WHEN     a.trial_activated AND     a.converted THEN 'Activated & Converted'
        WHEN     a.trial_activated AND NOT a.converted THEN 'Activated, Not Converted'
        WHEN NOT a.trial_activated AND     a.converted THEN 'Converted without Activation'
        ELSE                                                'Not Activated, Not Converted'
    END                                     AS activation_conversion_segment,

    -- ── Goal breakdown (carried from mart_trial_goals for transparency) ────
    a.goal_1_core_scheduling,
    a.goal_2_schedule_visibility,
    a.goal_3_time_tracking,
    a.goal_4_payroll_approval,
    a.goal_5_team_comms,
    a.goals_completed_count,

    -- ── Funnel position ───────────────────────────────────────────────────
    b.sequential_funnel_stage,
    b.first_incomplete_goal,

    -- ── Segmentation ──────────────────────────────────────────────────────
    a.engagement_tier,
    a.unique_activities_used,
    a.total_events,

    -- ── Audit ─────────────────────────────────────────────────────────────
    NOW()                                   AS created_at

FROM activation   a
LEFT JOIN bottleneck b USING (organization_id)
ORDER BY a.organization_id;

-- Primary key
ALTER TABLE marts.mart_trial_activation ADD PRIMARY KEY (organization_id);

-- Sanity check
DO $$
BEGIN
    RAISE NOTICE '─────────────────────────────────────────────';
    RAISE NOTICE 'marts.mart_trial_activation created';
    RAISE NOTICE '  Total orgs             : %  (expected: 966)', (SELECT COUNT(*) FROM marts.mart_trial_activation);
    RAISE NOTICE '  Trial Activated        : %  (expected:  65)', (SELECT COUNT(*) FROM marts.mart_trial_activation WHERE trial_activated);
    RAISE NOTICE '  Activation rate        : %.1f%%  (expected: 6.7%%)', (SELECT ROUND(AVG(trial_activated::INT)*100,1) FROM marts.mart_trial_activation);
    RAISE NOTICE '  Overall conv rate      : %.1f%%  (expected: 21.3%%)', (SELECT ROUND(AVG(converted::INT)*100,1) FROM marts.mart_trial_activation);
    RAISE NOTICE '─────────────────────────────────────────────';
    RAISE NOTICE 'Activation × Conversion Segments:';
    RAISE NOTICE '  Activated & Converted        : %  (expected: 11)', (SELECT COUNT(*) FROM marts.mart_trial_activation WHERE activation_conversion_segment = 'Activated & Converted');
    RAISE NOTICE '  Activated, Not Converted     : %  (expected: 54)', (SELECT COUNT(*) FROM marts.mart_trial_activation WHERE activation_conversion_segment = 'Activated, Not Converted');
    RAISE NOTICE '  Converted without Activation : %  (expected: 195)',(SELECT COUNT(*) FROM marts.mart_trial_activation WHERE activation_conversion_segment = 'Converted without Activation');
    RAISE NOTICE '  Not Activated, Not Converted : %  (expected: 706)',(SELECT COUNT(*) FROM marts.mart_trial_activation WHERE activation_conversion_segment = 'Not Activated, Not Converted');
    RAISE NOTICE '─────────────────────────────────────────────';
    RAISE NOTICE 'Task 2 complete.';
END $$;
