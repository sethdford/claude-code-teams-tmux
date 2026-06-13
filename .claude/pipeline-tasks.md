# Pipeline Tasks — Decompose sw-loop.sh into Modular Components (Execution)

## Implementation Checklist
- [ ] Task 1: Capture baseline PASS count from `./scripts/sw-loop-test.sh` + clean `bash -n`.
- [ ] Task 2: Create `lib/loop-prompts.sh` (guard + doc) with `compose_*` + `write_error_summary` + relocated `compose_prompt`.
- [ ] Task 3: Create `lib/loop-context.sh` (guard + doc) with `manage_context_window`, git tracking, new `inject_memory_context()`.
- [ ] Task 4: Add `format_duration()` to `lib/compat.sh`; remove from `sw-loop.sh`.
- [ ] Task 5: Relocate `run_single_agent_loop`, `run_test_gate`, `diagnose_failure`, `run_audit_agent`, and gates to `lib/loop-iteration.sh`.
- [ ] Task 6: Relocate `show_help`, banners, multi-agent + restart helpers, model/budget selectors out of `sw-loop.sh`.
- [ ] Task 7: Remove `manage_context_window`/`compose_prompt` from `loop-iteration.sh`; update its header doc.
- [ ] Task 8: Add `source` lines for the two new libs in `sw-loop.sh`; verify source order before `main()`.
- [ ] Task 9: Confirm test-pinned primitives + CLI flags + token-accounting strings remain in `sw-loop.sh`.
- [ ] Task 10: Apply dual-path grep updates to ~9 location tests (if Decision Point approved).
- [ ] Task 11: `bash -n` + `shellcheck` all touched files; verify Bash 3.2 compatibility.
- [ ] Task 12: Add inline documentation to every new lib module and function.
- [ ] Task 13: Sync `core-scripts` AUTO docs section in `.claude/CLAUDE.md`.
- [ ] Task 14: `wc -l scripts/sw-loop.sh` < 500 (primary path); full `sw-loop-test.sh` passes with no regressions.
- [ ] `lib/loop-context.sh` and `lib/loop-prompts.sh` created, sourced, documented.
- [ ] Ownership matches charter: context-window mgmt in `loop-context`, prompt composition in
- [ ] `lib/compat.sh` gains the shared `format_duration()` util.
- [ ] `scripts/sw-loop.sh` < 500 lines (primary path), containing only orchestration +
- [ ] `./scripts/sw-loop-test.sh` passes; no assertion's intent changed (only dual-path
- [ ] No functional changes — diff shows relocation + wiring + docs only.

## Context
- Pipeline: standard
- Branch: refactor/decompose-sw-loop-sh-into-modular-compon-641
- Issue: #641
- Generated: 2026-06-13T08:14:17Z
