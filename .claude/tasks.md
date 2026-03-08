# Tasks — Pipeline Failure Auto-Diagnostic Report Generator

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-231

## Checklist
- [ ] Task 1: Create `scripts/sw-diagnostic.sh` with standard script boilerplate (header, VERSION, helpers, show_help, main dispatcher)
- [ ] Task 2: Implement `diagnostic_generate()` — error collection, pipeline state reading, root cause classification, error scoring
- [ ] Task 3: Implement `filter_secrets()` for redacting tokens/keys/passwords from report text
- [ ] Task 4: Implement `write_markdown_report()` with all 6 required sections
- [ ] Task 5: Implement `write_json_report()` using jq for safe JSON construction
- [ ] Task 6: Implement `generate_suggestions()` with category-specific rules + memory lookup
- [ ] Task 7: Implement `diagnostic_show`, `diagnostic_list`, `diagnostic_json` subcommands
- [ ] Task 8: Add auto-trigger hook in `mark_stage_failed()` in `scripts/lib/pipeline-state.sh` (3 lines, `|| true` guarded)
- [ ] Task 9: Register `diagnostic` command in `route_observe()` in `scripts/sw` (1 line)
- [ ] Task 10: Create `scripts/sw-diagnostic-test.sh` test suite with 15 test cases
- [ ] Task 11: Register test in `package.json` test chain
- [ ] Task 12: Run full test suite and fix any failures
- [ ] `scripts/sw-diagnostic.sh` exists with all subcommands (generate, show, list, json, help)
- [ ] Diagnostic report auto-generates on any pipeline stage failure via `mark_stage_failed()` hook
- [ ] Report contains all 6 required sections (Summary, Error Details, Context, Timeline, Reproduction, Suggestions)
- [ ] JSON companion file written alongside Markdown report
- [ ] Root cause classified with confidence score for all 8 failure categories
- [ ] 2-3 actionable suggestions generated per failure category
- [ ] Secrets filtered from all report output (GitHub tokens, API keys, Bearer tokens, passwords)
- [ ] Event `pipeline.failure_diagnostic` emitted on report generation

## Notes
- Generated from pipeline plan at 2026-03-08T07:19:44Z
- Pipeline will update status as tasks complete
