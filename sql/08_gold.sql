-- 08_gold.sql
-- Gold DDL + build procedure: a single wide patient_summary fact table, one
-- row per surrogate patient, joining silver demographics with per-patient
-- event counts and encounter date bounds.

DROP TABLE IF EXISTS gold.patient_summary;
CREATE TABLE gold.patient_summary (
    patient_id                UUID PRIMARY KEY,
    zip3                       TEXT,
    age_bucket                 TEXT,
    race                       TEXT,
    ethnicity                  TEXT,
    gender                     TEXT,
    encounter_count             BIGINT NOT NULL,
    condition_count             BIGINT NOT NULL,
    medication_count            BIGINT NOT NULL,
    procedure_count             BIGINT NOT NULL,
    immunization_count           BIGINT NOT NULL,
    distinct_condition_codes     BIGINT NOT NULL,
    first_encounter_date         TIMESTAMPTZ,
    last_encounter_date          TIMESTAMPTZ
);

CREATE OR REPLACE PROCEDURE gold.sp_gold_build(OUT p_run_id BIGINT, OUT p_rows_affected BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id BIGINT;
    v_rows   BIGINT;
BEGIN
    INSERT INTO control.pipeline_run_log (run_type, status)
    VALUES ('GOLD', 'RUNNING')
    RETURNING run_id INTO v_run_id;

    TRUNCATE TABLE gold.patient_summary;

    INSERT INTO gold.patient_summary (
        patient_id, zip3, age_bucket, race, ethnicity, gender,
        encounter_count, condition_count, medication_count, procedure_count, immunization_count,
        distinct_condition_codes, first_encounter_date, last_encounter_date
    )
    SELECT
        p.patient_id, p.zip3, p.age_bucket, p.race, p.ethnicity, p.gender,
        COALESCE(enc.cnt, 0), COALESCE(cond.cnt, 0), COALESCE(med.cnt, 0), COALESCE(proc.cnt, 0), COALESCE(imm.cnt, 0),
        COALESCE(cond.distinct_codes, 0), enc.first_dt, enc.last_dt
    FROM silver.patients p
    LEFT JOIN (
        SELECT patient_id, count(*) AS cnt, min(start) AS first_dt, max(start) AS last_dt
        FROM silver.encounters GROUP BY patient_id
    ) enc ON enc.patient_id = p.patient_id
    LEFT JOIN (
        SELECT patient_id, count(*) AS cnt, count(DISTINCT code) AS distinct_codes
        FROM silver.conditions GROUP BY patient_id
    ) cond ON cond.patient_id = p.patient_id
    LEFT JOIN (SELECT patient_id, count(*) AS cnt FROM silver.medications GROUP BY patient_id) med ON med.patient_id = p.patient_id
    LEFT JOIN (SELECT patient_id, count(*) AS cnt FROM silver.procedures GROUP BY patient_id) proc ON proc.patient_id = p.patient_id
    LEFT JOIN (SELECT patient_id, count(*) AS cnt FROM silver.immunizations GROUP BY patient_id) imm ON imm.patient_id = p.patient_id;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    UPDATE control.pipeline_run_log
    SET ended_at = now(), status = 'SUCCESS', rows_affected = v_rows, notes = 'gold.patient_summary build'
    WHERE run_id = v_run_id;

    p_run_id := v_run_id;
    p_rows_affected := v_rows;
    COMMIT;
END;
$$;

CALL gold.sp_gold_build(NULL, NULL);
