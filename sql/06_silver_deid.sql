-- 06_silver_deid.sql
-- Silver DDL + per-table de-identification procedures + the sweep
-- orchestrator control.sp_deid_run(salt).
--
-- Techniques applied (see control.deid_audit for the technique enum):
--   DATE_SHIFT  every date/timestamp column, via the crosswalk's per-patient
--               ±[1,365]-day offset. NULL source dates propagate to NULL
--               automatically (date/timestamptz arithmetic with NULL is NULL)
--               so no special-casing is needed for optional stop/deathdate.
--   HASH        direct identifiers (SSN/DRIVERS/PASSPORT/NAME fields, device
--               UDI) -> encode(digest(value || salt, 'sha256'), 'hex'),
--               stored in *_token columns; cleartext is written once to the
--               reversible control.token_vault, then dropped from silver.
--   GENERALIZE  zip -> 3-digit prefix (zip3); county/FIPS/lat/lon/address/
--               birthplace are dropped entirely from silver.patients (finer
--               geography than state, beyond the plan's explicit zip/county
--               callout but consistent with the same Safe-Harbor intent).
--   BUCKET      age >= 90 (computed from the *original* birthdate/deathdate,
--               before shifting) collapses birthdate to NULL + age_bucket='90+'.
--   SUPPRESS    small-cell suppression on patients.city: cities with fewer
--               than 5 patients are nulled out (threshold chosen for this
--               113-patient sample; also used for the fully-dropped geo
--               columns, logged as one row per column since every row loses
--               that column).
--
-- patient_id becomes each table's crosswalk surrogate_id (UUID). encounter_id
-- and the encounters organization/provider/payer ids are carried through
-- unchanged (cast to UUID) -- they're opaque references, not patient
-- identifiers, and organizations/providers/payers are out of scope.

-- ---------------------------------------------------------------------
-- Silver DDL
-- ---------------------------------------------------------------------

DROP TABLE IF EXISTS silver.patients;
CREATE TABLE silver.patients (
    patient_id             UUID PRIMARY KEY,
    birthdate               DATE,
    deathdate               DATE,
    age_bucket               TEXT,
    ssn_token                TEXT,
    drivers_token            TEXT,
    passport_token           TEXT,
    prefix                   TEXT,
    first_token              TEXT,
    middle_token             TEXT,
    last_token                TEXT,
    suffix                   TEXT,
    maiden_token              TEXT,
    marital                 TEXT,
    race                     TEXT,
    ethnicity                TEXT,
    gender                   TEXT,
    city                     TEXT,
    state                    TEXT,
    zip3                     TEXT,
    healthcare_expenses      NUMERIC,
    healthcare_coverage      NUMERIC,
    income                   NUMERIC
);

DROP TABLE IF EXISTS silver.encounters;
CREATE TABLE silver.encounters (
    encounter_id             UUID PRIMARY KEY,
    patient_id               UUID NOT NULL,
    organization_id           UUID,
    provider_id               UUID,
    payer_id                  UUID,
    start                    TIMESTAMPTZ,
    stop                     TIMESTAMPTZ,
    encounterclass            TEXT,
    code                     TEXT,
    description               TEXT,
    base_encounter_cost       NUMERIC,
    total_claim_cost          NUMERIC,
    payer_coverage            NUMERIC,
    reasoncode                TEXT,
    reasondescription         TEXT
);

DROP TABLE IF EXISTS silver.conditions;
CREATE TABLE silver.conditions (
    patient_id                UUID NOT NULL,
    encounter_id              UUID,
    start                    DATE,
    stop                     DATE,
    system                   TEXT,
    code                     TEXT,
    description               TEXT
);

DROP TABLE IF EXISTS silver.medications;
CREATE TABLE silver.medications (
    patient_id                UUID NOT NULL,
    payer_id                  UUID,
    encounter_id              UUID,
    start                    TIMESTAMPTZ,
    stop                     TIMESTAMPTZ,
    code                     TEXT,
    description               TEXT,
    base_cost                 NUMERIC,
    payer_coverage            NUMERIC,
    dispenses                 INT,
    totalcost                  NUMERIC,
    reasoncode                TEXT,
    reasondescription         TEXT
);

DROP TABLE IF EXISTS silver.procedures;
CREATE TABLE silver.procedures (
    patient_id                UUID NOT NULL,
    encounter_id              UUID,
    start                    TIMESTAMPTZ,
    stop                     TIMESTAMPTZ,
    system                   TEXT,
    code                     TEXT,
    description               TEXT,
    base_cost                 NUMERIC,
    reasoncode                TEXT,
    reasondescription         TEXT
);

DROP TABLE IF EXISTS silver.observations;
CREATE TABLE silver.observations (
    patient_id                UUID NOT NULL,
    encounter_id              UUID,
    date                     TIMESTAMPTZ,
    category                 TEXT,
    code                     TEXT,
    description               TEXT,
    value                    TEXT,
    units                    TEXT,
    type                     TEXT
);

DROP TABLE IF EXISTS silver.immunizations;
CREATE TABLE silver.immunizations (
    patient_id                UUID NOT NULL,
    encounter_id              UUID,
    date                     TIMESTAMPTZ,
    code                     TEXT,
    description               TEXT,
    base_cost                 NUMERIC
);

DROP TABLE IF EXISTS silver.allergies;
CREATE TABLE silver.allergies (
    patient_id                UUID NOT NULL,
    encounter_id              UUID,
    start                    DATE,
    stop                     DATE,
    code                     TEXT,
    system                   TEXT,
    description               TEXT,
    type                     TEXT,
    category                 TEXT,
    reaction1                 TEXT,
    description1              TEXT,
    severity1                 TEXT,
    reaction2                 TEXT,
    description2              TEXT,
    severity2                 TEXT
);

DROP TABLE IF EXISTS silver.careplans;
CREATE TABLE silver.careplans (
    careplan_id               UUID PRIMARY KEY,
    patient_id                UUID NOT NULL,
    encounter_id              UUID,
    start                    DATE,
    stop                     DATE,
    code                     TEXT,
    description               TEXT,
    reasoncode                TEXT,
    reasondescription         TEXT
);

DROP TABLE IF EXISTS silver.devices;
CREATE TABLE silver.devices (
    patient_id                UUID NOT NULL,
    encounter_id              UUID,
    start                    TIMESTAMPTZ,
    stop                     TIMESTAMPTZ,
    code                     TEXT,
    description               TEXT,
    udi_token                  TEXT
);

DROP TABLE IF EXISTS silver.imaging_studies;
CREATE TABLE silver.imaging_studies (
    instance_uid              TEXT PRIMARY KEY,
    study_id                  UUID,
    patient_id                UUID NOT NULL,
    encounter_id              UUID,
    date                     TIMESTAMPTZ,
    series_uid                 TEXT,
    bodysite_code              TEXT,
    bodysite_description       TEXT,
    modality_code              TEXT,
    modality_description       TEXT,
    sop_code                   TEXT,
    sop_description            TEXT,
    procedure_code             TEXT
);

DROP TABLE IF EXISTS silver.supplies;
CREATE TABLE silver.supplies (
    patient_id                UUID NOT NULL,
    encounter_id              UUID,
    date                     DATE,
    code                     TEXT,
    description               TEXT,
    quantity                   INT
);

-- ---------------------------------------------------------------------
-- Per-table de-id procedures
-- ---------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE silver.sp_deid_patients(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    INSERT INTO control.token_vault (token_hash, identifier_type, original_value, salt)
    SELECT DISTINCT encode(digest(v || p_salt, 'sha256'), 'hex'), 'SSN', v, p_salt
    FROM (SELECT NULLIF(ssn, '') AS v FROM bronze.patients) s WHERE v IS NOT NULL
    ON CONFLICT (token_hash) DO NOTHING;

    INSERT INTO control.token_vault (token_hash, identifier_type, original_value, salt)
    SELECT DISTINCT encode(digest(v || p_salt, 'sha256'), 'hex'), 'DRIVERS', v, p_salt
    FROM (SELECT NULLIF(drivers, '') AS v FROM bronze.patients) s WHERE v IS NOT NULL
    ON CONFLICT (token_hash) DO NOTHING;

    INSERT INTO control.token_vault (token_hash, identifier_type, original_value, salt)
    SELECT DISTINCT encode(digest(v || p_salt, 'sha256'), 'hex'), 'PASSPORT', v, p_salt
    FROM (SELECT NULLIF(passport, '') AS v FROM bronze.patients) s WHERE v IS NOT NULL
    ON CONFLICT (token_hash) DO NOTHING;

    INSERT INTO control.token_vault (token_hash, identifier_type, original_value, salt)
    SELECT DISTINCT encode(digest(v || p_salt, 'sha256'), 'hex'), 'NAME', v, p_salt
    FROM (
        SELECT NULLIF(first, '') AS v FROM bronze.patients
        UNION SELECT NULLIF(middle, '') FROM bronze.patients
        UNION SELECT NULLIF(last, '') FROM bronze.patients
        UNION SELECT NULLIF(maiden, '') FROM bronze.patients
    ) s WHERE v IS NOT NULL
    ON CONFLICT (token_hash) DO NOTHING;

    TRUNCATE TABLE silver.patients;

    INSERT INTO silver.patients (
        patient_id, birthdate, deathdate, age_bucket,
        ssn_token, drivers_token, passport_token,
        prefix, first_token, middle_token, last_token, suffix, maiden_token,
        marital, race, ethnicity, gender,
        city, state, zip3,
        healthcare_expenses, healthcare_coverage, income
    )
    SELECT
        cw.surrogate_id,
        CASE WHEN age90.is_90_plus THEN NULL ELSE (b.birthdate::date + cw.date_offset_days) END,
        (NULLIF(b.deathdate, '')::date + cw.date_offset_days),
        CASE WHEN age90.is_90_plus THEN '90+' ELSE NULL END,
        CASE WHEN NULLIF(b.ssn, '') IS NULL THEN NULL ELSE encode(digest(b.ssn || p_salt, 'sha256'), 'hex') END,
        CASE WHEN NULLIF(b.drivers, '') IS NULL THEN NULL ELSE encode(digest(b.drivers || p_salt, 'sha256'), 'hex') END,
        CASE WHEN NULLIF(b.passport, '') IS NULL THEN NULL ELSE encode(digest(b.passport || p_salt, 'sha256'), 'hex') END,
        NULLIF(b.prefix, ''),
        CASE WHEN NULLIF(b.first, '') IS NULL THEN NULL ELSE encode(digest(b.first || p_salt, 'sha256'), 'hex') END,
        CASE WHEN NULLIF(b.middle, '') IS NULL THEN NULL ELSE encode(digest(b.middle || p_salt, 'sha256'), 'hex') END,
        CASE WHEN NULLIF(b.last, '') IS NULL THEN NULL ELSE encode(digest(b.last || p_salt, 'sha256'), 'hex') END,
        NULLIF(b.suffix, ''),
        CASE WHEN NULLIF(b.maiden, '') IS NULL THEN NULL ELSE encode(digest(b.maiden || p_salt, 'sha256'), 'hex') END,
        NULLIF(b.marital, ''),
        NULLIF(b.race, ''),
        NULLIF(b.ethnicity, ''),
        NULLIF(b.gender, ''),
        CASE WHEN cc.n < 5 THEN NULL ELSE NULLIF(b.city, '') END,
        NULLIF(b.state, ''),
        left(NULLIF(b.zip, ''), 3),
        NULLIF(b.healthcare_expenses, '')::numeric,
        NULLIF(b.healthcare_coverage, '')::numeric,
        NULLIF(b.income, '')::numeric
    FROM bronze.patients b
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = b.id::uuid
    LEFT JOIN LATERAL (
        SELECT extract(year FROM age(COALESCE(NULLIF(b.deathdate, '')::date, CURRENT_DATE), b.birthdate::date)) >= 90 AS is_90_plus
    ) age90 ON true
    LEFT JOIN (
        SELECT NULLIF(city, '') AS city, count(*) AS n FROM bronze.patients GROUP BY NULLIF(city, '')
    ) cc ON cc.city = NULLIF(b.city, '');

    GET DIAGNOSTICS v_n = ROW_COUNT;

    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES
        (p_run_id, 'patients', 'birthdate', 'DATE_SHIFT', (SELECT count(*) FROM silver.patients WHERE birthdate IS NOT NULL)),
        (p_run_id, 'patients', 'deathdate', 'DATE_SHIFT', (SELECT count(*) FROM silver.patients WHERE deathdate IS NOT NULL)),
        (p_run_id, 'patients', 'ssn', 'HASH', (SELECT count(*) FROM silver.patients WHERE ssn_token IS NOT NULL)),
        (p_run_id, 'patients', 'drivers', 'HASH', (SELECT count(*) FROM silver.patients WHERE drivers_token IS NOT NULL)),
        (p_run_id, 'patients', 'passport', 'HASH', (SELECT count(*) FROM silver.patients WHERE passport_token IS NOT NULL)),
        (p_run_id, 'patients', 'first', 'HASH', (SELECT count(*) FROM silver.patients WHERE first_token IS NOT NULL)),
        (p_run_id, 'patients', 'middle', 'HASH', (SELECT count(*) FROM silver.patients WHERE middle_token IS NOT NULL)),
        (p_run_id, 'patients', 'last', 'HASH', (SELECT count(*) FROM silver.patients WHERE last_token IS NOT NULL)),
        (p_run_id, 'patients', 'maiden', 'HASH', (SELECT count(*) FROM silver.patients WHERE maiden_token IS NOT NULL)),
        (p_run_id, 'patients', 'zip', 'GENERALIZE', v_n),
        (p_run_id, 'patients', 'age', 'BUCKET', (SELECT count(*) FROM silver.patients WHERE age_bucket = '90+')),
        (p_run_id, 'patients', 'city', 'SUPPRESS', (
            SELECT count(*) FROM bronze.patients b2
            JOIN (SELECT NULLIF(city, '') AS c, count(*) AS n FROM bronze.patients GROUP BY NULLIF(city, '')) cc2
              ON cc2.c = NULLIF(b2.city, '')
            WHERE NULLIF(b2.city, '') IS NOT NULL AND cc2.n < 5
        )),
        (p_run_id, 'patients', 'address', 'SUPPRESS', v_n),
        (p_run_id, 'patients', 'county', 'SUPPRESS', v_n),
        (p_run_id, 'patients', 'fips', 'SUPPRESS', v_n),
        (p_run_id, 'patients', 'lat', 'SUPPRESS', v_n),
        (p_run_id, 'patients', 'lon', 'SUPPRESS', v_n),
        (p_run_id, 'patients', 'birthplace', 'SUPPRESS', v_n);
END;
$$;

CREATE OR REPLACE PROCEDURE silver.sp_deid_encounters(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    TRUNCATE TABLE silver.encounters;
    INSERT INTO silver.encounters (
        encounter_id, patient_id, organization_id, provider_id, payer_id,
        start, stop, encounterclass, code, description,
        base_encounter_cost, total_claim_cost, payer_coverage, reasoncode, reasondescription
    )
    SELECT
        e.id::uuid, cw.surrogate_id,
        NULLIF(e.organization_id, '')::uuid, NULLIF(e.provider_id, '')::uuid, NULLIF(e.payer_id, '')::uuid,
        (e.start::timestamptz + make_interval(days => cw.date_offset_days)),
        (NULLIF(e.stop, '')::timestamptz + make_interval(days => cw.date_offset_days)),
        NULLIF(e.encounterclass, ''), NULLIF(e.code, ''), NULLIF(e.description, ''),
        NULLIF(e.base_encounter_cost, '')::numeric, NULLIF(e.total_claim_cost, '')::numeric, NULLIF(e.payer_coverage, '')::numeric,
        NULLIF(e.reasoncode, ''), NULLIF(e.reasondescription, '')
    FROM bronze.encounters e
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = e.patient_id::uuid;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES (p_run_id, 'encounters', 'start', 'DATE_SHIFT', v_n),
           (p_run_id, 'encounters', 'stop', 'DATE_SHIFT', (SELECT count(*) FROM silver.encounters WHERE stop IS NOT NULL));
END;
$$;

CREATE OR REPLACE PROCEDURE silver.sp_deid_conditions(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    TRUNCATE TABLE silver.conditions;
    INSERT INTO silver.conditions (patient_id, encounter_id, start, stop, system, code, description)
    SELECT cw.surrogate_id, NULLIF(c.encounter_id, '')::uuid,
           (c.start::date + cw.date_offset_days),
           (NULLIF(c.stop, '')::date + cw.date_offset_days),
           NULLIF(c.system, ''), NULLIF(c.code, ''), NULLIF(c.description, '')
    FROM bronze.conditions c
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = c.patient_id::uuid;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES (p_run_id, 'conditions', 'start', 'DATE_SHIFT', v_n),
           (p_run_id, 'conditions', 'stop', 'DATE_SHIFT', (SELECT count(*) FROM silver.conditions WHERE stop IS NOT NULL));
END;
$$;

CREATE OR REPLACE PROCEDURE silver.sp_deid_medications(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    TRUNCATE TABLE silver.medications;
    INSERT INTO silver.medications (
        patient_id, payer_id, encounter_id, start, stop, code, description,
        base_cost, payer_coverage, dispenses, totalcost, reasoncode, reasondescription
    )
    SELECT cw.surrogate_id, NULLIF(m.payer_id, '')::uuid, NULLIF(m.encounter_id, '')::uuid,
           (m.start::timestamptz + make_interval(days => cw.date_offset_days)),
           (NULLIF(m.stop, '')::timestamptz + make_interval(days => cw.date_offset_days)),
           NULLIF(m.code, ''), NULLIF(m.description, ''),
           NULLIF(m.base_cost, '')::numeric, NULLIF(m.payer_coverage, '')::numeric,
           NULLIF(m.dispenses, '')::int, NULLIF(m.totalcost, '')::numeric,
           NULLIF(m.reasoncode, ''), NULLIF(m.reasondescription, '')
    FROM bronze.medications m
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = m.patient_id::uuid;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES (p_run_id, 'medications', 'start', 'DATE_SHIFT', v_n),
           (p_run_id, 'medications', 'stop', 'DATE_SHIFT', (SELECT count(*) FROM silver.medications WHERE stop IS NOT NULL));
END;
$$;

CREATE OR REPLACE PROCEDURE silver.sp_deid_procedures(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    TRUNCATE TABLE silver.procedures;
    INSERT INTO silver.procedures (
        patient_id, encounter_id, start, stop, system, code, description,
        base_cost, reasoncode, reasondescription
    )
    SELECT cw.surrogate_id, NULLIF(p.encounter_id, '')::uuid,
           (p.start::timestamptz + make_interval(days => cw.date_offset_days)),
           (NULLIF(p.stop, '')::timestamptz + make_interval(days => cw.date_offset_days)),
           NULLIF(p.system, ''), NULLIF(p.code, ''), NULLIF(p.description, ''),
           NULLIF(p.base_cost, '')::numeric, NULLIF(p.reasoncode, ''), NULLIF(p.reasondescription, '')
    FROM bronze.procedures p
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = p.patient_id::uuid;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES (p_run_id, 'procedures', 'start', 'DATE_SHIFT', v_n),
           (p_run_id, 'procedures', 'stop', 'DATE_SHIFT', (SELECT count(*) FROM silver.procedures WHERE stop IS NOT NULL));
END;
$$;

CREATE OR REPLACE PROCEDURE silver.sp_deid_observations(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    TRUNCATE TABLE silver.observations;
    INSERT INTO silver.observations (patient_id, encounter_id, date, category, code, description, value, units, type)
    SELECT cw.surrogate_id, NULLIF(o.encounter_id, '')::uuid,
           (o.date::timestamptz + make_interval(days => cw.date_offset_days)),
           NULLIF(o.category, ''), NULLIF(o.code, ''), NULLIF(o.description, ''),
           NULLIF(o.value, ''), NULLIF(o.units, ''), NULLIF(o.type, '')
    FROM bronze.observations o
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = o.patient_id::uuid;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES (p_run_id, 'observations', 'date', 'DATE_SHIFT', v_n);
END;
$$;

CREATE OR REPLACE PROCEDURE silver.sp_deid_immunizations(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    TRUNCATE TABLE silver.immunizations;
    INSERT INTO silver.immunizations (patient_id, encounter_id, date, code, description, base_cost)
    SELECT cw.surrogate_id, NULLIF(i.encounter_id, '')::uuid,
           (i.date::timestamptz + make_interval(days => cw.date_offset_days)),
           NULLIF(i.code, ''), NULLIF(i.description, ''), NULLIF(i.base_cost, '')::numeric
    FROM bronze.immunizations i
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = i.patient_id::uuid;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES (p_run_id, 'immunizations', 'date', 'DATE_SHIFT', v_n);
END;
$$;

CREATE OR REPLACE PROCEDURE silver.sp_deid_allergies(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    TRUNCATE TABLE silver.allergies;
    INSERT INTO silver.allergies (
        patient_id, encounter_id, start, stop, code, system, description, type, category,
        reaction1, description1, severity1, reaction2, description2, severity2
    )
    SELECT cw.surrogate_id, NULLIF(a.encounter_id, '')::uuid,
           (a.start::date + cw.date_offset_days),
           (NULLIF(a.stop, '')::date + cw.date_offset_days),
           NULLIF(a.code, ''), NULLIF(a.system, ''), NULLIF(a.description, ''), NULLIF(a.type, ''), NULLIF(a.category, ''),
           NULLIF(a.reaction1, ''), NULLIF(a.description1, ''), NULLIF(a.severity1, ''),
           NULLIF(a.reaction2, ''), NULLIF(a.description2, ''), NULLIF(a.severity2, '')
    FROM bronze.allergies a
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = a.patient_id::uuid;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES (p_run_id, 'allergies', 'start', 'DATE_SHIFT', v_n),
           (p_run_id, 'allergies', 'stop', 'DATE_SHIFT', (SELECT count(*) FROM silver.allergies WHERE stop IS NOT NULL));
END;
$$;

CREATE OR REPLACE PROCEDURE silver.sp_deid_careplans(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    TRUNCATE TABLE silver.careplans;
    INSERT INTO silver.careplans (careplan_id, patient_id, encounter_id, start, stop, code, description, reasoncode, reasondescription)
    SELECT cp.id::uuid, cw.surrogate_id, NULLIF(cp.encounter_id, '')::uuid,
           (cp.start::date + cw.date_offset_days),
           (NULLIF(cp.stop, '')::date + cw.date_offset_days),
           NULLIF(cp.code, ''), NULLIF(cp.description, ''), NULLIF(cp.reasoncode, ''), NULLIF(cp.reasondescription, '')
    FROM bronze.careplans cp
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = cp.patient_id::uuid;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES (p_run_id, 'careplans', 'start', 'DATE_SHIFT', v_n),
           (p_run_id, 'careplans', 'stop', 'DATE_SHIFT', (SELECT count(*) FROM silver.careplans WHERE stop IS NOT NULL));
END;
$$;

CREATE OR REPLACE PROCEDURE silver.sp_deid_devices(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    INSERT INTO control.token_vault (token_hash, identifier_type, original_value, salt)
    SELECT DISTINCT encode(digest(v || p_salt, 'sha256'), 'hex'), 'UDI', v, p_salt
    FROM (SELECT NULLIF(udi, '') AS v FROM bronze.devices) s WHERE v IS NOT NULL
    ON CONFLICT (token_hash) DO NOTHING;

    TRUNCATE TABLE silver.devices;
    INSERT INTO silver.devices (patient_id, encounter_id, start, stop, code, description, udi_token)
    SELECT cw.surrogate_id, NULLIF(d.encounter_id, '')::uuid,
           (d.start::timestamptz + make_interval(days => cw.date_offset_days)),
           (NULLIF(d.stop, '')::timestamptz + make_interval(days => cw.date_offset_days)),
           NULLIF(d.code, ''), NULLIF(d.description, ''),
           CASE WHEN NULLIF(d.udi, '') IS NULL THEN NULL ELSE encode(digest(d.udi || p_salt, 'sha256'), 'hex') END
    FROM bronze.devices d
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = d.patient_id::uuid;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES (p_run_id, 'devices', 'start', 'DATE_SHIFT', v_n),
           (p_run_id, 'devices', 'stop', 'DATE_SHIFT', (SELECT count(*) FROM silver.devices WHERE stop IS NOT NULL)),
           (p_run_id, 'devices', 'udi', 'HASH', (SELECT count(*) FROM silver.devices WHERE udi_token IS NOT NULL));
END;
$$;

CREATE OR REPLACE PROCEDURE silver.sp_deid_imaging_studies(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    TRUNCATE TABLE silver.imaging_studies;
    INSERT INTO silver.imaging_studies (
        instance_uid, study_id, patient_id, encounter_id, date,
        series_uid, bodysite_code, bodysite_description, modality_code, modality_description,
        sop_code, sop_description, procedure_code
    )
    SELECT im.instance_uid, im.id::uuid, cw.surrogate_id, NULLIF(im.encounter_id, '')::uuid,
           (im.date::timestamptz + make_interval(days => cw.date_offset_days)),
           NULLIF(im.series_uid, ''), NULLIF(im.bodysite_code, ''), NULLIF(im.bodysite_description, ''),
           NULLIF(im.modality_code, ''), NULLIF(im.modality_description, ''),
           NULLIF(im.sop_code, ''), NULLIF(im.sop_description, ''), NULLIF(im.procedure_code, '')
    FROM bronze.imaging_studies im
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = im.patient_id::uuid;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES (p_run_id, 'imaging_studies', 'date', 'DATE_SHIFT', v_n);
END;
$$;

CREATE OR REPLACE PROCEDURE silver.sp_deid_supplies(IN p_run_id BIGINT, IN p_salt TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n BIGINT;
BEGIN
    TRUNCATE TABLE silver.supplies;
    INSERT INTO silver.supplies (patient_id, encounter_id, date, code, description, quantity)
    SELECT cw.surrogate_id, NULLIF(s.encounter_id, '')::uuid,
           (s.date::date + cw.date_offset_days),
           NULLIF(s.code, ''), NULLIF(s.description, ''), NULLIF(s.quantity, '')::int
    FROM bronze.supplies s
    JOIN control.patient_crosswalk cw ON cw.original_patient_id = s.patient_id::uuid;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO control.deid_audit (run_id, table_name, column_name, technique, rows_transformed)
    VALUES (p_run_id, 'supplies', 'date', 'DATE_SHIFT', v_n);
END;
$$;

-- ---------------------------------------------------------------------
-- Sweep orchestrator
-- ---------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE control.sp_deid_run(IN p_salt TEXT, OUT p_run_id BIGINT, OUT p_rows_affected BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id BIGINT;
    v_total  BIGINT;
BEGIN
    INSERT INTO control.pipeline_run_log (run_type, status)
    VALUES ('DEID', 'RUNNING')
    RETURNING run_id INTO v_run_id;

    CALL silver.sp_deid_patients(v_run_id, p_salt);
    CALL silver.sp_deid_encounters(v_run_id, p_salt);
    CALL silver.sp_deid_conditions(v_run_id, p_salt);
    CALL silver.sp_deid_medications(v_run_id, p_salt);
    CALL silver.sp_deid_procedures(v_run_id, p_salt);
    CALL silver.sp_deid_observations(v_run_id, p_salt);
    CALL silver.sp_deid_immunizations(v_run_id, p_salt);
    CALL silver.sp_deid_allergies(v_run_id, p_salt);
    CALL silver.sp_deid_careplans(v_run_id, p_salt);
    CALL silver.sp_deid_devices(v_run_id, p_salt);
    CALL silver.sp_deid_imaging_studies(v_run_id, p_salt);
    CALL silver.sp_deid_supplies(v_run_id, p_salt);

    SELECT (SELECT count(*) FROM silver.patients) + (SELECT count(*) FROM silver.encounters)
         + (SELECT count(*) FROM silver.conditions) + (SELECT count(*) FROM silver.medications)
         + (SELECT count(*) FROM silver.procedures) + (SELECT count(*) FROM silver.observations)
         + (SELECT count(*) FROM silver.immunizations) + (SELECT count(*) FROM silver.allergies)
         + (SELECT count(*) FROM silver.careplans) + (SELECT count(*) FROM silver.devices)
         + (SELECT count(*) FROM silver.imaging_studies) + (SELECT count(*) FROM silver.supplies)
    INTO v_total;

    UPDATE control.pipeline_run_log
    SET ended_at = now(), status = 'SUCCESS', rows_affected = v_total, notes = 'silver deid sweep'
    WHERE run_id = v_run_id;

    p_run_id := v_run_id;
    p_rows_affected := v_total;
    COMMIT;
END;
$$;

-- Fixed dev/test salt for local verification. sp_pipeline_run_all(salt) takes
-- the real salt as a runtime argument (see CLAUDE.md); this is not a secret.
CALL control.sp_deid_run('dev-salt-2026', NULL, NULL);
