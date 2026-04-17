# Pipeline Tasks — Fleet-Wide Cross-Repo Learning Synchronization Engine

## Implementation Checklist
- [ ] T1 Scaffold lib
- [ ] T2 env/hash helpers
- [ ] T3 Broadcast (atomic + merge + retry + scrub)
- [ ] T4 Load/reindex with success filter
- [ ] T5 Record success + effectiveness wiring
- [ ] T6 Prune (30d archive)
- [ ] T7 Dashboard + metric emission
- [ ] T8 Capture hook
- [ ] T9 Injection hook
- [ ] T10 Fleet CLI subcommand
- [ ] T11 Daily prune tick
- [ ] T12 Unit tests (9 cases)
- [ ] T13 package.json
- [ ] T14 CLAUDE.md docs
- [ ] T15 Manual smoke
- [ ] `~/.shipwright/fleet-memory/` populated on capture in fleet mode
- [ ] Same-sig patterns from N repos → one file, `votes==N`
- [ ] Context bundle shows `[fleet]` entries when relevant
- [ ] `shipwright fleet memory dashboard` shows top-10 + adoption/reuse rates
- [ ] Aged entries (>30d, 0 successes) archived on prune

## Context
- Pipeline: standard
- Branch: arch/fleet-wide-cross-repo-learning-synchroni-388
- Issue: #388
- Generated: 2026-04-17T12:54:32Z
