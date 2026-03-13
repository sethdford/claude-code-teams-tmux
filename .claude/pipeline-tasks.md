# Pipeline Tasks — Success Pattern Capture and Proven Configuration Replay System

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/proven-configs.sh` with core functions (capture, match, apply, track, prune, list, stats, scoring)
- [ ] Task 2: Create `scripts/sw-proven-configs.sh` CLI command with subcommands (list, show, match, stats, prune, reset, help)
- [ ] Task 3: Source `lib/proven-configs.sh` from pipeline-stages loader so it's available during pipeline execution
- [ ] Task 4: Integrate proven config capture into `scripts/lib/pipeline-commands.sh` after successful pipeline completion
- [ ] Task 5: Integrate proven config lookup into `scripts/lib/pipeline-stages-intake.sh` during intake stage
- [ ] Task 6: Integrate replay outcome tracking into `scripts/lib/pipeline-commands.sh` at pipeline finalization
- [ ] Task 7: Register `proven-configs` subcommand in `scripts/sw` CLI router
- [ ] Task 8: Create `scripts/sw-proven-configs-test.sh` test suite with 16 test cases
- [ ] Task 9: Register test suite in `package.json`
- [ ] Task 10: Run test suite and fix any failures
- [ ] `scripts/lib/proven-configs.sh` exists with all documented functions
- [ ] `scripts/sw-proven-configs.sh` exists with all subcommands (list, show, match, stats, prune, reset, help)
- [ ] `shipwright proven-configs help` shows usage and exits 0
- [ ] `shipwright proven-configs list` works on empty repo (shows "no configs")
- [ ] Successful pipeline completion creates a proven config entry in `~/.shipwright/proven-configs/<repo-hash>/configs.jsonl`
- [ ] Pipeline intake consults proven configs and applies matching config when available
- [ ] Replay outcomes are tracked and confidence scores updated after each replay
- [ ] Configs with replay success rate <40% after 5+ replays are automatically demoted
- [ ] `shipwright proven-configs prune` removes stale configs
- [ ] Test suite has 16 test cases, all passing

## Context
- Pipeline: autonomous
- Branch: ci/issue-257
- Issue: none
- Generated: 2026-03-13T18:56:55Z
