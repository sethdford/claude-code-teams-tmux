# Tasks — Hardcoded Policy Migration Engine with Adaptive Override Framework

## Status: In Progress
Pipeline: standard | Branch: migrate/hardcoded-policy-migration-engine-with-a-660

## Checklist
- [ ] Add `_policy_int <section> <key> [default]` to `scripts/lib/compat.sh` (sanitized, env→policy→default chain, Bash 3.2)
- [ ] Add `_policy_int` resolution-order coverage to `sw-policy-e2e-test.sh`
- [ ] Create `scripts/sw-policy-migrate.sh` with `scan` (keyword-filtered grep)
- [ ] Implement `rank` (git churn + intelligence-reference scoring), output top 20 + deferred 28
- [ ] Implement `migrate --dry-run/--apply` (atomic `jq` upsert into `tunables`, line rewrite, idempotent)
- [ ] Add `tunables` section to `config/policy.json` for top 20 values
- [ ] Extend `config/policy.schema.json` with `tunables` pattern schema + required keys
- [ ] Refactor top-20 scripts to `_policy_int` with original literal as fallback
- [ ] Add "POLICY & TUNABLES" validation section to `scripts/sw-doctor.sh`
- [ ] Write `docs/policy-migration.md` (28 deferred values + recipe)
- [ ] Create `scripts/sw-policy-migrate-test.sh`; register in `package.json`
- [ ] Sync VERSION vars; add `emit_event` to scanner; update `.claude/CLAUDE.md`
- [ ] Run `npm test` — all suites green (backward-compat validation)
- [ ] Scanner identifies hardcoded numeric thresholds/timeouts/limits across `scripts/*.sh`
- [ ] `config/policy.json` has structured `tunables`: section → key → `{default, env_var, adaptive_hint, rationale}`
- [ ] Top-20 scripts read via `_policy_int` with literal fallback (behavior unchanged when policy absent)
- [ ] `_policy_int <section> <key> [default]` in `scripts/lib/compat.sh`, Bash 3.2 safe, injection-guarded
- [ ] `docs/policy-migration.md` documents the remaining 28 values + recipe
- [ ] `shipwright doctor` validates policy parse, schema, required keys, env_var naming
- [ ] `config/policy.schema.json` validates the new section

## Notes
- Generated from pipeline plan at 2026-06-19T01:29:34Z
- Pipeline will update status as tasks complete
