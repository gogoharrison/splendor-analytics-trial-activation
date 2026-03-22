# Splendor Analytics — Trial Activation 

## The Problem

Splendor Analytics runs a 30-day free trial for new organisations signing up to its workforce management platform — covering shift scheduling, time tracking, payroll approvals, and team communications.

The core challenge: the product team has no definition of what a "good" trial looks like. While roughly 1 in 5 trialists eventually converts to a paying customer, the team cannot identify who is on track to convert, when to intervene, or which in-app behaviours actually drive the decision. Without that clarity, every onboarding improvement is a guess.

This project solves that by:
1. Defining **Trial Activation** — a specific set of in-app behaviours that signal a trialist has genuinely experienced the platform's core value.
2. Building the **data infrastructure** to track activation at scale using SQL mart models.
3. Running **descriptive analytics** to surface actionable insights for the product and onboarding teams.

---

## Dataset

| Column | Type | Description |
|---|---|---|
| `ORGANIZATION_ID` | string | Unique identifier for each trialling organisation |
| `ACTIVITY_NAME` | string | Name of the in-app activity performed |
| `TIMESTAMP` | datetime | When the activity occurred |
| `CONVERTED` | boolean | Whether the organisation converted to paid |
| `CONVERTED_AT` | datetime | Conversion timestamp (NaT if not converted) |
| `TRIAL_START` | datetime | When the trial started |
| `TRIAL_END` | datetime | Trial expiry date (trial_start + 30 days) |

**Raw size:** 170,526 rows × 7 columns  
**After cleaning:** 102,895 rows — 67,631 exact duplicates removed  
**Organisations:** 966 total | 206 converted (21.3%) | 760 did not convert  
**Trial period:** January – March  
**Unique activities:** 28 across 5 product modules

---

## Task 1 — Data Cleaning, EDA & Trial Goal Definition

### Step 1 — Data Cleaning
- Loaded and inspected the raw dataset (170,526 rows × 7 columns)
- Parsed all datetime columns from string to proper datetime objects
- Audited every column for null values — `CONVERTED_AT` is expectedly null for non-converters
- Detected and removed **67,631 exact duplicate rows** (39.7% of raw data)
- Validated consistency — all `CONVERTED=True` organisations have a `CONVERTED_AT` timestamp
- Derived trial-context fields: `days_into_trial`, `trial_length_days`, `event_within_trial`
- Exported cleaned data as `outputs/stg_events_clean.csv` for use in Tasks 2 and 3

### Step 2 — Organisation-Level Feature Matrix
- Aggregated the cleaned event log to organisation level (966 rows × 34 columns)
- Pivoted 28 activity types into individual count columns per organisation
- Derived `days_to_convert`, `trial_active_days`, `unique_acts`, and `engagement_tier`

### Step 3 — Exploratory Data Analysis
- Overall conversion rate (21.3%) and event volume distributions
- Activity adoption rates across all 28 activities
- Conversion rate by activity usage vs baseline
- Time-to-convert distribution for the 206 converted organisations

### Step 4 — Conversion Driver Analysis (Multi-Method)

| Method | Finding |
|---|---|
| Point-Biserial Correlation | 0 / 28 activities significant (all p > 0.05) |
| Chi-Squared Test | No activity achieves p < 0.05; lift values ≈ 1.0 |
| Random Forest (300 trees, CV AUC) | AUC ≈ 0.50 — no better than random |
| Engagement Segmentation | Conversion stable across all tiers (20–23%) |

**Key finding:** Conversion is **intent-driven, not behaviour-driven**. Goals are defined on product-value logic and must be validated via A/B testing.

### Step 5 — Trial Goal Definition

| Goal | Condition | Rationale | Completion Rate |
|---|---|---|---|
| G1 — Core Scheduling | ≥ 3 shifts created | Active recurring scheduling use | 58.3% |
| G2 — Schedule Visibility | ≥ 3 schedule views | Team members checking schedule daily | 36.0% |
| G3 — Time Tracking | ≥ 1 punch-in event | Live time & attendance operational | 21.8% |
| G4 — Payroll Approval | ≥ 1 shift approved | Full payroll loop closed | 20.7% |
| G5 — Team Communications | ≥ 1 message sent | Communication module adopted | 15.0% |

> **Trial Activation = All 5 goals completed → 65 / 966 organisations (6.7%)**

---

## Task 2 — SQL Data Models (Marts Layer)

**Database:** PostgreSQL | **Tool:** pgAdmin  
**Source:** `outputs/stg_events_clean.csv` — the cleaned output of Task 1

### Layer Architecture

```
stg_events_clean.csv  (Task 1 Python output)
        │
        ▼
[1] stg/stg_events_raw.sql          → staging.stg_events_raw         (TABLE)
        │
        ▼
[2] stg/stg_events.sql              → staging.stg_events              (VIEW)
        │
        ▼
[3] stg/int_org_activity_counts.sql → staging.int_org_activity_counts (TABLE)
        │
        ▼
[4] marts/mart_trial_goals.sql      → marts.mart_trial_goals          (TABLE)
        │
        ▼
[5] marts/mart_trial_activation.sql → marts.mart_trial_activation     (TABLE)
```

### Run Order in pgAdmin

Run each file in pgAdmin (`File → Open File → F5`) in this exact order:

| Step | File | Creates |
|---|---|---|
| 1 | `sql/stg/stg_events_raw.sql` | `staging.stg_events_raw` — loads the cleaned CSV |
| 2 | `sql/stg/stg_events.sql` | `staging.stg_events` — view adding `days_to_convert` + `module_name` |
| 3 | `sql/stg/int_org_activity_counts.sql` | `staging.int_org_activity_counts` — aggregated per org × activity |
| 4 | `sql/marts/mart_trial_goals.sql` | `marts.mart_trial_goals` — 5 goal flags per org |
| 5 | `sql/marts/mart_trial_activation.sql` | `marts.mart_trial_activation` — activation status + bottleneck |

> **Before running Step 1:** open `sql/stg/stg_events_raw.sql` and update the `COPY` file path to point to your local `outputs/stg_events_clean.csv`. Then use pgAdmin's **Import/Export Data** tool (right-click `stg_events_raw` → Import/Export Data) to load the CSV — leave the Columns tab empty so pgAdmin maps columns automatically from the header row.

### mart_trial_goals — Grain: one row per organisation

| Column | Type | Description |
|---|---|---|
| `organization_id` | TEXT | Unique org identifier |
| `goal_1_core_scheduling` | BOOLEAN | Created ≥ 3 shifts |
| `goal_2_schedule_visibility` | BOOLEAN | Viewed schedule ≥ 3 times |
| `goal_3_time_tracking` | BOOLEAN | At least 1 punch-in |
| `goal_4_payroll_approval` | BOOLEAN | At least 1 shift approved |
| `goal_5_team_comms` | BOOLEAN | At least 1 message sent |
| `goals_completed_count` | INTEGER | Total goals completed (0–5) |

### mart_trial_activation — Grain: one row per organisation

| Column | Type | Description |
|---|---|---|
| `organization_id` | TEXT | Unique org identifier |
| `trial_activated` | BOOLEAN | TRUE if all 5 goals completed |
| `activation_status` | TEXT | 'Activated' / 'Not Activated' |
| `activation_conversion_segment` | TEXT | 4-way cross-segment |
| `first_incomplete_goal` | TEXT | First goal that blocked activation |
| `sequential_funnel_stage` | INTEGER | How far through the funnel (0–5) |
| `engagement_tier` | TEXT | Minimal / Low / Medium / High |

### Expected Output After Running All Steps

```
staging.stg_events_raw          → 102,895 rows  (expected)
staging.stg_events              → 102,895 rows  (expected)
staging.int_org_activity_counts → up to 966 × 28 rows
marts.mart_trial_goals          → 966 rows (one per org)
marts.mart_trial_activation     → 966 rows (one per org)
```

---

## Task 3 — Descriptive Analytics & Product Metrics

**Notebook:** `notebooks/task3_product_analytics.ipynb`  
**Source:** `outputs/stg_events_clean.csv` + `outputs/stg_org_features.csv`


### Metrics Computed

| Metric | Value |
|---|---|
| Overall conversion rate | **21.3%** |
| Jan / Feb / Mar cohort conversion | 23.0% / 22.8% / 18.2% |
| Trial activation rate | **6.7%** |
| Conv rate — activated orgs | 16.9% |
| Conv rate — not activated orgs | 21.6% |
| Median time-to-convert | **30 days** (trial deadline) |
| % converting within 14 days | 1.5% |
| Scheduling module adoption | 88.0% |
| Time & Attendance adoption | 21.8% |
| Communications adoption | 15.0% |
| Biggest sequential funnel drop-off | G1 → G2 **(54.5%)** |
| Week 1 → Week 2 retention drop | **96% → 21%** |

### Visualisations Produced

| Chart | Metric | Description |
|---|---|---|
| Chart 1 | Conversion Rate | Overall pie + monthly cohort bar |
| Chart 2 | Trial Activation | KPI summary cards + goal completion counts |
| Chart 3 | Module Adoption | Adoption rate vs conversion rate per module |
| Chart 4 | Time-to-Convert | Distribution with Day 7 / 14 / 30 markers |
| Chart 5 | Daily Engagement | Events per org per trial day (converted vs not) |
| Charts 6 & 7 | Goal Funnel | Sequential funnel + goals by conversion status |
| Chart 8 | Engagement Depth | Median events per org per activity (top 12) |
| Chart 9 | Weekly Retention | % of orgs active per trial week |
| Charts 10 & 11 | Bottleneck | First incomplete goal + conv rate by goals completed |

### Key Findings

1. **Conversion is intent-driven** — no in-trial behaviour is statistically linked to conversion (all p > 0.05, CV AUC ≈ 0.50)
2. **Scheduling is universal** — 88% of orgs create shifts; it is the natural onboarding entry point
3. **Time tracking has the biggest adoption gap** — only 21.8% of orgs ever punch in
4. **Team comms is the least discovered feature** — only 15.0% adoption
5. **Conversions cluster at Day 30** — most orgs wait until the trial deadline to decide
6. **Engagement drops steeply after Week 1** — Week 2 activity is only ~21% of Week 1
7. **Activation bottleneck is at G1 → G2** — 54.5% of orgs that schedule never view the schedule

### Business Recommendations

1. Invest in pre-trial sales qualification — conversion is intent-driven, not nudge-driven
2. Build onboarding around scheduling — it is the universal entry point for 88% of orgs
3. Introduce a Day 3–5 in-app prompt to drive time tracking adoption
4. A/B test surfacing team communications in the onboarding checklist
5. Send a Day 20 "trial ending soon" email to drive earlier conversion decisions
6. Build an interactive onboarding checklist to guide orgs through all 5 goals
7. Introduce weekly digest emails to re-engage orgs that go quiet after Week 1

---

## How to Run

### Prerequisites

```bash
pip install -r requirements.txt
```

### Task 1 — Run First

Open and run `notebooks/task1_eda_trial_goals.ipynb` top to bottom.

**Outputs generated:**
- `outputs/stg_events_clean.csv` — cleaned event log (required by Task 2 and Task 3)
- `outputs/stg_org_features.csv` — org-level feature matrix (required by Task 3)
- `outputs/task1_*.png` — EDA and analysis charts

### Task 2 — Run After Task 1

1. Confirm `outputs/stg_events_clean.csv` exists
2. Open `sql/stg/stg_events_raw.sql` — create the table by running it in pgAdmin
3. Right-click `staging.stg_events_raw` in pgAdmin → **Import/Export Data** → import `stg_events_clean.csv` (leave Columns tab empty)
4. Run steps 2–5 in order using pgAdmin

### Task 3 — Run After Task 1

1. Confirm both output CSV files exist
2. Open `notebooks/task3_product_analytics.ipynb`
3. Run all **Cells** in order

---

## Assumptions & Limitations

- **Goals are analytical hypotheses, not proven causal levers.** No individual goal achieves statistical significance (all p > 0.05). Goals should be validated through controlled A/B testing before being used as operational KPIs.
- **Duplicate removal strategy:** Exact (organisation + activity + timestamp) triplet duplicates were removed. Near-duplicates with slightly different timestamps are retained as genuine separate events.
- **SQL dialect:** PostgreSQL. Minor syntax adjustments required for BigQuery (`INT64` casting) or Snowflake (`DATEDIFF`).
- **CSV loading:** `stg_events_raw.sql` uses pgAdmin's Import/Export tool instead of a server-side `COPY` command due to Windows file permission constraints on the PostgreSQL server process.

---
