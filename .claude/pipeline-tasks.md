# Pipeline Tasks — Script Complexity Doctor Check with Refactor Suggestions

## Implementation Checklist
- [ ] `scripts/lib/complexity-analyzer.sh` created and unit tested
- [ ] `scripts/sw-complexity.sh` CLI command working with --all, --recursive, --json flags
- [ ] Can analyze all 100+ scripts without errors
- [ ] Identifies 5+ distinct anti-patterns from Common Pitfalls
- [ ] Detects and flags 10+ scripts with refactor opportunities
- [ ] Doctor integration shows complexity section without breaking other checks
- [ ] JSON report matches schema (script, metrics, complexity, violations)
- [ ] Performance acceptable: `--all` completes in <30 seconds (with caching)
- [ ] Test suite covers unit + integration cases, all passing
- [ ] Manual verification of top 5 recommendations are sound
- [ ] Documentation updated: CLAUDE.md AUTO section + CLI help
- [ ] No regressions in existing doctor functionality

## Context
- Pipeline: autonomous
- Branch: ci/issue-272
- Issue: none
- Generated: 2026-03-14T20:07:19Z
