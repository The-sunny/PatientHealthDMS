-- 01_bronze_ddl.sql
-- Raw landing tables, one per source CSV, columns 1:1 with headers (all TEXT,
-- no parsing/casting on load). Source PATIENT/ORGANIZATION/PROVIDER/PAYER/
-- ENCOUNTER id-reference columns are suffixed _id for clarity; every other
-- column keeps its source name, lowercased. No PK/FK here — bronze is a raw
-- landing zone, duplicates and nulls are expected and caught by pre-DQ.

DROP TABLE IF EXISTS bronze.patients;
CREATE TABLE bronze.patients (
    id                     TEXT,
    birthdate              TEXT,
    deathdate              TEXT,
    ssn                    TEXT,
    drivers                TEXT,
    passport               TEXT,
    prefix                 TEXT,
    first                  TEXT,
    middle                 TEXT,
    last                   TEXT,
    suffix                 TEXT,
    maiden                 TEXT,
    marital                TEXT,
    race                   TEXT,
    ethnicity              TEXT,
    gender                 TEXT,
    birthplace             TEXT,
    address                TEXT,
    city                   TEXT,
    state                  TEXT,
    county                 TEXT,
    fips                   TEXT,
    zip                    TEXT,
    lat                    TEXT,
    lon                    TEXT,
    healthcare_expenses    TEXT,
    healthcare_coverage    TEXT,
    income                 TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);

DROP TABLE IF EXISTS bronze.encounters;
CREATE TABLE bronze.encounters (
    id                     TEXT,
    start                  TEXT,
    stop                   TEXT,
    patient_id             TEXT,
    organization_id        TEXT,
    provider_id            TEXT,
    payer_id               TEXT,
    encounterclass         TEXT,
    code                   TEXT,
    description            TEXT,
    base_encounter_cost    TEXT,
    total_claim_cost       TEXT,
    payer_coverage         TEXT,
    reasoncode             TEXT,
    reasondescription      TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);

DROP TABLE IF EXISTS bronze.conditions;
CREATE TABLE bronze.conditions (
    start                  TEXT,
    stop                   TEXT,
    patient_id             TEXT,
    encounter_id           TEXT,
    system                 TEXT,
    code                   TEXT,
    description            TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);

DROP TABLE IF EXISTS bronze.medications;
CREATE TABLE bronze.medications (
    start                  TEXT,
    stop                   TEXT,
    patient_id             TEXT,
    payer_id               TEXT,
    encounter_id           TEXT,
    code                   TEXT,
    description            TEXT,
    base_cost              TEXT,
    payer_coverage         TEXT,
    dispenses              TEXT,
    totalcost              TEXT,
    reasoncode             TEXT,
    reasondescription      TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);

DROP TABLE IF EXISTS bronze.procedures;
CREATE TABLE bronze.procedures (
    start                  TEXT,
    stop                   TEXT,
    patient_id             TEXT,
    encounter_id           TEXT,
    system                 TEXT,
    code                   TEXT,
    description            TEXT,
    base_cost              TEXT,
    reasoncode             TEXT,
    reasondescription      TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);

DROP TABLE IF EXISTS bronze.observations;
CREATE TABLE bronze.observations (
    date                   TEXT,
    patient_id             TEXT,
    encounter_id           TEXT,
    category               TEXT,
    code                   TEXT,
    description            TEXT,
    value                  TEXT,
    units                  TEXT,
    type                   TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);

DROP TABLE IF EXISTS bronze.immunizations;
CREATE TABLE bronze.immunizations (
    date                   TEXT,
    patient_id             TEXT,
    encounter_id           TEXT,
    code                   TEXT,
    description            TEXT,
    base_cost              TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);

DROP TABLE IF EXISTS bronze.allergies;
CREATE TABLE bronze.allergies (
    start                  TEXT,
    stop                   TEXT,
    patient_id             TEXT,
    encounter_id           TEXT,
    code                   TEXT,
    system                 TEXT,
    description            TEXT,
    type                   TEXT,
    category               TEXT,
    reaction1              TEXT,
    description1           TEXT,
    severity1              TEXT,
    reaction2              TEXT,
    description2           TEXT,
    severity2              TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);

DROP TABLE IF EXISTS bronze.careplans;
CREATE TABLE bronze.careplans (
    id                     TEXT,
    start                  TEXT,
    stop                   TEXT,
    patient_id             TEXT,
    encounter_id           TEXT,
    code                   TEXT,
    description            TEXT,
    reasoncode             TEXT,
    reasondescription      TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);

DROP TABLE IF EXISTS bronze.devices;
CREATE TABLE bronze.devices (
    start                  TEXT,
    stop                   TEXT,
    patient_id             TEXT,
    encounter_id           TEXT,
    code                   TEXT,
    description            TEXT,
    udi                    TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);

DROP TABLE IF EXISTS bronze.imaging_studies;
CREATE TABLE bronze.imaging_studies (
    id                     TEXT,
    date                   TEXT,
    patient_id             TEXT,
    encounter_id           TEXT,
    series_uid             TEXT,
    bodysite_code          TEXT,
    bodysite_description   TEXT,
    modality_code          TEXT,
    modality_description   TEXT,
    instance_uid           TEXT,
    sop_code               TEXT,
    sop_description        TEXT,
    procedure_code         TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);

DROP TABLE IF EXISTS bronze.supplies;
CREATE TABLE bronze.supplies (
    date                   TEXT,
    patient_id             TEXT,
    encounter_id           TEXT,
    code                   TEXT,
    description            TEXT,
    quantity               TEXT,
    load_batch_id          BIGINT,
    loaded_at              TIMESTAMPTZ
);
