-- =============================================================================
-- RLS Direct Validation Suite — 13 Test Groups
--
-- Purpose: Prove RLS enforcement under the app_role restricted role.
--          ALL tests must pass. Any failure blocks deploy.
--
-- Usage (via shell wrapper — recommended):
--   ./scripts/validate-rls.sh
--
-- Placeholder UUIDs (replaced by validate-rls.sh before execution):
--   __ORG_A_ID__       — Organization A (primary test org)
--   __ORG_B_ID__       — Organization B (cross-org target)
--   __ENTITY_A1_ID__   — Entity A1 (belongs to Org A)
--   __ENTITY_A2_ID__   — Entity A2 (belongs to Org A)
--   __ENTITY_B1_ID__   — Entity B1 (belongs to Org B)
--
-- Session context keys used by RLS policies:
--   app.current_org      — UUID of the validated organization
--   app.current_entity   — UUID of the validated entity (standard requests)
--   app.allowed_entities — comma-separated UUIDs (dashboard/bypass context only)
--
-- Design notes:
--   - Each test runs in its own BEGIN/ROLLBACK block — session vars never leak
--   - Groups 7 and 8 use DO $$ blocks to catch expected WITH CHECK violations
--   - Every test prints PASS or FAIL clearly for shell wrapper parsing
-- =============================================================================

-- =============================================================================
-- PRE-FLIGHT: Confirm we are NOT a superuser
-- RLS is bypassed for superusers. This check is mandatory.
-- =============================================================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_user WHERE usename = current_user AND usesuper) THEN
    RAISE EXCEPTION 'ABORT: Connected as superuser (%). RLS is bypassed. Use app_role.', current_user;
  END IF;
END $$;
\echo 'Pre-flight: Connected as app_role (not superuser) PASS'
\echo ''

-- =============================================================================
-- GROUP 1: Default Deny — No session vars → zero rows on ALL RLS tables
-- =============================================================================
\echo '=== GROUP 1: Default Deny (no session vars -> 0 rows) ==='

BEGIN;
DO $$
DECLARE
  v_count bigint;
  v_fail  boolean := false;
BEGIN
  SELECT count(*) INTO v_count FROM entity;
  IF v_count <> 0 THEN RAISE WARNING 'FAIL Group 1 entity: expected 0, got %', v_count; v_fail := true;
  ELSE RAISE NOTICE 'PASS Group 1 entity: 0 rows (default deny holds)'; END IF;

  SELECT count(*) INTO v_count FROM property;
  IF v_count <> 0 THEN RAISE WARNING 'FAIL Group 1 property: expected 0, got %', v_count; v_fail := true;
  ELSE RAISE NOTICE 'PASS Group 1 property: 0 rows (default deny holds)'; END IF;

  SELECT count(*) INTO v_count FROM invoice;
  IF v_count <> 0 THEN RAISE WARNING 'FAIL Group 1 invoice: expected 0, got %', v_count; v_fail := true;
  ELSE RAISE NOTICE 'PASS Group 1 invoice: 0 rows (default deny holds)'; END IF;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 1: Default deny broken on one or more tables';
  ELSE
    RAISE NOTICE 'PASS GROUP 1: Default deny — all 3 RLS tables return 0 rows without session vars';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 2: Valid Entity Context → Only Authorized Rows
-- With current_org + current_entity set to OrgA/EntityA1, we should only
-- see rows belonging to EntityA1. Other entities are invisible.
-- =============================================================================
\echo '=== GROUP 2: Valid Entity Context -> Only Authorized Rows ==='

BEGIN;
SET LOCAL "app.current_org" = '__ORG_A_ID__';
SET LOCAL "app.current_entity" = '__ENTITY_A1_ID__';
DO $$
DECLARE
  e1_count   bigint;
  prop_count bigint;
  inv_count  bigint;
  total_e    bigint;
  total_prop bigint;
  total_inv  bigint;
  v_fail     boolean := false;
BEGIN
  -- entity: org-scoped. Should see all org-A entities, not just A1.
  SELECT count(*) INTO e1_count FROM entity
    WHERE organization_id = '__ORG_A_ID__'::uuid;
  SELECT count(*) INTO total_e FROM entity;
  IF total_e <> e1_count THEN
    RAISE WARNING 'FAIL Group 2 entity: visible=% but org-A has %', total_e, e1_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 2 entity: % rows visible (all belong to Org A)', total_e;
  END IF;

  -- property: entity-scoped. Should see only Entity A1 properties.
  SELECT count(*) INTO prop_count FROM property
    WHERE entity_id = '__ENTITY_A1_ID__'::uuid;
  SELECT count(*) INTO total_prop FROM property;
  IF total_prop <> prop_count THEN
    RAISE WARNING 'FAIL Group 2 property: visible=% but entityA1 has %', total_prop, prop_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 2 property: % rows visible (all belong to Entity A1)', total_prop;
  END IF;

  -- invoice: entity-scoped. Same check.
  SELECT count(*) INTO inv_count FROM invoice
    WHERE entity_id = '__ENTITY_A1_ID__'::uuid;
  SELECT count(*) INTO total_inv FROM invoice;
  IF total_inv <> inv_count THEN
    RAISE WARNING 'FAIL Group 2 invoice: visible=% but entityA1 has %', total_inv, inv_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 2 invoice: % rows visible (all belong to Entity A1)', total_inv;
  END IF;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 2: Entity-scoped tables leaked rows from other entities';
  ELSE
    RAISE NOTICE 'PASS GROUP 2: Valid entity context shows only authorized rows';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 3: Cross-Org Read → Zero Rows
-- Even with OrgA context set, rows belonging to OrgB must be invisible.
-- =============================================================================
\echo '=== GROUP 3: Cross-Org Read -> Zero Rows ==='

BEGIN;
SET LOCAL "app.current_org" = '__ORG_A_ID__';
SET LOCAL "app.current_entity" = '__ENTITY_A1_ID__';
DO $$
DECLARE
  v_count bigint;
  v_fail  boolean := false;
BEGIN
  SELECT count(*) INTO v_count FROM entity
    WHERE organization_id = '__ORG_B_ID__'::uuid;
  IF v_count <> 0 THEN
    RAISE WARNING 'FAIL Group 3 entity: cross-org rows visible: %', v_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 3 entity: 0 cross-org rows from Org B';
  END IF;

  SELECT count(*) INTO v_count FROM property
    WHERE entity_id = '__ENTITY_B1_ID__'::uuid;
  IF v_count <> 0 THEN
    RAISE WARNING 'FAIL Group 3 property: cross-org entityB1 rows visible: %', v_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 3 property: 0 cross-org rows from entity B1';
  END IF;

  SELECT count(*) INTO v_count FROM invoice
    WHERE entity_id = '__ENTITY_B1_ID__'::uuid;
  IF v_count <> 0 THEN
    RAISE WARNING 'FAIL Group 3 invoice: cross-org entityB1 rows visible: %', v_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 3 invoice: 0 cross-org rows from entity B1';
  END IF;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 3: Cross-org isolation broken';
  ELSE
    RAISE NOTICE 'PASS GROUP 3: Cross-org read returns zero rows';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 4: Dashboard allowed_entities Path
-- No current_entity set; allowed_entities = A1,A2. Should see both entities'
-- rows but NOT entity B1 rows.
-- =============================================================================
\echo '=== GROUP 4: Dashboard allowed_entities Path ==='

BEGIN;
SET LOCAL "app.current_org" = '__ORG_A_ID__';
-- current_entity intentionally NOT set
SET LOCAL "app.allowed_entities" = '__ENTITY_A1_ID__,__ENTITY_A2_ID__';
DO $$
DECLARE
  a1_count   bigint;
  a2_count   bigint;
  total_prop bigint;
  total_inv  bigint;
  v_fail     boolean := false;
BEGIN
  SELECT count(*) INTO a1_count FROM property
    WHERE entity_id = '__ENTITY_A1_ID__'::uuid;
  SELECT count(*) INTO a2_count FROM property
    WHERE entity_id = '__ENTITY_A2_ID__'::uuid;
  SELECT count(*) INTO total_prop FROM property;
  IF total_prop <> a1_count + a2_count THEN
    RAISE WARNING 'FAIL Group 4 property: visible=% but A1=% + A2=%', total_prop, a1_count, a2_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 4 property: % rows visible (A1 + A2 only)', total_prop;
  END IF;

  SELECT count(*) INTO a1_count FROM invoice
    WHERE entity_id = '__ENTITY_A1_ID__'::uuid;
  SELECT count(*) INTO a2_count FROM invoice
    WHERE entity_id = '__ENTITY_A2_ID__'::uuid;
  SELECT count(*) INTO total_inv FROM invoice;
  IF total_inv <> a1_count + a2_count THEN
    RAISE WARNING 'FAIL Group 4 invoice: visible=% but A1=% + A2=%', total_inv, a1_count, a2_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 4 invoice: % rows visible (A1 + A2 only)', total_inv;
  END IF;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 4: allowed_entities path broken';
  ELSE
    RAISE NOTICE 'PASS GROUP 4: allowed_entities shows only authorized rows';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 5: allowed_entities Cannot Cross Org Boundary
-- allowed_entities includes B1's id, but current_org is A →
-- B1 rows must still be invisible.
-- =============================================================================
\echo '=== GROUP 5: allowed_entities Cannot Cross Orgs ==='

BEGIN;
SET LOCAL "app.current_org" = '__ORG_A_ID__';
SET LOCAL "app.allowed_entities" = '__ENTITY_A1_ID__,__ENTITY_B1_ID__';
DO $$
DECLARE
  v_count bigint;
  v_fail  boolean := false;
BEGIN
  SELECT count(*) INTO v_count FROM property
    WHERE entity_id = '__ENTITY_B1_ID__'::uuid;
  IF v_count <> 0 THEN
    RAISE WARNING 'FAIL Group 5 property: cross-org entityB1 rows visible via allowed_entities: %', v_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 5 property: 0 cross-org rows (org boundary enforced)';
  END IF;

  SELECT count(*) INTO v_count FROM invoice
    WHERE entity_id = '__ENTITY_B1_ID__'::uuid;
  IF v_count <> 0 THEN
    RAISE WARNING 'FAIL Group 5 invoice: cross-org entityB1 rows visible via allowed_entities: %', v_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 5 invoice: 0 cross-org rows (org boundary enforced)';
  END IF;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 5: allowed_entities org boundary broken';
  ELSE
    RAISE NOTICE 'PASS GROUP 5: allowed_entities org boundary enforced';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 6: Mixed-Tenant IN Clause Filtered
-- SELECT with WHERE entity_id IN (A1, B1) under A1 context → only A1 rows.
-- The RLS USING clause is ANDed — the WHERE filter doesn't widen RLS.
-- =============================================================================
\echo '=== GROUP 6: Mixed-Tenant IN Clause Filtered ==='

BEGIN;
SET LOCAL "app.current_org" = '__ORG_A_ID__';
SET LOCAL "app.current_entity" = '__ENTITY_A1_ID__';
DO $$
DECLARE
  a1_total  bigint;
  visible   bigint;
  v_fail    boolean := false;
BEGIN
  SELECT count(*) INTO a1_total FROM property
    WHERE entity_id = '__ENTITY_A1_ID__'::uuid;
  SELECT count(*) INTO visible FROM property
    WHERE entity_id IN ('__ENTITY_A1_ID__', '__ENTITY_B1_ID__');
  IF visible <> a1_total THEN
    RAISE WARNING 'FAIL Group 6 property: IN clause visible=% but A1-only=%', visible, a1_total;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 6 property: % rows (A1 only, IN clause filtered by RLS)', visible;
  END IF;

  SELECT count(*) INTO a1_total FROM invoice
    WHERE entity_id = '__ENTITY_A1_ID__'::uuid;
  SELECT count(*) INTO visible FROM invoice
    WHERE entity_id IN ('__ENTITY_A1_ID__', '__ENTITY_B1_ID__');
  IF visible <> a1_total THEN
    RAISE WARNING 'FAIL Group 6 invoice: IN clause visible=% but A1-only=%', visible, a1_total;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 6 invoice: % rows (A1 only, IN clause filtered by RLS)', visible;
  END IF;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 6: IN clause not filtered by RLS';
  ELSE
    RAISE NOTICE 'PASS GROUP 6: Mixed-tenant IN clause filtered by RLS';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 7: Write Wrong Entity Rejected (WITH CHECK)
-- INSERT property targeting entity B1 under A1 context → must be REJECTED.
-- =============================================================================
\echo '=== GROUP 7: Write Wrong Entity Rejected (WITH CHECK) ==='

BEGIN;
SET LOCAL "app.current_org" = '__ORG_A_ID__';
SET LOCAL "app.current_entity" = '__ENTITY_A1_ID__';
DO $$
DECLARE
  v_fail boolean := false;
BEGIN
  BEGIN
    INSERT INTO property (id, organization_id, entity_id, name)
    VALUES (gen_random_uuid(), '__ORG_A_ID__', '__ENTITY_B1_ID__', 'Test Cross-Entity Write');
    RAISE WARNING 'FAIL Group 7 property: INSERT with wrong entity_id succeeded';
    v_fail := true;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS Group 7 property: INSERT with wrong entity_id rejected (WITH CHECK)';
  END;

  BEGIN
    INSERT INTO invoice (id, organization_id, entity_id, property_id, amount)
    VALUES (gen_random_uuid(), '__ORG_A_ID__', '__ENTITY_B1_ID__', '__ENTITY_B1_ID__', 100.00);
    RAISE WARNING 'FAIL Group 7 invoice: INSERT with wrong entity_id succeeded';
    v_fail := true;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS Group 7 invoice: INSERT with wrong entity_id rejected (WITH CHECK)';
  END;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 7: WITH CHECK entity boundary broken';
  ELSE
    RAISE NOTICE 'PASS GROUP 7: WITH CHECK entity boundary enforced';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 8: Write Wrong Org Rejected (WITH CHECK)
-- INSERT property targeting org B under A1 context → must be REJECTED.
-- =============================================================================
\echo '=== GROUP 8: Write Wrong Org Rejected (WITH CHECK) ==='

BEGIN;
SET LOCAL "app.current_org" = '__ORG_A_ID__';
SET LOCAL "app.current_entity" = '__ENTITY_A1_ID__';
DO $$
DECLARE
  v_fail boolean := false;
BEGIN
  BEGIN
    INSERT INTO property (id, organization_id, entity_id, name)
    VALUES (gen_random_uuid(), '__ORG_B_ID__', '__ENTITY_A1_ID__', 'Test Cross-Org Write');
    RAISE WARNING 'FAIL Group 8 property: INSERT with wrong org_id succeeded';
    v_fail := true;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS Group 8 property: INSERT with wrong org_id rejected (WITH CHECK)';
  END;

  BEGIN
    -- Try to UPDATE an entity A1 property to belong to org B
    UPDATE property SET organization_id = '__ORG_B_ID__'
    WHERE entity_id = '__ENTITY_A1_ID__'::uuid
      AND organization_id = '__ORG_A_ID__'::uuid;
    RAISE WARNING 'FAIL Group 8 property: UPDATE to wrong org_id succeeded';
    v_fail := true;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS Group 8 property: UPDATE to wrong org_id rejected (WITH CHECK)';
  END;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 8: WITH CHECK org boundary broken';
  ELSE
    RAISE NOTICE 'PASS GROUP 8: WITH CHECK org boundary enforced';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 9: Null Session Vars → Zero Rows (Empty String)
-- Setting app.current_org to empty string → coalesce to nil UUID → 0 rows.
-- =============================================================================
\echo '=== GROUP 9: Null/Empty Session Vars -> Zero Rows ==='

BEGIN;
SET LOCAL "app.current_org" = '';
SET LOCAL "app.current_entity" = '__ENTITY_A1_ID__';
DO $$
DECLARE
  v_count bigint;
  v_fail  boolean := false;
BEGIN
  SELECT count(*) INTO v_count FROM property;
  IF v_count <> 0 THEN
    RAISE WARNING 'FAIL Group 9 property: empty org returned % rows (expected 0)', v_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 9 property: empty org -> 0 rows';
  END IF;

  SELECT count(*) INTO v_count FROM entity;
  IF v_count <> 0 THEN
    RAISE WARNING 'FAIL Group 9 entity: empty org returned % rows (expected 0)', v_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 9 entity: empty org -> 0 rows';
  END IF;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 9: Empty session vars not denied';
  ELSE
    RAISE NOTICE 'PASS GROUP 9: Empty session vars -> zero rows';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 10: Malformed Session Var → Error (Fails Closed)
-- Garbage UUID in current_entity → cast fails → error → no data leaked.
-- =============================================================================
\echo '=== GROUP 10: Malformed Session Var -> Fails Closed ==='

BEGIN;
SET LOCAL "app.current_org" = '__ORG_A_ID__';
SET LOCAL "app.current_entity" = 'not-a-uuid-at-all';
DO $$
DECLARE
  v_count bigint;
  v_fail  boolean := false;
BEGIN
  BEGIN
    SELECT count(*) INTO v_count FROM property;
    RAISE WARNING 'FAIL Group 10 property: garbage entity_id returned % rows (expected error)', v_count;
    v_fail := true;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS Group 10 property: malformed UUID -> error (fails closed)';
  END;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 10: Malformed session var not rejected';
  ELSE
    RAISE NOTICE 'PASS GROUP 10: Malformed session var -> error (fails closed, no data leaked)';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 11: Org-Scoped Table (entity) — Correct Scoping
-- entity table is org-scoped (no entity_id column). With current_org=A,
-- we should see all of Org A's entities, not individual entity scoping.
-- =============================================================================
\echo '=== GROUP 11: Org-Scoped Table — Correct Scoping ==='

BEGIN;
SET LOCAL "app.current_org" = '__ORG_A_ID__';
SET LOCAL "app.current_entity" = '__ENTITY_A1_ID__';
DO $$
DECLARE
  all_org_a  bigint;
  visible    bigint;
  v_fail     boolean := false;
BEGIN
  SELECT count(*) INTO all_org_a FROM entity
    WHERE organization_id = '__ORG_A_ID__'::uuid;
  SELECT count(*) INTO visible FROM entity;
  IF visible <> all_org_a THEN
    RAISE WARNING 'FAIL Group 11 entity: visible=% but org A has %', visible, all_org_a;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 11 entity: % rows visible (all Org A entities, not just A1)', visible;
  END IF;

  -- Verify entity does NOT narrow to just current_entity (it's org-scoped, not entity-scoped)
  IF visible < 2 THEN
    RAISE WARNING 'FAIL Group 11 entity: only % entity visible — entity-scoped policy incorrectly applied', visible;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 11 entity: sees all Org A entities (org-scoped, not entity-scoped)';
  END IF;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 11: Org-scoped table incorrectly filtered';
  ELSE
    RAISE NOTICE 'PASS GROUP 11: Org-scoped table correctly scoped to org only';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 12: Default Deny — Org-Scoped Table Without Org Context
-- entity table without current_org → zero rows.
-- =============================================================================
\echo '=== GROUP 12: Org-Scoped Default Deny ==='

BEGIN;
-- No session vars at all
DO $$
DECLARE
  v_count bigint;
  v_fail  boolean := false;
BEGIN
  SELECT count(*) INTO v_count FROM entity;
  IF v_count <> 0 THEN
    RAISE WARNING 'FAIL Group 12 entity: no org context returned % rows (expected 0)', v_count;
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 12 entity: 0 rows without org context';
  END IF;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 12: Org-scoped default deny broken';
  ELSE
    RAISE NOTICE 'PASS GROUP 12: Org-scoped table default deny holds';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- GROUP 13: Restricted Role Cannot Bypass RLS
-- =============================================================================
-- app_role is not superuser and has no BYPASSRLS. A non-superuser setting
-- row_security = off cannot silently skip RLS: any query that would be
-- affected by a policy instead ERRORS (fails closed). We assert that error.
-- =============================================================================
\echo '=== GROUP 13: Restricted Role Cannot Bypass RLS ==='

BEGIN;
DO $$
DECLARE
  v_count bigint;
  v_fail  boolean := false;
BEGIN
  -- Verify superuser attribute is NOT set
  IF EXISTS (SELECT 1 FROM pg_user WHERE usename = current_user AND usesuper) THEN
    RAISE WARNING 'FAIL Group 13: current_user is superuser';
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 13: current_user is not superuser (cannot bypass RLS)';
  END IF;

  -- Verify BYPASSRLS attribute is NOT set
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolbypassrls) THEN
    RAISE WARNING 'FAIL Group 13: current_user has BYPASSRLS attribute';
    v_fail := true;
  ELSE
    RAISE NOTICE 'PASS Group 13: current_user has no BYPASSRLS attribute';
  END IF;

  -- row_security = off: a non-superuser cannot disable RLS — queries that
  -- would be affected by a policy ERROR (fail closed) rather than return rows.
  BEGIN
    SET LOCAL row_security = off;
    BEGIN
      SELECT count(*) INTO v_count FROM property;
      -- Reaching here means RLS was silently bypassed — data would leak.
      RAISE WARNING 'FAIL Group 13 property: row_security=off returned % rows (RLS bypassed)', v_count;
      v_fail := true;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'PASS Group 13 property: row_security=off -> ERROR (fails closed, no data leaked)';
    END;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS Group 13 property: SET row_security=off rejected for non-superuser';
  END;

  IF v_fail THEN
    RAISE EXCEPTION 'FAIL GROUP 13: Restricted role CAN bypass RLS';
  ELSE
    RAISE NOTICE 'PASS GROUP 13: Restricted role cannot bypass RLS';
  END IF;
END $$;
ROLLBACK;
\echo ''

-- =============================================================================
-- FINAL SUMMARY
-- =============================================================================
\echo '=== Validation Complete ==='
\echo 'All 13 groups must show PASS above. Any FAIL = RLS isolation broken.'