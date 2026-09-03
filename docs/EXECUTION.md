# Execution Transcript

This file records the exact commands run against the showcase and their observed output. All commands were executed against a local Docker PostgreSQL 16 instance started via `docker compose up -d`.

## Environment

- OS: macOS (arm64)
- Docker: 29.7.2, Docker Compose 5.5.0
- PostgreSQL: 16-alpine (container), `psql` 16.14 (host client)

---

## 1. Start PostgreSQL

```
$ docker compose up -d

 Network showcase-pmlad_default  Created
 Container showcase-rls-postgres  Created
 Container showcase-rls-postgres  Started
```

Seed output (from container logs):

```
psql:/docker-entrypoint-initdb.d/02-seed.sql:82: NOTICE:  Seed: 2 orgs, 3 entities, 4 properties, 4 invoices
```

---

## 2. Default-Deny Demo (hero proof)

```
$ ./scripts/default-deny-demo.sh
```

Observed output:

```
RLS Default-Deny Demo — defense-in-depth survives an app bug
Connected as: app_role (restricted, non-superuser)
DB: postgresql://app_role:***@127.0.0.1:5433/showcase

═══════════════════════════════════════════════════════════════
  1. SCOPED (CORRECT) QUERY — app set session vars
═══════════════════════════════════════════════════════════════
  app.current_org    = aaaaaaaa-0000-0000-0000-000000000001
  app.current_entity = aaaaaaaa-0000-0000-0000-000000000011
BEGIN
SET
SET
 visible_properties
--------------------
                  2
(1 row)

     name     |          address
--------------+----------------------------
 Oak Manor    | 456 Oak Ave, OrgA-EntityA1
 Sunset Villa | 123 Main St, OrgA-EntityA1
(2 rows)

ROLLBACK

═══════════════════════════════════════════════════════════════
  2. UNSCOPED QUERY — app FORGOT session vars (the bug)
═══════════════════════════════════════════════════════════════
  (no app.current_org / app.current_entity set)
BEGIN
 visible_properties
--------------------
                  0
(1 row)

 visible_invoices
------------------
                0
(1 row)

ROLLBACK

═══════════════════════════════════════════════════════════════
  3. CROSS-TENANT QUERY — app asked for Org B's entity
═══════════════════════════════════════════════════════════════
  app.current_org    = aaaaaaaa-0000-0000-0000-000000000001  (but querying entity bbbbbbbb-0000-0000-0000-000000000011)
BEGIN
SET
SET
 cross_tenant_rows
-------------------
                 0
(1 row)

ROLLBACK

═══════════════════════════════════════════════════════════════
  RESULT
═══════════════════════════════════════════════════════════════
Scoped query returns rows; unscoped and cross-tenant queries return 0.
Isolation is enforced by PostgreSQL, not by application code.
```

Exit code: `0`.

This is captured as a terminal SVG at `docs/hero-proof.svg`.

---

## 3. Full RLS Validation Suite (13 groups)

```
$ ./scripts/validate-rls.sh
```

Observed output (group-level PASS lines, verbatim):

```
Pre-flight: Connected as app_role (not superuser) PASS

=== GROUP 1: Default Deny (no session vars -> 0 rows) ===
NOTICE:  PASS GROUP 1: Default deny — all 3 RLS tables return 0 rows without session vars

=== GROUP 2: Valid Entity Context -> Only Authorized Rows ===
NOTICE:  PASS GROUP 2: Valid entity context shows only authorized rows

=== GROUP 3: Cross-Org Read -> Zero Rows ===
NOTICE:  PASS GROUP 3: Cross-org read returns zero rows

=== GROUP 4: Dashboard allowed_entities Path ===
NOTICE:  PASS GROUP 4: allowed_entities shows only authorized rows

=== GROUP 5: allowed_entities Cannot Cross Orgs ===
NOTICE:  PASS GROUP 5: allowed_entities org boundary enforced

=== GROUP 6: Mixed-Tenant IN Clause Filtered ===
NOTICE:  PASS GROUP 6: Mixed-tenant IN clause filtered by RLS

=== GROUP 7: Write Wrong Entity Rejected (WITH CHECK) ===
NOTICE:  PASS GROUP 7: WITH CHECK entity boundary enforced

=== GROUP 8: Write Wrong Org Rejected (WITH CHECK) ===
NOTICE:  PASS GROUP 8: WITH CHECK org boundary enforced

=== GROUP 9: Null/Empty Session Vars -> Zero Rows ===
NOTICE:  PASS GROUP 9: Empty session vars -> zero rows

=== GROUP 10: Malformed Session Var -> Fails Closed ===
NOTICE:  PASS GROUP 10: Malformed session var -> error (fails closed, no data leaked)

=== GROUP 11: Org-Scoped Table — Correct Scoping ===
NOTICE:  PASS GROUP 11: Org-scoped table correctly scoped to org only

=== GROUP 12: Org-Scoped Default Deny ===
NOTICE:  PASS GROUP 12: Org-scoped table default deny holds

=== GROUP 13: Restricted Role Cannot Bypass RLS ===
NOTICE:  PASS GROUP 13: Restricted role cannot bypass RLS

=== Result Summary ===
  Group PASS lines detected: 13
  FAIL/ERROR lines detected: 0
  psql exit code: 0

=== ALL 13 GROUPS PASSED ===
RLS tenant isolation is enforced at the database level.
```

Exit code: `0`.

---

## 4. Structural Verification (CI gate)

```
$ ./scripts/verify-rls.sh
```

Observed output:

```
=== RLS Verification ===

--- Check 1: Connection role ---
OK: Connected as app_role (non-superuser)

--- Check 2: RLS enabled (relrowsecurity) ---
OK: entity — RLS enabled
OK: property — RLS enabled
OK: invoice — RLS enabled

--- Check 3: FORCE RLS (relforcerowsecurity) ---
OK: entity — FORCE RLS set
OK: property — FORCE RLS set
OK: invoice — FORCE RLS set

--- Check 4: Policies exist ---
OK: entity — 1 policy(ies)
OK: property — 1 policy(ies)
OK: invoice — 1 policy(ies)

--- Check 5: Default deny (no session vars → 0 rows) ---
OK: entity — 0 rows without context (default deny)
OK: property — 0 rows without context (default deny)
OK: invoice — 0 rows without context (default deny)

=== ALL CHECKS PASSED ===
```

Exit code: `0`.

---

## 5. Teardown

```
$ docker compose down -v
```

Removes the throwaway container and volume (destroys demo data).

---

## Summary

| Command | Exit | Result |
|---|---|---|
| `docker compose up -d` | 0 | Postgres up, 2 orgs / 3 entities / 4 properties / 4 invoices seeded |
| `./scripts/default-deny-demo.sh` | 0 | Scoped=2 rows, unscoped=0, cross-tenant=0 |
| `./scripts/validate-rls.sh` | 0 | 13/13 PASS groups |
| `./scripts/verify-rls.sh` | 0 | 5/5 structural checks |
