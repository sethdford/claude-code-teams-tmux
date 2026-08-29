# Pipeline Tasks — Split sw-loop.sh's Iteration/Prompt-Composition Logic into scripts/lib/loop-*.sh

## Implementation Checklist
- [ ] `scripts/lib/loop-orchestration.sh` created and contains `run_single_agent_loop`, `run_loop_with_restarts`, diagnostic functions
- [ ] `scripts/lib/loop-prompts.sh` created and contains all `compose_*` functions
- [ ] Both files have module guards and are properly sourced by sw-loop.sh
- [ ] All existing tests pass (`npm test`)
- [ ] `sw-loop-test.sh` passes unmodified
- [ ] `shipwright loop` works with all flag combinations
- [ ] No behavior changes to iteration logic or prompt building
- [ ] `shellcheck` passes for all new files (Bash 3.2 compatible)
- [ ] No `set -euo pipefail` violations
- [ ] Proper error handling preserved
- [ ] Module structure matches existing patterns
- [ ] sw-loop.sh reduced to ~1200 lines (target 55% reduction from 2713)
- [ ] Clear separation: CLI entry points (sw-loop.sh) vs. core loop logic (libs)
- [ ] Dependency graph is acyclic and documented
- [ ] Comments added to extracted functions if logic is non-obvious
- [ ] Function dependencies documented at module top
- [ ] No lost institutional knowledge in refactoring
- [ ] Analyze run_single_agent_loop dependencies (grep for calls, trace to origins)
- [ ] Analyze compose_* function dependencies  
- [ ] Draw/document dependency diagram (ASCII in plan or comment)

## Context
- Pipeline: autonomous
- Branch: ci/issue-3240
- Issue: none
- Generated: 2026-08-29T04:40:22Z
