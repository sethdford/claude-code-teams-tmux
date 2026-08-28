# Tasks — Pipeline Template Recommendation Based on Detected Project Type

## Status: In Progress
Pipeline: standard | Branch: feat/pipeline-template-recommendation-based-o-2910

## Checklist
- [ ] All 5 signal detectors implemented and tested (Tasks 1a-1e)
- [ ] Recommender function implemented with all template branches (Task 2)
- [ ] Signals integrated into prep.sh output (Task 3)
- [ ] Init reads and uses recommendation (Task 4)
- [ ] All 65+ unit tests passing
- [ ] All 15+ integration tests passing
- [ ] CLAUDE.md updated with auto-recommend feature description
- [ ] Manual testing on 3 real project types:
  - [ ] Shipwright repo (monorepo, TypeScript, vitest, GitHub Actions) → expect `standard` or `full`
  - [ ] Simple Node project (single package, jest, no CI) → expect `fast` or `standard`
  - [ ] Python project (single package, pytest) → expect `standard` or `fast`
- [ ] Recommendation rationale is human-readable and accurate
- [ ] Feature is skippable (init defaults to recommendation but allows override)
- [ ] No performance regression in prep execution time (<30s on large repos)
- [ ] Error paths tested (corrupted git, missing files, invalid JSON)
- [ ] All 9 template types mentioned in issue have at least one test scenario

## Notes
- Generated from pipeline plan at 2026-08-28T00:50:24Z
- Pipeline will update status as tasks complete
