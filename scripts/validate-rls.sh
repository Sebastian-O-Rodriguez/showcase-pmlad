#!/usr/bin/env bash
# =============================================================================
# validate-rls.sh — RLS Direct Validation Wrapper
#
# Runs the full 13-group SQL validation suite against a live database under
# the app_role restricted role. All tests must pass before app rollout.
#
# Usage:
#   ./scripts/validate-rls.sh
#
# Environment variables (all optional; default to the seed fixtures):
#   PGHOST / PGPORT / PGDATABASE / PGUSER / PGPASSWORD  — standard psql vars
#   APP_ROLE_PASSWORD  — password for the app_role restricted role
#   ORG_A_ID, ORG_B_ID, ENTITY_A1_ID, ENTITY_A2_ID, ENTITY_B1_ID
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed, missing tool, or connection error
#
# How UUIDs are used:
#   __ORG_A_ID__      — Organization A (primary test org)
#   __ORG_B_ID__      — Organization B (cross-org isolation target)
#   __ENTITY_A1_ID__  — Entity A1 (belongs to Org A)
#   __ENTITY_A2_ID__  — Entity A2 (belongs to Org A)
#   __ENTITY_B1_ID__  — Entity B1 (belongs to Org B)
#
# Notes:
#   - Must connect as app_role (non-superuser). RLS is bypassed for superusers.
#   - The script substitutes UUID placeholders in a temporary copy of the SQL
#     file — the original validate-rls.sql is never modified.
#   - FAIL detection: parses output for 'FAIL' lines and psql ERROR lines.
#   - Requires psql in PATH.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$SCRIPT_DIR/validate-rls.sql"

# ---------------------------------------------------------------------------
# Connection defaults (match docker-compose.yml + db/02-seed.sql fixtures)
# ---------------------------------------------------------------------------
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5433}"
PGDATABASE="${PGDATABASE:-showcase}"
PGUSER="${PGUSER:-app_role}"
APP_ROLE_PASSWORD="${APP_ROLE_PASSWORD:-app_role_demo_pw}"

# ---------------------------------------------------------------------------
# UUID fixture defaults (match db/02-seed.sql)
# ---------------------------------------------------------------------------
ORG_A_ID="${ORG_A_ID:-aaaaaaaa-0000-0000-0000-000000000001}"
ORG_B_ID="${ORG_B_ID:-bbbbbbbb-0000-0000-0000-000000000001}"
ENTITY_A1_ID="${ENTITY_A1_ID:-aaaaaaaa-0000-0000-0000-000000000011}"
ENTITY_A2_ID="${ENTITY_A2_ID:-aaaaaaaa-0000-0000-0000-000000000012}"
ENTITY_B1_ID="${ENTITY_B1_ID:-bbbbbbbb-0000-0000-0000-000000000011}"

# ---------------------------------------------------------------------------
# Colour helpers (degraded gracefully if terminal doesn't support it)
# ---------------------------------------------------------------------------
RED=''; GREEN=''; YELLOW=''; RESET=''
if [[ -t 1 ]] && command -v tput &>/dev/null; then
  RED=$(tput setaf 1); GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3); RESET=$(tput sgr0)
fi

info()   { echo "${YELLOW}[INFO]${RESET}  $*"; }
pass()   { echo "${GREEN}[PASS]${RESET}  $*"; }
fail()   { echo "${RED}[FAIL]${RESET}  $*"; }
header() { echo ""; echo "=== $* ==="; }

# ---------------------------------------------------------------------------
# Pre-flight: check required tools
# ---------------------------------------------------------------------------
if ! command -v psql &>/dev/null; then
  echo "ERROR: psql not found in PATH. Install PostgreSQL client tools."
  exit 1
fi

if ! command -v sed &>/dev/null; then
  echo "ERROR: sed not found in PATH."
  exit 1
fi

# ---------------------------------------------------------------------------
# Pre-flight: validate UUID format
# ---------------------------------------------------------------------------
UUID_REGEX='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
UUID_VALID=0
validate_uuid() {
  local name="$1" value="${!1}"
  if ! [[ "$value" =~ $UUID_REGEX ]]; then
    echo "ERROR: $name is not a valid UUID: $value"
    UUID_VALID=1
  fi
}
validate_uuid ORG_A_ID
validate_uuid ORG_B_ID
validate_uuid ENTITY_A1_ID
validate_uuid ENTITY_A2_ID
validate_uuid ENTITY_B1_ID
if [[ $UUID_VALID -ne 0 ]]; then
  exit 1
fi
info "All UUID formats validated"

# ---------------------------------------------------------------------------
# Verify SQL template exists
# ---------------------------------------------------------------------------
if [[ ! -f "$SQL_FILE" ]]; then
  echo "ERROR: SQL template not found: $SQL_FILE"
  exit 1
fi
info "SQL template: $SQL_FILE"

# ---------------------------------------------------------------------------
# Substitute UUID placeholders into a temp file
# ---------------------------------------------------------------------------
TMPFILE=$(mktemp /tmp/validate-rls-XXXXXX.sql)
trap 'rm -f "$TMPFILE"' EXIT

sed \
  -e "s/__ORG_A_ID__/${ORG_A_ID}/g" \
  -e "s/__ORG_B_ID__/${ORG_B_ID}/g" \
  -e "s/__ENTITY_A1_ID__/${ENTITY_A1_ID}/g" \
  -e "s/__ENTITY_A2_ID__/${ENTITY_A2_ID}/g" \
  -e "s/__ENTITY_B1_ID__/${ENTITY_B1_ID}/g" \
  "$SQL_FILE" > "$TMPFILE"

info "UUID placeholders substituted into temp file"

# ---------------------------------------------------------------------------
# Build DATABASE_URL for the restricted role
# ---------------------------------------------------------------------------
DATABASE_URL="postgresql://${PGUSER}:${APP_ROLE_PASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}"

header "Running RLS Validation Suite (13 groups)"
echo ""
echo "  DB: postgresql://${PGUSER}:***@${PGHOST}:${PGPORT}/${PGDATABASE} (password redacted)"
echo "  ORG_A_ID:     $ORG_A_ID"
echo "  ORG_B_ID:     $ORG_B_ID"
echo "  ENTITY_A1_ID: $ENTITY_A1_ID"
echo "  ENTITY_A2_ID: $ENTITY_A2_ID"
echo "  ENTITY_B1_ID: $ENTITY_B1_ID"
echo ""

# ---------------------------------------------------------------------------
# Run psql and capture full output
# -v ON_ERROR_STOP=1 causes psql to exit non-zero on SQL errors
# ---------------------------------------------------------------------------
PSQL_OUTPUT=$(psql \
  -v ON_ERROR_STOP=1 \
  --no-psqlrc \
  -X \
  "$DATABASE_URL" \
  -f "$TMPFILE" 2>&1) || PSQL_EXIT=$?

PSQL_EXIT="${PSQL_EXIT:-0}"

# Print the full output
echo "$PSQL_OUTPUT"
echo ""

# ---------------------------------------------------------------------------
# Parse results
# ---------------------------------------------------------------------------
header "Result Summary"

# Count group-level PASS/FAIL assertions from NOTICE/WARNING output.
# Exclude raw SQL source lines (which contain RAISE ... 'FAIL ...' as text).
PASS_COUNT=$(echo "$PSQL_OUTPUT" | grep -cE '(NOTICE|WARNING|INFO):.*PASS GROUP' || true)
FAIL_COUNT=$(echo "$PSQL_OUTPUT" | grep -cE '(NOTICE|WARNING|ERROR|INFO):.*FAIL' || true)
# Also count psql-level ERROR lines (connection errors, syntax errors)
PSQL_ERROR_COUNT=$(echo "$PSQL_OUTPUT" | grep -cE '^(ERROR:|psql:.*ERROR:)' || true)
FAIL_COUNT=$((FAIL_COUNT + PSQL_ERROR_COUNT))

echo ""
echo "  Group PASS lines detected: $PASS_COUNT"
echo "  FAIL/ERROR lines detected: $FAIL_COUNT"
echo "  psql exit code: $PSQL_EXIT"
echo ""

# Check if pre-flight superuser check passed
if echo "$PSQL_OUTPUT" | grep -q 'ABORT: Connected as superuser'; then
  echo "FATAL: Validation ran as superuser. RLS is bypassed for superusers."
  exit 1
fi

# ---------------------------------------------------------------------------
# Final verdict
# ---------------------------------------------------------------------------
if [[ $FAIL_COUNT -eq 0 && $PSQL_EXIT -eq 0 && $PASS_COUNT -eq 13 ]]; then
  echo "=== ALL 13 GROUPS PASSED ==="
  echo "RLS tenant isolation is enforced at the database level."
  exit 0
elif [[ $FAIL_COUNT -eq 0 && $PSQL_EXIT -eq 0 ]]; then
  echo "=== WARNING: only $PASS_COUNT/13 group PASS lines detected ==="
  echo "RLS tests passed but group count is unexpected. Check the suite."
  exit 1
else
  echo "=== VALIDATION FAILED ==="
  echo "RLS isolation is broken or the database is misconfigured."
  echo "Deployment MUST be blocked."
  exit 1
fi