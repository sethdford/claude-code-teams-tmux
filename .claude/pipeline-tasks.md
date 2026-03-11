# Pipeline Tasks — Pipeline Success Rate Emergency Mode - Auto-Activate Conservative Limits When Success Rate Collapses

## Implementation Checklist
- [ ] Task 1: Add emergency mode defaults to `config/defaults.json`
- [ ] Task 2: Add emergency event types to `config/event-schema.json`
- [ ] Task 3: Create `scripts/lib/daemon-emergency.sh` with core functions (check, activate, deactivate, is_active, load_state, get_ceiling)
- [ ] Task 4: Integrate emergency ceiling into `daemon_auto_scale()` in `scripts/lib/daemon-poll.sh`
- [ ] Task 5: Add emergency check hook into `daemon_check_degradation()` in `scripts/lib/daemon-poll-health.sh`
- [ ] Task 6: Add periodic emergency check to poll loop in `scripts/lib/daemon-poll.sh`
- [ ] Task 7: Source daemon-emergency.sh and add startup state loading in `scripts/sw-daemon.sh`
- [ ] Task 8: Add `emergency` CLI subcommand to `scripts/sw-daemon.sh`
- [ ] Task 9: Show emergency state in `scripts/sw-status.sh` dashboard
- [ ] Task 10: Create test suite `scripts/sw-emergency-mode-test.sh` with 13 test cases
- [ ] Task 11: Register test in `package.json`
- [ ] Task 12: Run full test suite and fix any regressions
- [ ] Emergency mode activates automatically when rolling success rate ≤ 30% (configurable)
- [ ] Emergency mode reduces MAX_PARALLEL to MIN_WORKERS
- [ ] Emergency mode forces "full" template with compound_quality
- [ ] Emergency mode increases MAX_RETRIES to at least 3
- [ ] Emergency mode deactivates after success rate ≥ 60% sustained for 3 consecutive checks
- [ ] Hysteresis prevents oscillation (30% activate / 60% deactivate)
- [ ] Emergency state persists via flag file across daemon restarts
- [ ] Emergency state auto-expires after configurable duration (default 2h)

## Context
- Pipeline: autonomous
- Branch: ci/issue-251
- Issue: none
- Generated: 2026-03-11T01:01:59Z
