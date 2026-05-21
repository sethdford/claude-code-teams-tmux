# Tasks — Success Pattern Injection Engine for Failing Builds

## Status: In Progress
Pipeline: standard | Branch: ci/success-pattern-injection-engine-for-fai-513

## Checklist
- [ ] Task 1: Create `scripts/lib/success-patterns.sh` skeleton with `VERSION`, `set -euo pipefail`, helpers, `sp_*` stubs.
- [ ] Task 2: Implement `sp_load_patterns` with corrupt/missing JSON guard and lazy id backfill.
- [ ] Task 3: Implement scoring components (title Jaccard, file overlap, error-sig hit-ratio).
- [ ] Task 4: Implement `sp_top_k` with `similarity_threshold` and `max_inject`.
- [ ] Task 5: Implement `sp_render_injection` with char/line caps and `injection_id`.
- [ ] Task 6: Wire injection into `sw-loop.sh` at iteration 1 and on test-fail re-entry; stamp `injection_id`.
- [ ] Task 7: Wire `sp_record_outcome` into `memory_finalize_pipeline`; detect acknowledged flag.
- [ ] Task 8: Build CLI wrapper `sw-success-patterns.sh`; register in `scripts/sw` router.
- [ ] Task 9: Add config defaults to `daemon-config.json`; read via `_smart_*`.
- [ ] Task 10: Implement `sp_effectiveness_report` (JSON output for dashboard).
- [ ] Task 11: Write `sw-success-patterns-test.sh` covering scoring, thresholds, empty/malformed corpus, JSONL atomicity, char cap, deterministic ids.
- [ ] Task 12: Register test in `package.json`; run `shipwright docs sync`; confirm `shipwright doctor` clean.
- [ ] Task 13: Benchmark 500-pattern scoring < 500ms; capture in test output.
- [ ] `scripts/lib/success-patterns.sh` implemented, Bash 3.2 compatible, `set -euo pipefail` clean.
- [ ] CLI `shipwright success-patterns {index,score,inject,report,forget}` working end-to-end.
- [ ] `sw-loop.sh` injects top-3 patterns at iteration 1 and on test-fail re-entry; `injection_id` recorded in pipeline state.
- [ ] `memory_finalize_pipeline` writes outcome JSONL via `sp_record_outcome` with `acknowledged` flag.
- [ ] Config keys readable via `_smart_*`; kill switch flips engine to no-op without code change.
- [ ] Test suite passes; registered in `package.json`; ≥10 cases including empty/malformed/concurrent/boundary.
- [ ] Benchmark: 500-pattern corpus scored in <500ms (recorded in test output).

## Notes
- Generated from pipeline plan at 2026-05-21T18:59:44Z
- Pipeline will update status as tasks complete
