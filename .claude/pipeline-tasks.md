# Pipeline Tasks — Automated Tech Stack Example Repository Generator for Adoption Showcase

## Implementation Checklist
- [ ] Task 1: Create `scripts/sw-showcase.sh` skeleton (shebang, pipefail, VERSION, usage)
- [ ] Task 2: Implement argument parsing with validation
- [ ] Task 3: Implement pre-flight + force-overwrite guard
- [ ] Task 4: Implement Node stack writer (atomic, jq-built JSON)
- [ ] Task 5: Implement Python stack writer
- [ ] Task 6: Implement Go stack writer
- [ ] Task 7: Implement common file writer (.claude/, README, .gitignore)
- [ ] Task 8: Add `emit_event` and success summary
- [ ] Task 9: Wire `showcase` subcommand into `scripts/sw` router
- [ ] Task 10: Create `scripts/sw-showcase-test.sh` with ≥6 PASS/FAIL cases
- [ ] Task 11: Register test in `package.json` test chain
- [ ] Task 12: Run `npm test` locally, fix regressions
- [ ] Task 13: Run `shipwright docs sync` to update AUTO sections
- [ ] `shipwright showcase --help` prints usage
- [ ] `shipwright showcase --stack node --out /tmp/sw-demo` writes ≥6 files
- [ ] Generated `package.json` parses with `jq`
- [ ] Refuses overwrite without `--force`; honors `--force`
- [ ] All three stacks (node, python, go) supported
- [ ] `scripts/sw-showcase-test.sh` passes with PASS=N, FAIL=0
- [ ] `npm test` exits 0

## Context
- Pipeline: autonomous
- Branch: ci/issue-441
- Issue: none
- Generated: 2026-05-07T20:52:07Z
