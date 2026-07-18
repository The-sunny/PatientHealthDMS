-- 05_crosswalk.sql
-- Populate control.patient_crosswalk: one surrogate UUID + random per-patient
-- date offset (±[1,365] days, never 0) per bronze patient. Idempotent via
-- ON CONFLICT DO NOTHING on original_patient_id, so re-running never
-- reshuffles an existing patient's surrogate id or offset.
--
-- Deviates from the plan's literal sp_build_crosswalk(run_id, salt) signature:
-- salt is only used later for identifier tokenization (sp_deid_run), not here,
-- so it's dropped as an unused parameter. This procedure logs its own
-- pipeline_run_log row (run_type = 'DEID', since crosswalk build is a
-- prerequisite sub-step of de-identification), matching the self-contained
-- pattern used by sp_bronze_load_batch/sp_predq_run.

CREATE OR REPLACE PROCEDURE control.sp_build_crosswalk(OUT p_run_id BIGINT, OUT p_rows_affected BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id BIGINT;
    v_rows   BIGINT;
BEGIN
    INSERT INTO control.pipeline_run_log (run_type, status)
    VALUES ('DEID', 'RUNNING')
    RETURNING run_id INTO v_run_id;

    INSERT INTO control.patient_crosswalk (original_patient_id, surrogate_id, date_offset_days)
    SELECT p.id::uuid,
           gen_random_uuid(),
           (1 + floor(random() * 365))::int * (CASE WHEN random() < 0.5 THEN -1 ELSE 1 END)
    FROM bronze.patients p
    ON CONFLICT (original_patient_id) DO NOTHING;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    UPDATE control.pipeline_run_log
    SET ended_at = now(),
        status = 'SUCCESS',
        rows_affected = v_rows,
        notes = 'crosswalk build'
    WHERE run_id = v_run_id;

    p_run_id := v_run_id;
    p_rows_affected := v_rows;
    COMMIT;
END;
$$;

CALL control.sp_build_crosswalk(NULL, NULL);
