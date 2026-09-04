# Pipeline Tasks — Split sw-loop.sh (2713 lines) Into build-loop-core / build-loop-restart / build-loop-context Modules

## Implementation Checklist
- [ ] Task 1: Capture baseline — test PASS/FAIL counts, `bash -n`, pinned-shellcheck output, `--help` golden hash
- [ ] Task 2: Create three module files with `_BUILD_LOOP_*_LOADED` guards and headers
- [ ] Task 3: Move the 12 `build-loop-context.sh` functions; add source line; verify
- [ ] Task 4: Move the 14 `build-loop-core.sh` functions (incl. `run_single_agent_loop`); verify
- [ ] Task 5: Move the 7 `build-loop-restart.sh` functions (incl. `generate_worker_script` heredoc); verify
- [ ] Task 6: Consolidate all scattered globals; assert global-set diff is empty; keep `trap cleanup` after sourcing
- [ ] Task 7: Delete orphaned section-header comments left by this and prior extraction passes
- [ ] Task 8: Run pinned shellcheck v0.11.0 with CI flags; resolve SC2154 per-module, not repo-wide
- [ ] Task 9: Retarget 11 greps + 3 `sed` extractions in `sw-loop-test.sh`
- [ ] Task 10: Write `scripts/sw-build-loop-modules-test.sh` (unit + structural assertions)
- [ ] Task 11: Register the new suite in `package.json`
- [ ] Task 12: Verify `sw-pipeline-test.sh` mock-`sw-loop.sh` path still works (modules must be optional)
- [ ] Task 13: Run `npm test`; compare to Task 1 baseline — counts must be equal or higher, zero new failures
- [ ] Task 14: `shipwright docs sync` for the `AUTO:core-scripts` line count; `shipwright version check`
- [ ] Task 15: Confirm `sw-loop.sh` ≤ 600 lines and each module ≤ 1100 lines
- [ ] `scripts/sw-loop.sh` ≤ 600 lines, contains only shebang/traps/sourcing/globals/`VERSION`/`show_help`/argparse/validation/`main`
- [ ] `build-loop-core.sh`, `build-loop-restart.sh`, `build-loop-context.sh` exist, each with a module guard, each ≤ 1100 lines
- [ ] Every one of the 33 moved functions passes the byte-level `diff` check (Testing step 1)
- [ ] Global-declaration set of `sw-loop.sh` is unchanged (empty sorted diff)
- [ ] `--help` output byte-identical to baseline

## Context
- Pipeline: autonomous
- Branch: ci/issue-3936
- Issue: none
- Generated: 2026-09-04T01:12:32Z
