# Pipeline Tasks — Test Failure Git Bisection Tool with Automatic Root Cause Identification

## Implementation Checklist
- [ ] Task 1: Scaffold `scripts/sw-bisect.sh` header, VERSION, lib sourcing + fallbacks
- [ ] Task 2: Implement argument parser (`--good/--bad/--test-cmd/--json/--no-classify/-h`)
- [ ] Task 3: Implement pre-flight guards (git repo, dirty tree, ancestry, capture branch)
- [ ] Task 4: Install EXIT/INT/TERM trap that runs `git bisect reset` + branch restore
- [ ] Task 5: Generate atomic exit-code-mapping bisect wrapper script
- [ ] Task 6: Drive `git bisect start` + `git bisect run`, parse first-bad-commit SHA
- [ ] Task 7: Collect culprit metadata + capped diff
- [ ] Task 8: Integrate `root-cause.sh` classification + fix suggestion
- [ ] Task 9: Write `bisect-result.json` atomically with `jq -n --arg`
- [ ] Task 10: Human-readable boxed report + `--json` mode
- [ ] Task 11: `emit_event` observability + optional memory capture
- [ ] Task 12: Add `bisect)` router case + help text in `scripts/sw`
- [ ] Task 13: Write `scripts/sw-bisect-test.sh` with real-git repo fixture
- [ ] Task 14: Register test in `package.json`, update `.claude/CLAUDE.md`
- [ ] Task 15: `shellcheck` + `bash -n` + run suite; keep VERSION synced
- [ ] `shipwright bisect --good <ref> --bad <ref> --test-cmd "<cmd>"` finds the first
- [ ] Working tree and branch are restored on success, failure, AND interrupt.
- [ ] `.claude/pipeline-artifacts/bisect-result.json` written atomically with a valid
- [ ] Dirty-tree and non-git inputs rejected with actionable errors.
- [ ] `scripts/sw-bisect-test.sh` passes and is registered in `package.json`.

## Context
- Pipeline: autonomous
- Branch: ci/issue-726
- Issue: none
- Generated: 2026-07-03T14:47:59Z
