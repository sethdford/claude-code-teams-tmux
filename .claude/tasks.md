# Tasks — Hardcoded Policy Migration to config/policy.json for Platform Autonomy

## Status: In Progress
Pipeline: standard | Branch: migrate/hardcoded-policy-migration-to-config-pol-468

## Checklist
- [ ] **Task 1**: Create config/policy.json schema with 5 categories and 20+ initial policies
- [ ] **Task 2**: Create scripts/lib/policy-loader.sh with get_policy(), get_policy_with_override(), validate_policy() functions
- [ ] **Task 3**: Add validate_policy() call to pipeline startup (scripts/sw-pipeline.sh)
- [ ] **Task 4**: Migrate scripts/sw-loop.sh to use policy-loader (circuit_breaker, max_extensions, etc.)
- [ ] **Task 5**: Migrate scripts/sw-daemon.sh to use policy-loader (max_parallel, max_workers)
- [ ] **Task 6**: Migrate scripts/sw-intelligence.sh to use policy-loader (cache_ttl, anomaly_threshold)
- [ ] **Task 7**: Create scripts/sw-extract-policies.sh extraction tool (one-time use)
- [ ] **Task 8**: Run extraction tool, review candidates, populate config/policy.json with 30-50 total policies
- [ ] **Task 9**: Migrate remaining 5-10 critical scripts (pipeline, adaptive, cost, etc.)
- [ ] **Task 10**: Create automated hygiene scan test (detects new hardcoded policy values)
- [ ] **Task 11**: Expand scripts/sw-policy-e2e-test.sh to 40+ test cases
- [ ] **Task 12**: Create docs/POLICY_MIGRATION_GUIDE.md with all policy keys and overrides
- [ ] **Task 13**: Update scripts/sw-doctor.sh with policy validation checks
- [ ] **Task 14**: Update .claude/CLAUDE.md documentation with policy system
- [ ] **Task 15**: Run full test suite, verify platform hygiene scan passes (0 new hardcoded values)
- [ ] config/policy.json created with 30+ policies in 5 categories
- [ ] scripts/lib/policy-loader.sh implemented with all 4 public functions
- [ ] 5 critical scripts migrated to use policy-loader (loop, daemon, intelligence, pipeline, adaptive)
- [ ] No hardcoded policy values remaining in migrated scripts
- [ ] scripts/sw-policy-e2e-test.sh has 40+ test cases, all pass

## Notes
- Generated from pipeline plan at 2026-05-14T19:07:40Z
- Pipeline will update status as tasks complete
