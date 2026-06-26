# Tasks — Parallel Stage Execution Engine with Dependency Graph Scheduler

## Status: In Progress
Pipeline: standard | Branch: arch/parallel-stage-execution-engine-with-dep-696

## Checklist
- [ ] **Task 1:** Create `pipeline-dag.sh` skeleton (module guard, `VERSION`, `set -euo pipefail`, jq helpers).
- [ ] **Task 2:** Implement `dag_default_depends_on` (linear fallback). *Task 1 blocks Task 2; Task 2 blocks Tasks 4, 6, 12.*
- [ ] **Task 3:** Implement `dag_validate_acyclic` with cycle-path reporting + missing-dep error. *Task 3 blocks Tasks 8, 9.*
- [ ] **Task 4:** Implement `dag_compute_layers` (Kahn layering, stable within-layer order). *Needs Task 2; blocks Task 6.*
- [ ] **Task 5:** Create `pipeline-parallel.sh`; implement `parallel_partition` (whitelist + gate + mutating rules). *Needs Task 1.*
- [ ] **Task 6:** Implement `parallel_run_layer` (fan-out, concurrency cap, `wait`, failure propagation). *Needs Tasks 4, 5; blocks Task 8.*
- [ ] **Task 7:** Implement deterministic `parallel_merge_logs` + per-stage events/check-runs (`NO_GITHUB` guarded). *Needs Task 6.*
- [ ] **Task 8:** Integrate layered engine into `run_pipeline()` behind `SW_PARALLEL_STAGES`; force build/test/mutating/gated into singleton layers. *Needs Tasks 3, 6.*
- [ ] **Task 9:** Wire composer: default-deps on compose, acyclic check in `composer_validate_pipeline`, `composer layers` cmd, VERSION bump. *Needs Task 3.*
- [ ] **Task 10:** Add `depends_on` to `standard/full/autonomous` templates; validate via composer CLI. *Needs Task 9.*
- [ ] **Task 11:** Optional tmux pane mode (visualization, fallback-safe). *Needs Task 6; non-blocking for DoD.*
- [ ] **Task 12:** Write `sw-pipeline-dag-test.sh` (layering, cycles, wall-clock, determinism, failure, flag-off parity). *Needs Tasks 2, 4, 6.*
- [ ] **Task 13:** Register test in `package.json`; update `.claude/CLAUDE.md` (+ AUTO:test-suites via `docs sync`); sync VERSIONs. *Needs Task 12.*
- [ ] **Task 14:** Add a wall-clock benchmark assertion (mock stages with fixed sleeps) proving >30% reduction. *Needs Tasks 6, 12.*
- [ ] `pipeline-dag.sh` computes correct layers and rejects cycles with a clear path (unit-tested).
- [ ] `pipeline-parallel.sh` runs a layer's whitelisted stages concurrently, caps concurrency, and propagates the first failure after waiting all siblings.
- [ ] `run_pipeline()` waits only on real `depends_on` deps when `SW_PARALLEL_STAGES` is on; **byte-identical** sequential behaviour when off.
- [ ] Mutating (`build/merge/deploy/validate`) and `gate:approve` stages never share a layer.
- [ ] Wall-clock benchmark proves **>30%** reduction on a ≥3-parallel-stage mock template.
- [ ] `sw-pipeline-dag-test.sh` passes (layering, cycles, determinism, failure propagation, flag-off parity, wall-clock) and is registered in `package.json` + AUTO:test-suites.

## Notes
- Generated from pipeline plan at 2026-06-26T01:33:52Z
- Pipeline will update status as tasks complete
