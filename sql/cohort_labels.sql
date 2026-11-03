WITH hf_admissions AS (
    SELECT DISTINCT
        a.subject_id,
        a.hadm_id,
        a.admittime,
        a.dischtime
    FROM mimiciv_hosp.admissions a
    JOIN mimiciv_hosp.diagnoses_icd d
        ON a.hadm_id = d.hadm_id
    WHERE d.seq_num = 1
      AND (
          (d.icd_version = 9 AND d.icd_code LIKE '428%')
          OR
          (d.icd_version = 10 AND d.icd_code LIKE 'I50%')
      )
      AND a.hospital_expire_flag = 0
      AND a.dischtime IS NOT NULL
),
admission_history AS (
    SELECT
        h.hadm_id,
        COUNT(past.hadm_id) AS prior_admission_count,
        COUNT(past.hadm_id) FILTER (
            WHERE past.admittime >=
                h.admittime - INTERVAL '365 days'
        ) AS prior_admission_count_365d
    FROM hf_admissions h
    LEFT JOIN mimiciv_hosp.admissions past
        ON h.subject_id = past.subject_id
       AND past.hadm_id <> h.hadm_id
       AND past.admittime < h.admittime
       AND past.dischtime < h.admittime
    GROUP BY h.hadm_id
)
SELECT
    h.subject_id,
    h.hadm_id,
    h.admittime,
    h.dischtime,

    p.anchor_age
        + EXTRACT(YEAR FROM h.admittime)::INTEGER
        - p.anchor_year AS age,

    p.gender,

    EXTRACT(EPOCH FROM (h.dischtime - h.admittime))
        / 86400.0 AS los_days,

    hist.prior_admission_count,
    hist.prior_admission_count_365d,

    -- 잠정 레이블: ELECTIVE 제외 기준
    CASE WHEN EXISTS (
        SELECT 1
        FROM mimiciv_hosp.admissions r
        WHERE r.subject_id = h.subject_id
          AND r.hadm_id <> h.hadm_id
          AND r.admittime > h.dischtime
          AND r.admittime <=
              h.dischtime + INTERVAL '30 days'
          AND r.admission_type <> 'ELECTIVE'
    )
    THEN 1 ELSE 0 END AS readmission_30d_unplanned

FROM hf_admissions h
LEFT JOIN mimiciv_hosp.patients p
    ON h.subject_id = p.subject_id
LEFT JOIN admission_history hist
    ON h.hadm_id = hist.hadm_id
ORDER BY h.subject_id, h.admittime, h.hadm_id;
