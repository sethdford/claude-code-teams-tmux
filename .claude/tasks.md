# Tasks — Zero-Config Setup Wizard with Project Type Auto-Detection

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-724

## Checklist
- [ ] Task 1: Source `compat.sh` in `project-detect.sh`; fix `date -j` cache-age bug via `date_to_epoch`; make cache write atomic. **(blocks 3, 6)**
- [ ] Task 2: Add `project_detect_summary_line()` helper. **(blocks 3)**
- [ ] Task 3: Replace `sw-setup.sh` Phase-2 inline detector with `project_detect_all` + summary line; preserve no-detect fallback. **(needs 1, 2)**
- [ ] Task 4: Add `--yes`/`--zero-config`/`--non-interactive`/`--enable-daemon` flag parsing + `CI`/non-TTY implicit mode to `sw-setup.sh`; update `--help`.
- [ ] Task 5: Guard the daemon `read` prompt behind `NON_INTERACTIVE`. **(needs 4)**
- [ ] Task 6: Add `--from-detection <file>` to `sw-init.sh` with `jq` merge + atomic `mv`; no-op when absent. **(blocks 7)**
- [ ] Task 7: In `sw-setup.sh` Phase 3, pass `--from-detection` to `sw-init.sh`. **(needs 3, 6)**
- [ ] Task 8: Add `emit_event` calls for `setup_detected`/`setup_complete`.
- [ ] Task 9: Regression test in `sw-project-detect-test.sh` for Linux cache-age path + atomic write. **(needs 1)**
- [ ] Task 10: Extend `sw-setup-test.sh` — zero-config run completes with no prompt (`</dev/null` + timeout), detection persisted to `daemon-config.json`. **(needs 3, 5, 7)**
- [ ] Task 11: Unit test `sw-init.sh --from-detection` merges fields and is a no-op without the flag. **(needs 6)**
- [ ] Task 12: Update `.claude/CLAUDE.md`; run `shipwright version check` + `shipwright docs check`. **(needs all)**
- [ ] `shipwright setup --yes` completes with **zero interactive prompts**, exit 0, in a temp Node repo.
- [ ] Wizard detection is produced by `project-detect.sh` (inline duplicate detector removed).
- [ ] Detected `test_cmd`, `build_cmd`, and `pipeline_template` are persisted into `.claude/daemon-config.json`.
- [ ] `project-detect.sh` cache-age computation works on Linux (GNU date) — regression test passes; cache write is atomic.
- [ ] `sw-init.sh --from-detection` merges fields via `jq --arg` + atomic write, and is a no-op without the flag.
- [ ] All touched scripts remain `set -euo pipefail` and Bash 3.2 compatible.
- [ ] `emit_event` fires for `setup_detected` and `setup_complete`.
- [ ] `sw-setup-test.sh`, `sw-project-detect-test.sh`, `sw-init-test.sh` pass; `npm test` green.

## Notes
- Generated from pipeline plan at 2026-07-03T14:47:44Z
- Pipeline will update status as tasks complete
