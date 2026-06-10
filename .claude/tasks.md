# Tasks — Fallback Policy Migrator — Convert 67 Static Fallbacks to Config-Driven Adaptive Overrides

## Status: In Progress
Pipeline: standard | Branch: refactor/fallback-policy-migrator-convert-67-stat-620

## Checklist
- [ ] T1: Implement `_fallback_audit`, generate inventory JSONL, select top 20 tunable fallbacks
- [ ] T2: Write `config/fallback-policy.schema.json`
- [ ] T3: Write `config/fallback-policy.json` with 20 policies (`learning_enabled:false`)
- [ ] T4: Implement `_smart_fallback` + `_fallback_clamp` in `scripts/lib/fallback-policy.sh`
- [ ] T5: Implement `scripts/sw-fallback.sh` (audit/inventory/list/validate) + register `fallback)` in `scripts/sw`
- [ ] T6: Add adaptive-override writer bridge to `scripts/sw-adaptive.sh`
- [ ] T7: Migrate the top-20 call-sites to `_smart_fallback` (behavior-preserving)
- [ ] T8: Write `scripts/sw-fallback-policy-test.sh`, register in `package.json`
- [ ] T9: Document Fallback Policy System in `.claude/CLAUDE.md`; commit generated skill doc
- [ ] T10: Run `shipwright fallback validate`, `npm test`, `shipwright doctor` — all green
- [ ] Audit produces a complete fallback inventory (`file,line,variable,default,context`).
- [ ] `config/fallback-policy.json` + schema exist and validate; 20 high-impact fallbacks declared.
- [ ] `_smart_fallback` resolves the documented 4-tier precedence and clamps to bounds.
- [ ] Top 20 call-sites migrated; behavior **unchanged** when no config/override present (proven by regression test).
- [ ] Adaptive bridge writes learned overrides only when confident; learning defaults **off**.
- [ ] `.claude/CLAUDE.md` documents the system with schema + examples; `shipwright fallback` discoverable.
- [ ] New test suite registered and passing; `npm test` and `shipwright doctor` green.

## Notes
- Generated from pipeline plan at 2026-06-10T14:02:16Z
- Pipeline will update status as tasks complete
