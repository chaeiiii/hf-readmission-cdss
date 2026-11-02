-- ============================================================================
-- Heart failure 30-day unplanned readmission | B: laboratory features
-- MIMIC-IV PostgreSQL | version: 2026-11-02
-- ============================================================================
-- PURPOSE
--   Reproduce 10 lab analytes x first/last = 20 features for the *index*
--   heart-failure hospitalization, at the index discharge prediction time.
--
-- INPUT (prepared by cohort owner / A)
--   public.hf_cohort(subject_id, hadm_id, admittime, dischtime)
--   Expected initial cohort: 8,077 distinct hadm_id; cohort definition may change.
--   This script does NOT generate a cohort or readmission label.
--
-- OUTPUT
--   public.hf_lab_features: one row per hadm_id, 2 IDs + 20 numeric features
--
-- RULES
--   - Match both subject_id and hadm_id.
--   - charttime within [admittime, dischtime], storetime <= dischtime;
--     hence results documented after discharge are excluded.
--   - Only numeric valuenum; no imputation, outlier deletion or patient exclusion.
--   - first/last sorted by charttime, storetime, labevent_id for tie-breaking.
--   - Only selected principal itemids; alternative lab codes are not merged.
--   - Assumes first/last measurements use comparable units for each itemid;
--     verify units with quality checks below.
--   - Run CREATE once; if rebuilding, first archive/rename old output and
--     remove it deliberately. Never DROP shared tables by default.
-- ============================================================================

-- 0. Input verification (read-only)
SELECT
    COUNT(*) AS cohort_admissions,
    COUNT(DISTINCT subject_id) AS cohort_patients,
    COUNT(DISTINCT hadm_id) AS unique_hadm_ids,
    COUNT(*) FILTER (WHERE subject_id IS NULL OR hadm_id IS NULL
                         OR admittime IS NULL OR dischtime IS NULL) AS missing_required,
    COUNT(*) FILTER (WHERE dischtime < admittime) AS invalid_time_order
FROM public.hf_cohort;

-- 1. Create lab feature table. Run once after input verification.
CREATE TABLE public.hf_lab_features AS
WITH ranked_labs AS (
    SELECT
        c.subject_id,
        c.hadm_id,
        l.itemid,
        l.valuenum,
        ROW_NUMBER() OVER (
            PARTITION BY c.subject_id, c.hadm_id, l.itemid
            ORDER BY l.charttime ASC, l.storetime ASC NULLS LAST,
                     l.labevent_id ASC
        ) AS rn_first,
        ROW_NUMBER() OVER (
            PARTITION BY c.subject_id, c.hadm_id, l.itemid
            ORDER BY l.charttime DESC, l.storetime DESC NULLS LAST,
                     l.labevent_id DESC
        ) AS rn_last
    FROM public.hf_cohort AS c
    JOIN mimiciv_hosp.labevents AS l
      ON c.subject_id = l.subject_id
     AND c.hadm_id = l.hadm_id
    WHERE l.itemid IN (
        50912, -- creatinine
        51006, -- blood urea nitrogen
        50983, -- sodium
        50971, -- potassium
        51222, -- hemoglobin
        50862, -- albumin
        51301, -- white blood cells
        51265, -- platelet count
        50882, -- bicarbonate
        50931  -- glucose
    )
      AND l.charttime >= c.admittime
      AND l.charttime <= c.dischtime
      AND l.storetime <= c.dischtime
      AND l.valuenum IS NOT NULL
),
lab_agg AS (
    SELECT
        subject_id,
        hadm_id,
        itemid,
        MAX(valuenum) FILTER (WHERE rn_first = 1) AS first_value,
        MAX(valuenum) FILTER (WHERE rn_last  = 1) AS last_value
    FROM ranked_labs
    GROUP BY subject_id, hadm_id, itemid
)
SELECT
    c.subject_id,
    c.hadm_id,
    MAX(a.first_value) FILTER (WHERE a.itemid = 50912) AS creatinine_first,
    MAX(a.last_value)  FILTER (WHERE a.itemid = 50912) AS creatinine_last,
    MAX(a.first_value) FILTER (WHERE a.itemid = 51006) AS bun_first,
    MAX(a.last_value)  FILTER (WHERE a.itemid = 51006) AS bun_last,
    MAX(a.first_value) FILTER (WHERE a.itemid = 50983) AS sodium_first,
    MAX(a.last_value)  FILTER (WHERE a.itemid = 50983) AS sodium_last,
    MAX(a.first_value) FILTER (WHERE a.itemid = 50971) AS potassium_first,
    MAX(a.last_value)  FILTER (WHERE a.itemid = 50971) AS potassium_last,
    MAX(a.first_value) FILTER (WHERE a.itemid = 51222) AS hemoglobin_first,
    MAX(a.last_value)  FILTER (WHERE a.itemid = 51222) AS hemoglobin_last,
    MAX(a.first_value) FILTER (WHERE a.itemid = 50862) AS albumin_first,
    MAX(a.last_value)  FILTER (WHERE a.itemid = 50862) AS albumin_last,
    MAX(a.first_value) FILTER (WHERE a.itemid = 51301) AS wbc_first,
    MAX(a.last_value)  FILTER (WHERE a.itemid = 51301) AS wbc_last,
    MAX(a.first_value) FILTER (WHERE a.itemid = 51265) AS platelet_first,
    MAX(a.last_value)  FILTER (WHERE a.itemid = 51265) AS platelet_last,
    MAX(a.first_value) FILTER (WHERE a.itemid = 50882) AS bicarbonate_first,
    MAX(a.last_value)  FILTER (WHERE a.itemid = 50882) AS bicarbonate_last,
    MAX(a.first_value) FILTER (WHERE a.itemid = 50931) AS glucose_first,
    MAX(a.last_value)  FILTER (WHERE a.itemid = 50931) AS glucose_last
FROM public.hf_cohort AS c
LEFT JOIN lab_agg AS a
  ON c.subject_id = a.subject_id
 AND c.hadm_id = a.hadm_id
GROUP BY c.subject_id, c.hadm_id;

-- 2. Output integrity checks
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT subject_id) AS unique_subjects,
    COUNT(DISTINCT hadm_id) AS unique_admissions,
    COUNT(*) - COUNT(DISTINCT hadm_id) AS duplicate_hadm_rows,
    COUNT(*) FILTER (WHERE subject_id IS NULL OR hadm_id IS NULL) AS missing_ids,
    (SELECT COUNT(*) FROM public.hf_cohort) AS expected_rows
FROM public.hf_lab_features;

-- 3. Coverage/missingness for each of 20 features
SELECT
    v.variable_name,
    COUNT(v.value) AS available,
    COUNT(*) - COUNT(v.value) AS missing,
    ROUND(100.0 * (COUNT(*) - COUNT(v.value)) / NULLIF(COUNT(*), 0), 2) AS missing_pct
FROM public.hf_lab_features AS f
CROSS JOIN LATERAL (
    VALUES
        ('creatinine_first', f.creatinine_first), ('creatinine_last', f.creatinine_last),
        ('bun_first', f.bun_first), ('bun_last', f.bun_last),
        ('sodium_first', f.sodium_first), ('sodium_last', f.sodium_last),
        ('potassium_first', f.potassium_first), ('potassium_last', f.potassium_last),
        ('hemoglobin_first', f.hemoglobin_first), ('hemoglobin_last', f.hemoglobin_last),
        ('albumin_first', f.albumin_first), ('albumin_last', f.albumin_last),
        ('wbc_first', f.wbc_first), ('wbc_last', f.wbc_last),
        ('platelet_first', f.platelet_first), ('platelet_last', f.platelet_last),
        ('bicarbonate_first', f.bicarbonate_first), ('bicarbonate_last', f.bicarbonate_last),
        ('glucose_first', f.glucose_first), ('glucose_last', f.glucose_last)
) AS v(variable_name, value)
GROUP BY v.variable_name
ORDER BY v.variable_name;

-- 4. Count admissions with no laboratory features at all
SELECT COUNT(*) AS all_lab_features_missing
FROM public.hf_lab_features AS f
WHERE num_nonnulls(
    creatinine_first, creatinine_last,
    bun_first, bun_last, sodium_first, sodium_last,
    potassium_first, potassium_last,
    hemoglobin_first, hemoglobin_last,
    albumin_first, albumin_last,
    wbc_first, wbc_last, platelet_first, platelet_last,
    bicarbonate_first, bicarbonate_last,
    glucose_first, glucose_last
) = 0;

-- 5. Check observed units *within the chosen cohort and time window*
SELECT
    d.label AS lab_name,
    l.itemid,
    COALESCE(l.valueuom, '(NULL)') AS unit,
    COUNT(*) AS record_count
FROM public.hf_cohort AS c
JOIN mimiciv_hosp.labevents AS l
  ON c.subject_id = l.subject_id
 AND c.hadm_id = l.hadm_id
JOIN mimiciv_hosp.d_labitems AS d ON l.itemid = d.itemid
WHERE l.itemid IN (50912,51006,50983,50971,51222,50862,51301,51265,50882,50931)
  AND l.charttime >= c.admittime
  AND l.charttime <= c.dischtime
  AND l.storetime <= c.dischtime
  AND l.valuenum IS NOT NULL
GROUP BY d.label, l.itemid, l.valueuom
ORDER BY d.label, record_count DESC;

-- NOTE: ICU chartevents / OMR vital signs are NOT included in this output.
-- OMR date-only measurements cannot automatically be treated as discharge vitals.
-- CSV export (lab_features.csv) is done from DBeaver. Do NOT commit patient-level
-- MIMIC-IV extracts or derived CSVs to GitHub; commit code/docs only.
