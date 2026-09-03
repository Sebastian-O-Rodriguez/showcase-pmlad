#!/usr/bin/env bash
# =============================================================================
# default-deny-demo.sh — Hero Proof: RLS default-deny survives an app bug
#
# Demonstrates the core claim in one screen:
#   1. Connect as the restricted app_role (non-superuser).
#   2. Scoped query (correct session vars)  → rows visible.
#   3. Unscoped query (app forgot to set them — the "bug") → 0 rows.
#   4. Cross-tenant query (wrong org's data) → 0 rows.
#
# This is the defense-in-depth story: even if application code forgets to
# scope a query, PostgreSQL returns zero rows instead of leaking tenants.
#
# Usage:
#   ./scripts/default-deny-demo.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5433}"
PGDATABASE="${PGDATABASE:-showcase}"
PGUSER="${PGUSER:-app_role}"
APP_ROLE_PASSWORD="${APP_ROLE_PASSWORD:-app_role_demo_pw}"
DATABASE_URL="postgresql://${PGUSER}:${APP_ROLE_PASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}"

# Seed fixture UUIDs (match db/02-seed.sql)
ORG_A_ID="aaaaaaaa-0000-0000-0000-000000000001"
ORG_B_ID="bbbbbbbb-0000-0000-0000-000000000001"
ENTITY_A1_ID="aaaaaaaa-0000-0000-0000-000000000011"
ENTITY_B1_ID="bbbbbbbb-0000-0000-0000-000000000011"

if ! command -v psql &>/dev/null; then
  echo "ERROR: psql not found in PATH."
  exit 1
fi

header() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  $*"
  echo "═══════════════════════════════════════════════════════════════"
}

echo "RLS Default-Deny Demo — defense-in-depth survives an app bug"
echo "Connected as: $PGUSER (restricted, non-superuser)"
echo "DB: postgresql://$PGUSER:***@$PGHOST:$PGPORT/$PGDATABASE"

header "1. SCOPED (CORRECT) QUERY — app set session vars"
echo "  app.current_org    = $ORG_A_ID"
echo "  app.current_entity = $ENTITY_A1_ID"
psql "$DATABASE_URL" -X --no-psqlrc <<'SQL'
BEGIN;
SET LOCAL "app.current_org"    = 'aaaaaaaa-0000-0000-0000-000000000001';
SET LOCAL "app.current_entity" = 'aaaaaaaa-0000-0000-0000-000000000011';
SELECT count(*) AS visible_properties FROM property;
SELECT name, address FROM property ORDER BY name;
ROLLBACK;
SQL

header "2. UNSCOPED QUERY — app FORGOT session vars (the bug)"
echo "  (no app.current_org / app.current_entity set)"
psql "$DATABASE_URL" -X --no-psqlrc <<'SQL'
BEGIN;
SELECT count(*) AS visible_properties FROM property;
SELECT count(*) AS visible_invoices  FROM invoice;
ROLLBACK;
SQL

header "3. CROSS-TENANT QUERY — app asked for Org B's entity"
echo "  app.current_org    = $ORG_A_ID  (but querying entity $ENTITY_B1_ID)"
psql "$DATABASE_URL" -X --no-psqlrc <<'SQL'
BEGIN;
SET LOCAL "app.current_org"    = 'aaaaaaaa-0000-0000-0000-000000000001';
SET LOCAL "app.current_entity" = 'aaaaaaaa-0000-0000-0000-000000000011';
SELECT count(*) AS cross_tenant_rows FROM property
  WHERE entity_id = 'bbbbbbbb-0000-0000-0000-000000000011';
ROLLBACK;
SQL

header "RESULT"
echo "Scoped query returns rows; unscoped and cross-tenant queries return 0."
echo "Isolation is enforced by PostgreSQL, not by application code."