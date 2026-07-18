-- 09_orchestrator.sql
-- Top-level orchestrator chaining pre-DQ -> crosswalk -> de-id -> post-DQ ->
-- gold, aborting if either DQ gate fails. Bronze load isn't chained here: it
-- requires \copy, which is psql-client-only and can't run inside a
-- procedure (see sql/03_load_bronze.sql) -- run.sh already runs that file
-- as its own step before this one when executing the full pipeline.

CREATE OR REPLACE PROCEDURE control.sp_pipeline_run_all(IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id    BIGINT;
    v_gate_fail INT;
    v_rows      BIGINT;
BEGIN
    CALL control.sp_predq_run(v_run_id, v_gate_fail);
    IF v_gate_fail > 0 THEN
        RAISE EXCEPTION 'Pre-DQ gate failed: % check(s) failed (run_id=%). See control.dq_results.', v_gate_fail, v_run_id;
    END IF;

    CALL control.sp_build_crosswalk(v_run_id, v_rows);

    CALL control.sp_deid_run(p_salt, v_run_id, v_rows);

    CALL control.sp_postdq_run(v_run_id, v_gate_fail);
    IF v_gate_fail > 0 THEN
        RAISE EXCEPTION 'Post-DQ gate failed: % check(s) failed (run_id=%). See control.dq_results.', v_gate_fail, v_run_id;
    END IF;

    CALL gold.sp_gold_build(v_run_id, v_rows);

    RAISE NOTICE 'Pipeline completed successfully (gold.patient_summary: % rows).', v_rows;
END;
$$;
