-- ============================================================
-- Medplum/Lakebase PostgreSQL Compatibility Test Suite
-- Run: databricks psql <instance> -- -f scripts/test-lakebase-compat.sql
-- ============================================================

-- TEST 1: UUID generation
SELECT gen_random_uuid() AS uuid_test;

-- TEST 2: UUID primary key
CREATE TABLE _test_uuid (id UUID PRIMARY KEY DEFAULT gen_random_uuid());
INSERT INTO _test_uuid DEFAULT VALUES;
INSERT INTO _test_uuid DEFAULT VALUES;
SELECT * FROM _test_uuid;

-- TEST 3: UUID[] array column (CRITICAL for Medplum)
CREATE TABLE _test_uuid_array (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  compartments UUID[]
);
INSERT INTO _test_uuid_array (compartments)
VALUES (ARRAY[gen_random_uuid(), gen_random_uuid()]::UUID[]);
SELECT * FROM _test_uuid_array;

-- TEST 4: UUID[] array overlap operator (CRITICAL for Medplum search)
INSERT INTO _test_uuid_array (compartments)
VALUES (ARRAY['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID]);
SELECT * FROM _test_uuid_array
WHERE compartments && ARRAY['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11']::UUID[];

-- TEST 5: TEXT[] array column (CRITICAL for Medplum search)
CREATE TABLE _test_text_array (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tokens TEXT[]
);
INSERT INTO _test_text_array (tokens) VALUES (ARRAY['john', 'doe', 'patient']);
SELECT * FROM _test_text_array WHERE tokens && ARRAY['john']::TEXT[];

-- TEST 6: TIMESTAMP WITH TIME ZONE
CREATE TABLE _test_timestamp (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "lastUpdated" TIMESTAMPTZ DEFAULT NOW()
);
INSERT INTO _test_timestamp DEFAULT VALUES;
SELECT * FROM _test_timestamp;

-- TEST 7: REPEATABLE READ isolation level
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT 1 AS isolation_test;
COMMIT;

-- TEST 8: Advisory locks
SELECT pg_try_advisory_lock(12345) AS lock_acquired;
SELECT pg_advisory_unlock(12345) AS lock_released;

-- TEST 9: GIN index on arrays
CREATE INDEX _idx_text_gin ON _test_text_array USING GIN (tokens);
CREATE INDEX _idx_uuid_gin ON _test_uuid_array USING GIN (compartments);

-- TEST 10: Full Medplum-like table structure
CREATE TABLE _test_content (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content TEXT NOT NULL,
  "lastUpdated" TIMESTAMPTZ DEFAULT NOW(),
  compartments UUID[],
  name TEXT[],
  status TEXT
);
INSERT INTO _test_content (content, compartments, name, status) VALUES (
  '{"resourceType":"Patient","name":[{"given":["John"],"family":"Doe"}]}',
  ARRAY[gen_random_uuid()]::UUID[],
  ARRAY['John', 'Doe'],
  'active'
);
SELECT * FROM _test_content WHERE name && ARRAY['John']::TEXT[] AND status = 'active';

-- TEST 11: Multiple tables (Medplum creates 150+ resource tables)
CREATE TABLE _test_Patient (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content TEXT NOT NULL,
  "lastUpdated" TIMESTAMPTZ DEFAULT NOW(),
  compartments UUID[],
  name TEXT[]
);
CREATE TABLE _test_Patient_History (
  "versionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  id UUID NOT NULL,
  content TEXT NOT NULL,
  "lastUpdated" TIMESTAMPTZ DEFAULT NOW()
);

-- TEST 12: Quoted column names (Medplum uses camelCase)
SELECT "lastUpdated", "versionId" FROM _test_Patient_History;

-- CLEANUP
DROP TABLE IF EXISTS _test_uuid, _test_uuid_array, _test_text_array,
  _test_timestamp, _test_content, _test_Patient, _test_Patient_History;
DROP INDEX IF EXISTS _idx_text_gin, _idx_uuid_gin;

SELECT 'ALL TESTS COMPLETED' AS result;
