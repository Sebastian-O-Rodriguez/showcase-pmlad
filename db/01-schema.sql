-- =============================================================================
-- Minimal multi-tenant schema with PostgreSQL Row-Level Security (RLS)
--
-- This is a self-contained reconstruction of a production tenant-isolation
-- design. It proves the SAME idea as the original system — isolation enforced
-- at the database, not in application code — using a minimal model and
-- generic role/table names. (See README "Public Showcase Scope".)
--
-- Model:
--   organization            (top-level tenant boundary; NOT RLS-protected,
--                            discovered via membership before context exists)
--   entity                  (sub-tenant within an organization; ORG-scoped)
--   property, invoice       (business rows; ENTITY-scoped + ORG-scoped)
--
-- Restricted application role: app_role
--
-- Session context keys (set via `SET LOCAL` inside each transaction):
--   app.current_org       — UUID of the validated organization
--   app.current_entity    — UUID of the validated entity (standard requests)
--   app.allowed_entities  — comma-separated UUIDs (dashboard/multi-entity path)
--
-- DEFAULT DENY: a missing/empty session var coalesces to the nil UUID
-- (00000000-...) which matches no real row — zero rows without valid context.
--
-- FORCE ROW LEVEL SECURITY: policies apply even to the table owner, so a bug
-- that connects with an over-privileged role still cannot read another tenant.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Restricted application role (created idempotently; demo-only password)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_role') THEN
    -- Demo-only local password. Never a real secret: this role exists solely
    -- inside the throwaway docker-compose Postgres used to run this showcase.
    CREATE ROLE app_role LOGIN PASSWORD 'app_role_demo_pw';
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS organization (
  id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL
);

CREATE TABLE IF NOT EXISTS entity (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organization(id) ON DELETE RESTRICT,
  name            text NOT NULL
);
CREATE INDEX IF NOT EXISTS entity_organization_id_idx ON entity(organization_id);

CREATE TABLE IF NOT EXISTS property (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organization(id) ON DELETE RESTRICT,
  entity_id       uuid NOT NULL REFERENCES entity(id) ON DELETE RESTRICT,
  name            text NOT NULL,
  address         text
);
CREATE INDEX IF NOT EXISTS property_organization_id_idx ON property(organization_id);
CREATE INDEX IF NOT EXISTS property_entity_id_idx ON property(entity_id);

CREATE TABLE IF NOT EXISTS invoice (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organization(id) ON DELETE RESTRICT,
  entity_id       uuid NOT NULL REFERENCES entity(id) ON DELETE RESTRICT,
  property_id     uuid NOT NULL REFERENCES property(id) ON DELETE RESTRICT,
  amount          numeric(10, 2) NOT NULL
);
CREATE INDEX IF NOT EXISTS invoice_organization_id_idx ON invoice(organization_id);
CREATE INDEX IF NOT EXISTS invoice_entity_id_idx ON invoice(entity_id);

-- ---------------------------------------------------------------------------
-- Grants: the restricted role can talk to every table, but RLS decides rows.
-- ---------------------------------------------------------------------------
GRANT CONNECT ON DATABASE showcase TO app_role;
GRANT USAGE ON SCHEMA public TO app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_role;

-- ---------------------------------------------------------------------------
-- Helper expression used by every policy:
--   org_is_ok()      → organization matches current_org (nil-UUID on missing)
--   entity_is_ok()   → entity matches current_entity OR is in allowed_entities
--   entity_write_ok()→ WITH CHECK: writes must target the single current entity
-- ---------------------------------------------------------------------------

-- entity: ORG-scoped. Visible only when current_org matches.
ALTER TABLE entity ENABLE ROW LEVEL SECURITY;
ALTER TABLE entity FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON entity;
CREATE POLICY org_isolation ON entity
  FOR ALL
  USING (
    organization_id = coalesce(
      nullif(current_setting('app.current_org', true), ''),
      '00000000-0000-0000-0000-000000000000'
    )::uuid
  )
  WITH CHECK (
    organization_id = coalesce(
      nullif(current_setting('app.current_org', true), ''),
      '00000000-0000-0000-0000-000000000000'
    )::uuid
  );

-- property: ENTITY-scoped + ORG-scoped.
ALTER TABLE property ENABLE ROW LEVEL SECURITY;
ALTER TABLE property FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON property;
CREATE POLICY tenant_isolation ON property
  FOR ALL
  USING (
    organization_id = coalesce(
      nullif(current_setting('app.current_org', true), ''),
      '00000000-0000-0000-0000-000000000000'
    )::uuid
    AND (
      entity_id = coalesce(
        nullif(current_setting('app.current_entity', true), ''),
        '00000000-0000-0000-0000-000000000000'
      )::uuid
      OR (
        (current_setting('app.current_entity', true) IS NULL
          OR current_setting('app.current_entity', true) = '')
        AND entity_id = ANY(
          string_to_array(
            coalesce(nullif(current_setting('app.allowed_entities', true), ''), ''),
            ','
          )::uuid[]
        )
      )
    )
  )
  WITH CHECK (
    organization_id = coalesce(
      nullif(current_setting('app.current_org', true), ''),
      '00000000-0000-0000-0000-000000000000'
    )::uuid
    AND entity_id = coalesce(
      nullif(current_setting('app.current_entity', true), ''),
      '00000000-0000-0000-0000-000000000000'
    )::uuid
  );

-- invoice: ENTITY-scoped + ORG-scoped (same shape as property).
ALTER TABLE invoice ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoice FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON invoice;
CREATE POLICY tenant_isolation ON invoice
  FOR ALL
  USING (
    organization_id = coalesce(
      nullif(current_setting('app.current_org', true), ''),
      '00000000-0000-0000-0000-000000000000'
    )::uuid
    AND (
      entity_id = coalesce(
        nullif(current_setting('app.current_entity', true), ''),
        '00000000-0000-0000-0000-000000000000'
      )::uuid
      OR (
        (current_setting('app.current_entity', true) IS NULL
          OR current_setting('app.current_entity', true) = '')
        AND entity_id = ANY(
          string_to_array(
            coalesce(nullif(current_setting('app.allowed_entities', true), ''), ''),
            ','
          )::uuid[]
        )
      )
    )
  )
  WITH CHECK (
    organization_id = coalesce(
      nullif(current_setting('app.current_org', true), ''),
      '00000000-0000-0000-0000-000000000000'
    )::uuid
    AND entity_id = coalesce(
      nullif(current_setting('app.current_entity', true), ''),
      '00000000-0000-0000-0000-000000000000'
    )::uuid
  );
