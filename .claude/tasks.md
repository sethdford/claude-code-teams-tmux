# Tasks — Project Type Auto-Detection and Smart Template Recommendation Engine

## Status: In Progress
Pipeline: standard | Branch: feat/project-type-auto-detection-and-smart-te-480

## Checklist
- [ ] Task 1: Create `scripts/lib/project-detect.sh` skeleton with VERSION, set -euo pipefail, function stubs
- [ ] Task 2: Implement 10 per-type detector functions (node, nextjs, react, vue, rails, django, python, go, rust, java)
- [ ] Task 3: Implement `detect_project_type()` dispatcher with priority order and confidence scoring
- [ ] Task 4: Implement `recommend_template()` mapping (simple→fast, standard→standard, complex/java→full)
- [ ] Task 5: Implement `write_daemon_config()` with atomic write and jq merge (preserve existing keys)
- [ ] Task 6: Add `--interactive` flag and detection hook to `scripts/sw-prep.sh`
- [ ] Task 7: Create `scripts/sw-project-detect-test.sh` with 10 fixture project types
- [ ] Task 8: Add merge-preservation test and ambiguous monorepo test
- [ ] Task 9: Register test in `package.json` scripts and ensure `npm test` includes it
- [ ] Task 10: Run `shipwright doctor` and `npm test` to verify no regressions
- [ ] `scripts/lib/project-detect.sh` exists, sourced cleanly under bash 3.2
- [ ] 10 project types detected with correct test_cmd/build_cmd/template
- [ ] `shipwright prep --interactive` shows detection, asks confirmation, writes daemon-config.json
- [ ] Existing daemon-config.json values preserved (merge, not overwrite)
- [ ] `npm test` includes new test suite and passes 100%
- [ ] `shipwright doctor` reports no new issues
- [ ] No regressions in existing `sw-prep-test.sh`

## Notes
- Generated from pipeline plan at 2026-05-15T01:22:27Z
- Pipeline will update status as tasks complete
