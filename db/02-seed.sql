-- =============================================================================
-- Seed data for RLS showcase validation
-- Fixed UUIDs for reproducible test fixtures.
-- Must run as superuser (RLS is bypassed).
-- =============================================================================

-- Org A (primary test organization)
INSERT INTO organization (id, name) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Org A')
ON CONFLICT (id) DO NOTHING;

-- Org B (cross-org isolation target)
INSERT INTO organization (id, name) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001', 'Org B')
ON CONFLICT (id) DO NOTHING;

-- Entity A1 (belongs to Org A)
INSERT INTO entity (id, organization_id, name) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000011', 'aaaaaaaa-0000-0000-0000-000000000001', 'Entity A1')
ON CONFLICT (id) DO NOTHING;

-- Entity A2 (belongs to Org A; used for dashboard/multi-entity tests)
INSERT INTO entity (id, organization_id, name) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000012', 'aaaaaaaa-0000-0000-0000-000000000001', 'Entity A2')
ON CONFLICT (id) DO NOTHING;

-- Entity B1 (belongs to Org B; cross-org isolation target)
INSERT INTO entity (id, organization_id, name) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000011', 'bbbbbbbb-0000-0000-0000-000000000001', 'Entity B1')
ON CONFLICT (id) DO NOTHING;

-- Property A1-1 (Org A, Entity A1)
INSERT INTO property (id, organization_id, entity_id, name, address) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000100', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000011', 'Sunset Villa', '123 Main St, OrgA-EntityA1')
ON CONFLICT (id) DO NOTHING;

-- Property A1-2 (Org A, Entity A1 — second row for count tests)
INSERT INTO property (id, organization_id, entity_id, name, address) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000101', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000011', 'Oak Manor', '456 Oak Ave, OrgA-EntityA1')
ON CONFLICT (id) DO NOTHING;

-- Property A2-1 (Org A, Entity A2)
INSERT INTO property (id, organization_id, entity_id, name, address) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000200', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000012', 'River Lodge', '789 River Rd, OrgA-EntityA2')
ON CONFLICT (id) DO NOTHING;

-- Property B1-1 (Org B, Entity B1 — cross-org isolation target)
INSERT INTO property (id, organization_id, entity_id, name, address) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000100', 'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000011', 'Cross-Org Property', '1 Cross St, OrgB-EntityB1')
ON CONFLICT (id) DO NOTHING;

-- Invoice A1-1 (Org A, Entity A1, Property A1-1)
INSERT INTO invoice (id, organization_id, entity_id, property_id, amount) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000300', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000011', 'aaaaaaaa-0000-0000-0000-000000000100', 1500.00)
ON CONFLICT (id) DO NOTHING;

-- Invoice A1-2 (Org A, Entity A1, Property A1-2)
INSERT INTO invoice (id, organization_id, entity_id, property_id, amount) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000301', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000011', 'aaaaaaaa-0000-0000-0000-000000000101', 2200.00)
ON CONFLICT (id) DO NOTHING;

-- Invoice A2-1 (Org A, Entity A2, Property A2-1)
INSERT INTO invoice (id, organization_id, entity_id, property_id, amount) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000400', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000012', 'aaaaaaaa-0000-0000-0000-000000000200', 1800.00)
ON CONFLICT (id) DO NOTHING;

-- Invoice B1-1 (Org B, Entity B1, Property B1-1)
INSERT INTO invoice (id, organization_id, entity_id, property_id, amount) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000300', 'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000011', 'bbbbbbbb-0000-0000-0000-000000000100', 990.00)
ON CONFLICT (id) DO NOTHING;

-- Verify counts
DO $$
DECLARE
  orgs int; entities int; props int; invs int;
BEGIN
  SELECT count(*) INTO orgs    FROM organization;
  SELECT count(*) INTO entities FROM entity;
  SELECT count(*) INTO props   FROM property;
  SELECT count(*) INTO invs    FROM invoice;
  RAISE NOTICE 'Seed: % orgs, % entities, % properties, % invoices', orgs, entities, props, invs;
END $$;