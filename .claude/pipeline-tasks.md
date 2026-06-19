# Pipeline Tasks — Fleet-Wide Pattern Mining & Knowledge Transfer Engine

## Implementation Checklist
- [ ] Task 1: Scaffold `sw-knowledge.sh` with house boilerplate + `VERSION=3.3.0`
- [ ] Task 2: Implement `ensure_knowledge_file`, `km_atomic_write`, `km_signature`, `km_iter_repos`
- [ ] Task 3: Implement `cmd_mine` (extract → group by signature → score confidence → atomic write)
- [ ] Task 4: Implement `cmd_transfer` (additive promotion into `global.json`, capped/deduped)
- [ ] Task 5: Implement `cmd_inject` (Jaccard tag ranking → injectable context, bump metrics)
- [ ] Task 6: Implement `cmd_search`, `cmd_show`, `cmd_report`, `show_help`
- [ ] Task 7: Implement `main()` case dispatch with unknown-command handling
- [ ] Task 8: Register `knowledge|mine` subcommand in `scripts/sw`
- [ ] Task 9: Write `sw-knowledge-test.sh` (cross-repo collapse, confidence bounds, inject, transfer, malformed input)
- [ ] Task 10: Register test in `package.json` `test` script
- [ ] Task 11: `shipwright docs sync` + add Fleet Knowledge doc note
- [ ] Task 12: Run `npm test`; verify all suites pass (acceptance criterion)
- [ ] `scripts/sw-knowledge.sh` exists, executable, `set -euo pipefail`, `VERSION` matches `package.json`.
- [ ] `shipwright knowledge mine` produces a valid `~/.shipwright/memory/fleet-knowledge.json`; cross-repo patterns merge by signature with correct `repo_count`/`total_occurrences`.
- [ ] `shipwright knowledge inject <task_type>` emits ranked, relevant injectable context; `transfer` updates `global.json` additively.
- [ ] `knowledge` (and `mine` alias) dispatch correctly from `scripts/sw`.
- [ ] `sw-knowledge-test.sh` passes and is registered in `package.json`.
- [ ] All writes atomic (tmp + `mv`); any GitHub-touching code (none expected) guarded by `NO_GITHUB`; all `jq` uses `--arg`.
- [ ] No Bash 3.2 violations.
- [ ] `npm test` is green — **all existing tests continue to pass** (spec acceptance criterion).

## Context
- Pipeline: autonomous
- Branch: ci/issue-668
- Issue: none
- Generated: 2026-06-19T14:13:01Z
