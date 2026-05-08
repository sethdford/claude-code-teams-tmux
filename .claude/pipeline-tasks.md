# Pipeline Tasks — Fleet-Wide Pattern Learning System for Cross-Repo Knowledge Sharing

## Implementation Checklist
- [ ] Task 1: Create `sw-fleet-patterns.sh` with VERSION, helpers, atomic store init
- [ ] Task 2: Implement schema versioned JSON store and `_ensure_store`
- [ ] Task 3: Implement `extract` reading events.jsonl + memory + git
- [ ] Task 4: Implement `query` with tech/issue/error similarity scoring
- [ ] Task 5: Implement `record-use` and effectiveness recomputation
- [ ] Task 6: Implement `prune` with age + low-success-rate eviction
- [ ] Task 7: Implement `stats` subcommand for dashboard
- [ ] Task 8: Hook into `sw-loop.sh` iteration prompt composition
- [ ] Task 9: Hook into `sw-intelligence.sh` cache enrichment
- [ ] Task 10: Hook post-success extraction in pipeline success path
- [ ] Task 11: Register `fleet-patterns` in `scripts/sw` router
- [ ] Task 12: Add dashboard `/api/fleet-patterns/stats` endpoint
- [ ] Task 13: Add dashboard widget (size, growth, effectiveness)
- [ ] Task 14: Write `sw-fleet-patterns-test.sh` with extract/query/effectiveness/prune cases
- [ ] Task 15: Update CLAUDE.md (Intelligence Layer + Fleet Mode + Runtime State + AUTO core-scripts)
- [ ] Task 16: Register test suite in `package.json`
- [ ] `sw fleet-patterns {extract,query,record-use,prune,stats}` all functional
- [ ] `~/.shipwright/fleet-patterns.json` created with versioned schema on first use
- [ ] Build loop queries patterns before strategic decisions (verified via prompt inspection)
- [ ] Intelligence engine enriches cache with matched patterns

## Context
- Pipeline: standard
- Branch: feat/fleet-wide-pattern-learning-system-for-c-461
- Issue: #461
- Generated: 2026-05-08T19:35:22Z
