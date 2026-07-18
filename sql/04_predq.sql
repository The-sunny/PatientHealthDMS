-- 04_predq.sql
-- Pre-transform data quality on bronze. One dq_results row per check per
-- table: null counts on key fields, referential integrity (child patient_id
-- must exist in patients), duplicate detection, and code-format sanity for
-- the coding systems Synthea actually uses (SNOMED/RxNorm/LOINC/CVX).
-- Every check's metric_value is a violation COUNT; threshold is always 0
-- (zero violations expected); pass_fail flips to FAIL above threshold.
--
-- Gate vs. warning: NULL_RATE and REFERENTIAL_INTEGRITY failures mean data
-- that can't safely join/transform downstream, so they count toward
-- p_gate_fail_count and the orchestrator aborts on them. DUPLICATE and
-- CODE_FORMAT failures are logged to dq_results (fully visible/auditable,
-- pass_fail = FAIL) but don't count toward the gate — they're expected,
-- permanent quirks of this raw CSV (e.g. observations legitimately mixes
-- LOINC with SNOMED and survey-metric codes), not corruption.

DROP PROCEDURE IF EXISTS control.sp_predq_run(OUT BIGINT, OUT INT);

CREATE OR REPLACE PROCEDURE control.sp_predq_run(OUT p_run_id BIGINT, OUT p_gate_fail_count INT)
LANGUAGE plpgsql
AS $$
DECLARE
    r          RECORD;
    v_run_id   BIGINT;
    v_gate_fails INT := 0;
    v_warn_fails INT := 0;
    v_total    BIGINT;
    v_bad      BIGINT;
    v_pattern  TEXT;
BEGIN
    INSERT INTO control.pipeline_run_log (run_type, status)
    VALUES ('PRE_DQ', 'RUNNING')
    RETURNING run_id INTO v_run_id;

    -- patients: the one table with no patient_id/code column of its own.
    EXECUTE 'SELECT count(*) FROM bronze.patients' INTO v_total;

    EXECUTE format('SELECT count(*) FROM bronze.patients WHERE id IS NULL OR id = %L', '') INTO v_bad;
    INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
    VALUES (v_run_id, 'BRONZE', 'patients', 'null_count_id', 'NULL_RATE', v_bad, 0,
            CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s of %s rows', v_bad, v_total));
    IF v_bad > 0 THEN v_gate_fails := v_gate_fails + 1; END IF;

    EXECUTE format('SELECT count(*) FROM bronze.patients WHERE birthdate IS NULL OR birthdate = %L', '') INTO v_bad;
    INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
    VALUES (v_run_id, 'BRONZE', 'patients', 'null_count_birthdate', 'NULL_RATE', v_bad, 0,
            CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s of %s rows', v_bad, v_total));
    IF v_bad > 0 THEN v_gate_fails := v_gate_fails + 1; END IF;

    EXECUTE 'SELECT count(*) - count(DISTINCT id) FROM bronze.patients' INTO v_bad;
    INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
    VALUES (v_run_id, 'BRONZE', 'patients', 'duplicate_id', 'DUPLICATE', v_bad, 0,
            CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s duplicate ids of %s rows', v_bad, v_total));
    IF v_bad > 0 THEN v_warn_fails := v_warn_fails + 1; END IF;

    -- the 11 child clinical tables, each carrying patient_id + code.
    FOR r IN
        SELECT * FROM (VALUES
            ('encounters',       'start', 'id',      NULL::text, 'code'),
            ('conditions',       'start', NULL::text, 'SNOMED',  'code'),
            ('medications',      'start', NULL::text, 'RXNORM',  'code'),
            ('procedures',       'start', NULL::text, 'SNOMED',  'code'),
            ('observations',     'date',  NULL::text, 'LOINC',   'code'),
            ('immunizations',    'date',  NULL::text, 'CVX',     'code'),
            ('allergies',        'start', NULL::text, NULL::text,'code'),
            ('careplans',        'start', 'id',       NULL::text,'code'),
            ('devices',          'start', NULL::text, NULL::text,'code'),
            -- id is the study-grain id, shared across an image's series/instance
            -- rows by design; instance_uid is the true row-grain PK candidate.
            ('imaging_studies',  'date',  'instance_uid', NULL::text,'procedure_code'),
            ('supplies',         'date',  NULL::text, NULL::text,'code')
        ) AS t(table_name, date_col, id_col, code_system, code_col)
    LOOP
        EXECUTE format('SELECT count(*) FROM bronze.%I', r.table_name) INTO v_total;

        -- null-rate: patient_id
        EXECUTE format('SELECT count(*) FROM bronze.%I WHERE patient_id IS NULL OR patient_id = %L', r.table_name, '') INTO v_bad;
        INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
        VALUES (v_run_id, 'BRONZE', r.table_name, 'null_count_patient_id', 'NULL_RATE', v_bad, 0,
                CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s of %s rows', v_bad, v_total));
        IF v_bad > 0 THEN v_gate_fails := v_gate_fails + 1; END IF;

        -- null-rate: primary date column
        EXECUTE format('SELECT count(*) FROM bronze.%I WHERE %I IS NULL OR %I = %L', r.table_name, r.date_col, r.date_col, '') INTO v_bad;
        INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
        VALUES (v_run_id, 'BRONZE', r.table_name, format('null_count_%s', r.date_col), 'NULL_RATE', v_bad, 0,
                CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s of %s rows', v_bad, v_total));
        IF v_bad > 0 THEN v_gate_fails := v_gate_fails + 1; END IF;

        -- null-rate: code
        EXECUTE format('SELECT count(*) FROM bronze.%I WHERE %I IS NULL OR %I = %L', r.table_name, r.code_col, r.code_col, '') INTO v_bad;
        INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
        VALUES (v_run_id, 'BRONZE', r.table_name, format('null_count_%s', r.code_col), 'NULL_RATE', v_bad, 0,
                CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s of %s rows', v_bad, v_total));
        IF v_bad > 0 THEN v_gate_fails := v_gate_fails + 1; END IF;

        -- referential integrity: patient_id must exist in bronze.patients
        EXECUTE format(
            'SELECT count(*) FROM bronze.%I c WHERE c.patient_id IS NOT NULL AND c.patient_id <> %L
               AND NOT EXISTS (SELECT 1 FROM bronze.patients p WHERE p.id = c.patient_id)',
            r.table_name, ''
        ) INTO v_bad;
        INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
        VALUES (v_run_id, 'BRONZE', r.table_name, 'ri_orphan_patient_id', 'REFERENTIAL_INTEGRITY', v_bad, 0,
                CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s of %s rows reference a missing patient', v_bad, v_total));
        IF v_bad > 0 THEN v_gate_fails := v_gate_fails + 1; END IF;

        -- duplicate detection: PK-candidate id if present, else full-row dup
        IF r.id_col IS NOT NULL THEN
            EXECUTE format('SELECT count(*) - count(DISTINCT %I) FROM bronze.%I', r.id_col, r.table_name) INTO v_bad;
            INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
            VALUES (v_run_id, 'BRONZE', r.table_name, 'duplicate_id', 'DUPLICATE', v_bad, 0,
                    CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s duplicate ids of %s rows', v_bad, v_total));
        ELSE
            EXECUTE format(
                'SELECT COALESCE(SUM(c - 1), 0) FROM (SELECT count(*) c FROM bronze.%I t GROUP BY to_jsonb(t) - ''load_batch_id'' - ''loaded_at'') d',
                r.table_name
            ) INTO v_bad;
            INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
            VALUES (v_run_id, 'BRONZE', r.table_name, 'duplicate_full_row', 'DUPLICATE', v_bad, 0,
                    CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s excess full-row duplicates of %s rows', v_bad, v_total));
        END IF;
        IF v_bad > 0 THEN v_warn_fails := v_warn_fails + 1; END IF;

        -- code-format sanity, only for tables with a known coding system
        IF r.code_system IS NOT NULL THEN
            v_pattern := CASE WHEN r.code_system = 'LOINC' THEN '^\d+-\d$' ELSE '^\d+$' END;
            EXECUTE format(
                'SELECT count(*) FROM bronze.%I WHERE %I IS NOT NULL AND %I <> %L AND %I !~ %L',
                r.table_name, r.code_col, r.code_col, '', r.code_col, v_pattern
            ) INTO v_bad;
            INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
            VALUES (v_run_id, 'BRONZE', r.table_name, format('code_format_%s', lower(r.code_system)), 'CODE_FORMAT', v_bad, 0,
                    CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END,
                    format('%s of %s codes fail %s pattern %s', v_bad, v_total, r.code_system, v_pattern));
            IF v_bad > 0 THEN v_warn_fails := v_warn_fails + 1; END IF;
        END IF;
    END LOOP;

    UPDATE control.pipeline_run_log
    SET ended_at = now(),
        status = CASE WHEN v_gate_fails = 0 THEN 'SUCCESS' ELSE 'FAILED' END,
        notes = format('gate_fail_count=%s, warn_fail_count=%s', v_gate_fails, v_warn_fails)
    WHERE run_id = v_run_id;

    p_run_id := v_run_id;
    p_gate_fail_count := v_gate_fails;
    COMMIT;
END;
$$;

CALL control.sp_predq_run(NULL, NULL);
