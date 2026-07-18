-- 03_load_bronze.sql
-- Loads the 12 in-scope Synthea CSVs into bronze via \copy (client-side,
-- cannot run inside a procedure), then calls sp_bronze_load_batch() to stamp
-- load_batch_id/loaded_at on the freshly-loaded rows and log the run.
-- __CSV_DIR__ is substituted by run.sh at execution time.

CREATE OR REPLACE PROCEDURE control.sp_bronze_load_batch()
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id   BIGINT;
    v_batch_id BIGINT;
    v_rows     BIGINT := 0;
    v_n        BIGINT;
    v_table    TEXT;
    v_tables   TEXT[] := ARRAY['patients','encounters','conditions','medications',
                                'procedures','observations','immunizations','allergies',
                                'careplans','devices','imaging_studies','supplies'];
BEGIN
    INSERT INTO control.pipeline_run_log (run_type, status)
    VALUES ('LOAD', 'RUNNING')
    RETURNING run_id INTO v_run_id;

    -- run_id doubles as the load_batch_id: unique, sequential, no extra
    -- generator needed.
    v_batch_id := v_run_id;

    FOREACH v_table IN ARRAY v_tables LOOP
        EXECUTE format(
            'UPDATE bronze.%I SET load_batch_id = $1, loaded_at = now() WHERE load_batch_id IS NULL',
            v_table
        ) USING v_batch_id;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_rows := v_rows + v_n;
    END LOOP;

    UPDATE control.pipeline_run_log
    SET ended_at = now(),
        status = 'SUCCESS',
        rows_affected = v_rows,
        notes = format('batch_id=%s', v_batch_id)
    WHERE run_id = v_run_id;

    COMMIT;
END;
$$;

-- Truncate before reload so re-running the pipeline doesn't accumulate
-- duplicate loads across runs (bronze still tolerates duplicates *within*
-- a single CSV, which pre-DQ checks for).
TRUNCATE TABLE
    bronze.patients, bronze.encounters, bronze.conditions, bronze.medications,
    bronze.procedures, bronze.observations, bronze.immunizations, bronze.allergies,
    bronze.careplans, bronze.devices, bronze.imaging_studies, bronze.supplies;

\copy bronze.patients (id,birthdate,deathdate,ssn,drivers,passport,prefix,first,middle,last,suffix,maiden,marital,race,ethnicity,gender,birthplace,address,city,state,county,fips,zip,lat,lon,healthcare_expenses,healthcare_coverage,income) FROM '__CSV_DIR__/patients.csv' WITH (FORMAT csv, HEADER true)

\copy bronze.encounters (id,start,stop,patient_id,organization_id,provider_id,payer_id,encounterclass,code,description,base_encounter_cost,total_claim_cost,payer_coverage,reasoncode,reasondescription) FROM '__CSV_DIR__/encounters.csv' WITH (FORMAT csv, HEADER true)

\copy bronze.conditions (start,stop,patient_id,encounter_id,system,code,description) FROM '__CSV_DIR__/conditions.csv' WITH (FORMAT csv, HEADER true)

\copy bronze.medications (start,stop,patient_id,payer_id,encounter_id,code,description,base_cost,payer_coverage,dispenses,totalcost,reasoncode,reasondescription) FROM '__CSV_DIR__/medications.csv' WITH (FORMAT csv, HEADER true)

\copy bronze.procedures (start,stop,patient_id,encounter_id,system,code,description,base_cost,reasoncode,reasondescription) FROM '__CSV_DIR__/procedures.csv' WITH (FORMAT csv, HEADER true)

\copy bronze.observations (date,patient_id,encounter_id,category,code,description,value,units,type) FROM '__CSV_DIR__/observations.csv' WITH (FORMAT csv, HEADER true)

\copy bronze.immunizations (date,patient_id,encounter_id,code,description,base_cost) FROM '__CSV_DIR__/immunizations.csv' WITH (FORMAT csv, HEADER true)

\copy bronze.allergies (start,stop,patient_id,encounter_id,code,system,description,type,category,reaction1,description1,severity1,reaction2,description2,severity2) FROM '__CSV_DIR__/allergies.csv' WITH (FORMAT csv, HEADER true)

\copy bronze.careplans (id,start,stop,patient_id,encounter_id,code,description,reasoncode,reasondescription) FROM '__CSV_DIR__/careplans.csv' WITH (FORMAT csv, HEADER true)

\copy bronze.devices (start,stop,patient_id,encounter_id,code,description,udi) FROM '__CSV_DIR__/devices.csv' WITH (FORMAT csv, HEADER true)

\copy bronze.imaging_studies (id,date,patient_id,encounter_id,series_uid,bodysite_code,bodysite_description,modality_code,modality_description,instance_uid,sop_code,sop_description,procedure_code) FROM '__CSV_DIR__/imaging_studies.csv' WITH (FORMAT csv, HEADER true)

\copy bronze.supplies (date,patient_id,encounter_id,code,description,quantity) FROM '__CSV_DIR__/supplies.csv' WITH (FORMAT csv, HEADER true)

CALL control.sp_bronze_load_batch();
