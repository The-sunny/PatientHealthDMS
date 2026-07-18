-- 02_control_ddl.sql
-- Sensitive control-plane tables: re-linking keys (patient_crosswalk,
-- token_vault) and the audit trail (pipeline_run_log, dq_results,
-- deid_audit). These are the assets that would be access-restricted
-- (dedicated role + REVOKE) in a real deployment.

DROP TABLE IF EXISTS control.patient_crosswalk;
CREATE TABLE control.patient_crosswalk (
    original_patient_id    UUID NOT NULL UNIQUE,
    surrogate_id           UUID NOT NULL DEFAULT gen_random_uuid(),
    date_offset_days       INT NOT NULL,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (original_patient_id)
);

DROP TABLE IF EXISTS control.token_vault;
CREATE TABLE control.token_vault (
    token_hash             TEXT PRIMARY KEY,
    identifier_type        TEXT NOT NULL CHECK (identifier_type IN ('NAME','SSN','DRIVERS','PASSPORT','UDI')),
    original_value         TEXT NOT NULL,
    salt                   TEXT NOT NULL,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TABLE IF EXISTS control.pipeline_run_log;
CREATE TABLE control.pipeline_run_log (
    run_id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_type               TEXT NOT NULL CHECK (run_type IN ('LOAD','PRE_DQ','DEID','POST_DQ','GOLD')),
    started_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at               TIMESTAMPTZ,
    status                 TEXT NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING','SUCCESS','FAILED')),
    rows_affected          BIGINT,
    notes                  TEXT
);

DROP TABLE IF EXISTS control.dq_results;
CREATE TABLE control.dq_results (
    dq_id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id                 BIGINT NOT NULL REFERENCES control.pipeline_run_log(run_id),
    layer                  TEXT NOT NULL CHECK (layer IN ('BRONZE','SILVER')),
    table_name             TEXT NOT NULL,
    check_name             TEXT NOT NULL,
    check_type             TEXT NOT NULL,
    metric_value           NUMERIC,
    threshold              NUMERIC,
    pass_fail              TEXT NOT NULL CHECK (pass_fail IN ('PASS','FAIL')),
    checked_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    detail                 TEXT
);

DROP TABLE IF EXISTS control.deid_audit;
CREATE TABLE control.deid_audit (
    audit_id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id                 BIGINT NOT NULL REFERENCES control.pipeline_run_log(run_id),
    table_name             TEXT NOT NULL,
    column_name            TEXT NOT NULL,
    technique               TEXT NOT NULL CHECK (technique IN ('DATE_SHIFT','HASH','GENERALIZE','SUPPRESS','BUCKET')),
    rows_transformed       BIGINT NOT NULL,
    ran_at                 TIMESTAMPTZ NOT NULL DEFAULT now()
);
