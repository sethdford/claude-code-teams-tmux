# Tasks — Community Starter Kit Generator with Framework Detection and Best-Practice Templates

## Status: In Progress
Pipeline: standard | Branch: feat/community-starter-kit-generator-with-fra-349

## Checklist
- [ ] Task 1: Create `scripts/lib/starter-kit.sh` with framework best practices lookup functions (Node.js, Python, Go, Rust, Ruby) — Tasks 2-4 depend on this
- [ ] Task 2: Add quality checks functions to `lib/starter-kit.sh` returning JSON per framework
- [ ] Task 3: Add example issue generation functions to `lib/starter-kit.sh`
- [ ] Task 4: Add pitfalls/gotchas functions per framework to `lib/starter-kit.sh`
- [ ] Task 5: Create `scripts/sw-starter-kit.sh` CLI with `generate`, `issues`, `check`, `help` subcommands — depends on Tasks 1-4
- [ ] Task 6: Implement `generate` subcommand — auto-detect → prep → enhance CLAUDE.md → quality checks → issues → report
- [ ] Task 7: Implement `issues` subcommand — generate example issue templates only
- [ ] Task 8: Implement `check` subcommand — audit existing starter kit setup
- [ ] Task 9: Add `starter-kit|sk` route to `scripts/sw` CLI router
- [ ] Task 10: Create `scripts/sw-starter-kit-test.sh` with tests for all 5 frameworks + edge cases
- [ ] Task 11: Register test in `package.json` test chain
- [ ] Task 12: Run full test suite to verify no regressions
- [ ] `shipwright starter-kit generate` works end-to-end for Node.js, Python, Go, Rust, Ruby projects
- [ ] CLAUDE.md is enhanced with framework-specific conventions, pitfalls, and quality guidance
- [ ] 3-5 example issue templates generated per project in `.github/ISSUE_TEMPLATE/`
- [ ] Quality checks JSON generated with framework-appropriate commands
- [ ] `shipwright starter-kit check` reports setup completeness
- [ ] All new tests pass (`scripts/sw-starter-kit-test.sh`)
- [ ] Full test suite passes (`npm test`) — no regressions
- [ ] CLI router updated — `shipwright starter-kit` and `shipwright sk` work

## Notes
- Generated from pipeline plan at 2026-04-03T18:34:20Z
- Pipeline will update status as tasks complete
