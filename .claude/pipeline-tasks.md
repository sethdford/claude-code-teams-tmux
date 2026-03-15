# Pipeline Tasks — Simple Feature Success Smoke Test - Add Version Flag to sw Command

## Implementation Checklist
- [ ] Task 1: Create `scripts/sw-version-test.sh` with test harness boilerplate
- [ ] Task 2: Add test — `sw --version` outputs version string with semver pattern
- [ ] Task 3: Add test — `sw -v` produces same output as `--version`
- [ ] Task 4: Add test — `sw --version` exits with code 0
- [ ] Task 5: Add test — `sw version` subcommand shows version
- [ ] Task 6: Add test — `sw version check` exits 0 in shipwright repo
- [ ] Task 7: Add test — `sw version bump` with no args exits 1
- [ ] Task 8: Register test in `package.json` test script chain
- [ ] Task 9: Run test suite and verify all tests pass
- [ ] Task 10: Run existing `sw-hello-test.sh` to confirm no regressions
- [x] `sw --version` flag exists and outputs version (pre-existing)
- [x] `sw -v` flag exists and outputs version (pre-existing)
- [ ] `scripts/sw-version-test.sh` exists and follows project test conventions
- [ ] Test covers `--version`, `-v`, `version show`, `version check`, `version bump` error
- [ ] All tests in `sw-version-test.sh` pass (FAIL: 0)
- [ ] Test registered in `package.json` `test` script
- [ ] Existing test suite (`sw-hello-test.sh`) still passes

## Context
- Pipeline: autonomous
- Branch: ci/issue-281
- Issue: none
- Generated: 2026-03-15T07:03:29Z
