-- 07_postdq.sql
-- Post-transform data quality on silver. Unlike pre-DQ, every check here
-- represents something that should be structurally impossible if the de-id
-- transform is correct (not a permanent quirk of the raw data), so ALL
-- checks count toward the gate (p_gate_fail_count) -- see [[patienthealthdms-pipeline]]
-- memory note on the pre-DQ gate/warning split; post-DQ deliberately doesn't
-- split the same way.

CREATE OR REPLACE PROCEDURE control.sp_postdq_run(OUT p_run_id BIGINT, OUT p_gate_fail_count INT)
LANGUAGE plpgsql
AS $$
DECLARE
    r            RECORD;
    v_run_id     BIGINT;
    v_gate_fails INT := 0;
    v_bronze_n   BIGINT;
    v_silver_n   BIGINT;
    v_bad        BIGINT;
BEGIN
    INSERT INTO control.pipeline_run_log (run_type, status)
    VALUES ('POST_DQ', 'RUNNING')
    RETURNING run_id INTO v_run_id;

    -- 1. row-count parity: every bronze row must have produced exactly one silver row
    FOR r IN
        SELECT * FROM (VALUES
            ('patients'), ('encounters'), ('conditions'), ('medications'), ('procedures'),
            ('observations'), ('immunizations'), ('allergies'), ('careplans'), ('devices'),
            ('imaging_studies'), ('supplies')
        ) AS t(table_name)
    LOOP
        EXECUTE format('SELECT count(*) FROM bronze.%I', r.table_name) INTO v_bronze_n;
        EXECUTE format('SELECT count(*) FROM silver.%I', r.table_name) INTO v_silver_n;
        v_bad := abs(v_bronze_n - v_silver_n);
        INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
        VALUES (v_run_id, 'SILVER', r.table_name, 'row_count_parity', 'ROW_COUNT_PARITY', v_bad, 0,
                CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END,
                format('bronze=%s silver=%s', v_bronze_n, v_silver_n));
        IF v_bad > 0 THEN v_gate_fails := v_gate_fails + 1; END IF;
    END LOOP;

    -- 2. RI survived the id swap: every child patient_id must exist in silver.patients
    FOR r IN
        SELECT * FROM (VALUES
            ('encounters'), ('conditions'), ('medications'), ('procedures'),
            ('observations'), ('immunizations'), ('allergies'), ('careplans'), ('devices'),
            ('imaging_studies'), ('supplies')
        ) AS t(table_name)
    LOOP
        EXECUTE format(
            'SELECT count(*) FROM silver.%I c WHERE NOT EXISTS (SELECT 1 FROM silver.patients p WHERE p.patient_id = c.patient_id)',
            r.table_name
        ) INTO v_bad;
        INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
        VALUES (v_run_id, 'SILVER', r.table_name, 'ri_patient_id_survived', 'REFERENTIAL_INTEGRITY', v_bad, 0,
                CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s orphaned patient_id rows', v_bad));
        IF v_bad > 0 THEN v_gate_fails := v_gate_fails + 1; END IF;
    END LOOP;

    -- 3. date-shift preserved inter-event deltas: per patient, the encounter
    -- start date span (max - min, day-level) must be identical bronze vs silver.
    -- Bronze's start is TEXT, so it must go through the same TEXT ->
    -- TIMESTAMPTZ -> local DATE cast the actual transform uses (06_silver_deid.sql):
    -- a naive TEXT::date cast takes the literal date substring and ignores
    -- timezone, while TEXT::timestamptz::date converts UTC -> session
    -- timezone first -- for early-UTC-morning timestamps that shifts the
    -- local calendar date back a day, and comparing the two casts
    -- inconsistently produces false date-span mismatches.
    SELECT count(*) INTO v_bad FROM (
        SELECT cw.original_patient_id
        FROM control.patient_crosswalk cw
        JOIN LATERAL (
            SELECT max(start::timestamptz::date) - min(start::timestamptz::date) AS span
            FROM bronze.encounters WHERE patient_id = cw.original_patient_id::text
        ) bspan ON true
        JOIN LATERAL (
            SELECT max(start::date) - min(start::date) AS span
            FROM silver.encounters WHERE patient_id = cw.surrogate_id
        ) sspan ON true
        WHERE bspan.span IS DISTINCT FROM sspan.span
    ) mismatches;
    INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
    VALUES (v_run_id, 'SILVER', 'encounters', 'date_delta_preserved', 'DATE_DELTA', v_bad, 0,
            CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s patients with mismatched encounter date span', v_bad));
    IF v_bad > 0 THEN v_gate_fails := v_gate_fails + 1; END IF;

    -- 4. leaked-identifier scan: no original bronze patient id may appear as a
    -- silver patient_id anywhere (silver should only ever carry surrogate ids)
    SELECT count(*) INTO v_bad
    FROM (
        SELECT DISTINCT patient_id FROM silver.patients
        UNION SELECT DISTINCT patient_id FROM silver.encounters
        UNION SELECT DISTINCT patient_id FROM silver.conditions
        UNION SELECT DISTINCT patient_id FROM silver.medications
        UNION SELECT DISTINCT patient_id FROM silver.procedures
        UNION SELECT DISTINCT patient_id FROM silver.observations
        UNION SELECT DISTINCT patient_id FROM silver.immunizations
        UNION SELECT DISTINCT patient_id FROM silver.allergies
        UNION SELECT DISTINCT patient_id FROM silver.careplans
        UNION SELECT DISTINCT patient_id FROM silver.devices
        UNION SELECT DISTINCT patient_id FROM silver.imaging_studies
        UNION SELECT DISTINCT patient_id FROM silver.supplies
    ) used_ids
    WHERE used_ids.patient_id IN (SELECT id::uuid FROM bronze.patients);
    INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
    VALUES (v_run_id, 'SILVER', 'ALL', 'leaked_original_patient_id', 'LEAKED_IDENTIFIER', v_bad, 0,
            CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s original patient ids found in silver', v_bad));
    IF v_bad > 0 THEN v_gate_fails := v_gate_fails + 1; END IF;

    -- 5. token integrity: a *_token column must never equal the raw cleartext
    -- it was derived from (i.e. hashing actually happened, not a passthrough)
    SELECT count(*) INTO v_bad
    FROM bronze.patients b
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = b.id::uuid
    JOIN silver.patients s ON s.patient_id = cw.surrogate_id
    WHERE (NULLIF(b.ssn, '') IS NOT NULL AND s.ssn_token = b.ssn)
       OR (NULLIF(b.drivers, '') IS NOT NULL AND s.drivers_token = b.drivers)
       OR (NULLIF(b.passport, '') IS NOT NULL AND s.passport_token = b.passport)
       OR (NULLIF(b.first, '') IS NOT NULL AND s.first_token = b.first)
       OR (NULLIF(b.last, '') IS NOT NULL AND s.last_token = b.last);
    INSERT INTO control.dq_results (run_id, layer, table_name, check_name, check_type, metric_value, threshold, pass_fail, detail)
    VALUES (v_run_id, 'SILVER', 'patients', 'leaked_cleartext_token', 'LEAKED_IDENTIFIER', v_bad, 0,
            CASE WHEN v_bad = 0 THEN 'PASS' ELSE 'FAIL' END, format('%s rows where a token column equals raw cleartext', v_bad));
    IF v_bad > 0 THEN v_gate_fails := v_gate_fails + 1; END IF;

    UPDATE control.pipeline_run_log
    SET ended_at = now(),
        status = CASE WHEN v_gate_fails = 0 THEN 'SUCCESS' ELSE 'FAILED' END,
        notes = format('gate_fail_count=%s', v_gate_fails)
    WHERE run_id = v_run_id;

    p_run_id := v_run_id;
    p_gate_fail_count := v_gate_fails;
    COMMIT;
END;
$$;

CALL control.sp_postdq_run(NULL, NULL);
