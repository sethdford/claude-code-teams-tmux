# Tasks — Split sw-db.sh: Extract Query/Schema Layer into lib/db-query.sh

## Status: In Progress
Pipeline: standard | Branch: refactor/split-sw-db-sh-extract-query-schema-laye-1583

## Checklist
- [ ] Task 1: Capture baseline — `./scripts/sw-db-test.sh` PASS/FAIL/TOTAL and `wc -l scripts/sw-db.sh` (1939)
- [ ] Task 2: Create `scripts/lib/db-query.sh` with header, precondition comment, `_SW_DB_QUERY_LOADED` guard, and no `set -euo pipefail`
- [ ] Task 3: Move lines 67–662 verbatim (via `sed -n`, not retyping); `init_schema`'s SQL heredoc byte-identical
- [ ] Task 4: Delete lines 67–662 from sw-db.sh
- [ ] Task 5: Insert the two-candidate resolver (`SCRIPT_DIR/lib` → `REPO_DIR/scripts/lib` → `error` + `exit 1`) after the config globals
- [ ] Task 6: Resolve VERSION policy via `./scripts/check-version-consistency.sh`; bump or hold accordingly
- [ ] Task 7: `bash -n` both files; `shellcheck` both; no new warnings
- [ ] Task 8: Function-parity diff (before-union vs after-union) is empty
- [ ] Task 9: `wc -l scripts/sw-db.sh` < 1400
- [ ] Task 10: `./scripts/sw-db-test.sh` matches baseline; `git diff --stat scripts/sw-db-test.sh` empty
- [ ] Task 11: All 15 consumer suites from step 10 green
- [ ] Task 12: Real-sqlite3 smoke — `init` then `health` in a throwaway `$HOME`
- [ ] Task 13: Add `lib/db-query.sh` row to the Shared Libraries table in `.claude/CLAUDE.md`
- [ ] Task 14: `shipwright docs check` exits 0 (use `docs sync` for AUTO-managed content)
- [ ] Task 15: `npm test` fully green
- [ ] `scripts/lib/db-query.sh` exists and contains `_db_exec`, `_db_query`, `_sql_escape`, `ensure_db_dir`, `check_sqlite3`, `db_available`, `_db_feature_enabled`, `init_schema`, `migrate_schema`
- [ ] `scripts/sw-db.sh` sources it via the two-candidate resolver and is **under 1400 lines**
- [ ] `git diff --stat scripts/sw-db-test.sh` is empty — the test file is untouched
- [ ] `./scripts/sw-db-test.sh` PASS/FAIL/TOTAL identical to the step-1 baseline
- [ ] Function-parity diff empty — no function gained, lost, or duplicated

## Notes
- Generated from pipeline plan at 2026-08-08T02:37:43Z
- Pipeline will update status as tasks complete
