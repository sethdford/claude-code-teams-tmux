# Tasks — Add Test Suites for the 5 Untested Scripts

## Status: In Progress
Pipeline: standard | Branch: test/add-test-suites-for-the-5-untested-scrip-3736

## Checklist
- [ ] Task 1: Add the shared harness skeleton (shebang, box header with em-dash purpose, `set -euo pipefail`, ERR trap, `test-helpers.sh` source, `setup_test_env`/`cleanup_test_env`) to all 5 new files; `chmod +x`
- [ ] Task 2: Write `sw-event-schema-sync-test.sh` — synthetic repo fixture, in-sync/drift/`--write`/idempotency/dynamic-type/stale-kept/no-python3 cases
- [ ] Task 3: Write `sw-test-all-test.sh` with a **sandboxed** copy of the runner + generated fake suites; assert discovery, `--list`, no-abort-on-failure, `--pattern`, timeout, report TSV, `--jobs`, exit codes 0/1/2
- [ ] Task 4: Write `sw-tmux-role-color-test.sh` — recording `tmux` mock, one assertion per role color, case-insensitivity, unknown/empty title fallback, tmux-failure tolerance
- [ ] Task 5: Write `sw-tmux-status-test.sh` — stage badge color/icon/label, upward state-file walk, missing state, fresh vs. stale heartbeats, `all`/unknown/default dispatch
- [ ] Task 6: Write `sw-tracker-github-test.sh` — label add/remove, arg-validation returns, `create_issue` label splitting and response parsing, `[]` fallbacks, `NO_GITHUB` short-circuit, `provider_notify` event emission
- [ ] Task 7: Verify no new suite shells out to the real repo `scripts/` dir or makes a network/`gh` call (grep the 5 files for unmocked `gh`/`git`/`curl`)
- [ ] Task 8: Register all 5 in `package.json` `test:legacy-chain` via `jq` + atomic `mv`; validate with `jq empty` and `npm run test:list`
- [ ] Task 9: Run `bash scripts/sw-docs.sh sync` and confirm `check` exits 0 with 5 new non-empty rows in `AUTO:test-suites`
- [ ] Task 10: Run each new suite individually; confirm each exits 0 and reports a nonzero test count
- [ ] Task 11: Time each new suite; confirm each finishes well under the 300s per-suite watchdog (target <20s)
- [ ] Task 12: Run full `npm test` and confirm no pre-existing suite regressed
- [ ] Task 13: Run `shellcheck` on the 5 new files; confirm Bash 3.2 compliance (no `declare -A`, `readarray`, `${var,,}`, `${var^^}`)
- [ ] Task 14: Verify test isolation — run the new suites twice in a row and confirm identical results and no leftover temp dirs or `$HOME/.shipwright` pollution
- [ ] All 5 `scripts/sw-*-test.sh` files exist, are executable, use `set -euo pipefail`, an ERR trap, `lib/test-helpers.sh` PASS/FAIL counters, and mock binaries for all externals
- [ ] Each new suite exits 0 standalone and asserts ≥10 behaviors
- [ ] `bash scripts/sw-test-all.sh --list` shows 110 suites (105 + 5)
- [ ] The 5 suites appear in `package.json` `test:legacy-chain`; `jq empty package.json` passes
- [ ] `bash scripts/sw-docs.sh check` exits 0; `AUTO:test-suites` contains 5 new rows with populated Purpose cells
- [ ] `npm test` passes with zero failures and zero timeouts; no previously-passing suite regressed

## Notes
- Generated from pipeline plan at 2026-09-02T19:20:09Z
- Pipeline will update status as tasks complete
