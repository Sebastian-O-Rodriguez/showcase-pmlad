#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# verify-rls.sh — RLS Verification Script
# Verifies Row Level Security is properly configured on all
# tenant-owned tables. Run against any environment.
#
# Usage: ./scripts/verify-rls.sh
# Exit: 0 = all checks passed, 1 = verification failed
# ============================================================

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5433}"
PGDATABASE="${PGDATABASE:-showcase}"
PGUSER="${PGUSER:-app_role}"
APP_ROLE_PASSWORD="${APP_ROLE_PASSWORD:-app_role_demo_pw}"
DATABASE_URL="postgresql://${PGUSER}:${APP_ROLE_PASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}"

# 3 tenant-owned tables enforced by RLS:
#   org-scoped (1):    entity
#   entity-scoped (2): property, invoice
TABLES='entity property invoice'

FAIL=0

echo "=== RLS Verification ==="
echo ""

# Require psql
if ! command -v psql &>/dev/null; then
  echo "ERROR: psql not found in PATH."
  exit 1
fi

# 1. Verify connection is NOT superuser
echo "--- Check 1: Connection role ---"
CURRENT_USER=$(psql "$DATABASE_URL" -tAc "SELECT current_user")
IS_SUPER=$(psql "$DATABASE_URL" -tAc "SELECT usesuper FROM pg_user WHERE usename = current_user")
if [[ "$IS_SUPER" == "t" ]]; then
  echo "FAIL: Connected as $CURRENT_USER (superuser — RLS is bypassed)"
  FAIL=1
else
  echo "OK: Connected as $CURRENT_USER (non-superuser)"
fi
echo ""

# 2. Verify RLS enabled on all tenant tables
echo "--- Check 2: RLS enabled (relrowsecurity) ---"
for table in $TABLES; do
  REL_RLS=$(psql "$DATABASE_URL" -tAc "SELECT relrowsecurity FROM pg_class WHERE relname = '$table'")
  if [[ "$REL_RLS" == "t" ]]; then
    echo "OK: $table — RLS enabled"
  else
    echo "FAIL: $table — RLS NOT enabled"
    FAIL=1
  fi
done
echo ""

# 3. Verify FORCE ROW LEVEL SECURITY on all tenant tables
echo "--- Check 3: FORCE RLS (relforcerowsecurity) ---"
for table in $TABLES; do
  FORCE_RLS=$(psql "$DATABASE_URL" -tAc "SELECT relforcerowsecurity FROM pg_class WHERE relname = '$table'")
  if [[ "$FORCE_RLS" == "t" ]]; then
    echo "OK: $table — FORCE RLS set"
  else
    echo "FAIL: $table — FORCE RLS NOT set"
    FAIL=1
  fi
done
echo ""

# 4. Verify policies exist on all tenant tables
echo "--- Check 4: Policies exist ---"
for table in $TABLES; do
  POL_COUNT=$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM pg_policies WHERE tablename = '$table'")
  if [[ "$POL_COUNT" -ge 1 ]]; then
    echo "OK: $table — $POL_COUNT policy(ies)"
  else
    echo "FAIL: $table — no policies"
    FAIL=1
  fi
done
echo ""

# 5. Verify default deny — without session vars, all tables return 0 rows
echo "--- Check 5: Default deny (no session vars → 0 rows) ---"
for table in $TABLES; do
  ROW_COUNT=$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM $table")
  if [[ "$ROW_COUNT" == "0" ]]; then
    echo "OK: $table — 0 rows without context (default deny)"
  else
    echo "FAIL: $table — $ROW_COUNT rows visible without context"
    FAIL=1
  fi
done
echo ""

# Summary
if [[ $FAIL -ne 0 ]]; then
  echo "=== VERIFICATION FAILED ==="
  exit 1
fi

echo "=== ALL CHECKS PASSED ==="