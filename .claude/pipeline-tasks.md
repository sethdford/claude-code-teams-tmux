# Pipeline Tasks — Cross-Pipeline Result Cache with Change-Based Invalidation

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/result-cache.sh` scaffold (header, VERSION, dirs, source guard).
- [ ] Task 2: Implement `result_cache_enabled` gate (config + tool availability).
- [ ] Task 3: Implement `result_cache_fingerprint` (git HEAD + porcelain hash + goal/body), subshell-safe.
- [ ] Task 4: Implement `_result_cache_init` + atomic `entries.json` seeding.
- [ ] Task 5: Implement `result_cache_get` (key, TTL age check, hit/miss events).
- [ ] Task 6: Implement `result_cache_store` with `jq --arg`, atomic `mv`, `max_entries` eviction.
- [ ] Task 7: Implement `result_cache_try_restore` + `result_cache_save` hooks (artifact I/O).
- [ ] Task 8: Wire both hooks into `pipeline-execution.sh` stage loop, fully guarded.
- [ ] Task 9: Source lib in `pipeline-stages.sh`/`bootstrap.sh` with no-op fallback.
- [ ] Task 10: Create `scripts/sw-result-cache.sh` CLI (`stats/list/get/clear/invalidate/prune/help`).
- [ ] Task 11: Register command in `scripts/sw` router.
- [ ] Task 12: Add `result_cache` block to `.claude/daemon-config.json` (disabled).
- [ ] Task 13: Write `scripts/sw-result-cache-test.sh`; register in `package.json`.
- [ ] Task 14: Update `.claude/CLAUDE.md` (Result Cache section, script tables, runtime-state).
- [ ] Task 15: Run `shipwright version check`, `shellcheck`, and new + related test suites.
- [ ] Three new files exist and pass `shellcheck` (bash 3.2 safe: no `declare -A`, `readarray`, `${var,,}`/`${var^^}`).
- [ ] With `result_cache.enabled=false` (default), pipeline behaves **identically** — hooks are provable no-ops (regression suites green).
- [ ] With the flag on: a second run over an **unchanged** repo restores `plan.md`/`design.md`/`spec.json` and skips the Claude call (verified via `result_cache.hit`).
- [ ] Any tracked/untracked change, changed goal/issue body, or TTL expiry produces a **miss** (tests 3 & 4) — no stale artifact ever served.
- [ ] Only `cacheable_stages` are cached; `build`/`test`/`pr`/`merge`/`deploy` never restored.

## Context
- Pipeline: autonomous
- Branch: ci/issue-725
- Issue: none
- Generated: 2026-07-03T14:50:00Z
