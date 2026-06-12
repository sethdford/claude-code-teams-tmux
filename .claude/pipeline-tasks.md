# Pipeline Tasks — Dependency Pre-Flight Check & Auto-Install Engine

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/dependency-preflight.sh` skeleton (VERSION, load guard, defensive sourcing of `project-detect.sh`/`helpers.sh`)
- [ ] Task 2: Implement `dep_detect_manifests` with bounded `find` + node_modules/vendor exclusion (monorepo-aware) *(blocks Task 3,4,5)*
- [ ] Task 3: Implement `dep_manager_available` + per-manager mapping
- [ ] Task 4: Implement `dep_is_installed` heuristics for npm/pip/go/bundle/mvn
- [ ] Task 5: Implement `dep_install` with lockfile-deterministic commands in `( cd … )` subshells *(blocked by Task 2,3)*
- [ ] Task 6: Implement `dep_preflight_run` orchestrator: config gate, loop, aggregation, `SW_DEPS_PREINSTALLED`, atomic marker write *(blocked by Task 2-5)*
- [ ] Task 7: Add `emit_event "dependencies.installed"` calls with manager/count/duration_ms/status
- [ ] Task 8: Add `_smart_bool` helper to `scripts/lib/compat.sh`
- [ ] Task 9: Hook `dep_preflight_run` into `stage_build()` (guarded, non-fatal) + source module
- [ ] Task 10: Add `dependency_preflight` block to `.claude/daemon-config.json`
- [ ] Task 11: Create `scripts/sw-lib-dependency-preflight-test.sh` with missing-deps fixtures (Node fixture w/o node_modules)
- [ ] Task 12: Add unit tests: detection (each manager), availability skip, installed-detection, disabled-flag no-op, non-fatal install failure
- [ ] Task 13: Add integration test: temp Node project with deps in package.json but no node_modules → assert install attempted + event emitted + `SW_DEPS_PREINSTALLED=0`
- [ ] Task 14: Register test in `package.json`; run full `npm test` to confirm no regressions
- [ ] Task 15: Update `.claude/CLAUDE.md` config/flag docs; bump VERSION consistency
- [ ] `dependency-preflight.sh` created; sourced by `stage_build()` behind a `type`-guard; non-fatal on all failures
- [ ] Detects package.json / requirements.txt / go.mod / Gemfile / pom.xml (Node, Python, Go, Ruby, Java)
- [ ] Checks installed status before the build loop; auto-installs missing deps with the correct manager
- [ ] Each install wrapped in `timeout` and a `( cd … )` subshell; partial/failed install never aborts pipeline
- [ ] Emits `dependencies.installed` pipeline event (manager, count, duration_ms, status) via `emit_event`

## Context
- Pipeline: standard
- Branch: ci/dependency-pre-flight-check-auto-install-637
- Issue: #637
- Generated: 2026-06-12T19:26:25Z
