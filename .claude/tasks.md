# Tasks — Stage Output Schema Validator & Contract Enforcement

## Status: In Progress
Pipeline: standard | Branch: arch/stage-output-schema-validator-contract-e-669

## Checklist
- [ ] Task 1: Create 14 stage output schema files (config/stage-schemas/*.json)
- [ ] Task 2: Implement scripts/lib/validate.sh with core validation functions
- [ ] Task 3: Implement sw-validate-stage-output.sh as CLI entry point
- [ ] Task 4: Integrate validation into pipeline-stages.sh execution flow
- [ ] Task 5: Create comprehensive test suite sw-validate-stage-output-test.sh
- [ ] Task 6: Update package.json to register validation test suite
- [ ] Task 7: Update .claude/CLAUDE.md with validation documentation
- [ ] Task 8: Add validation configuration section to daemon-config.json
- [ ] Task 9: Manual end-to-end testing of validation in real pipeline
- [ ] Task 10: Add validation integration tests to sw-pipeline-test.sh
- [ ] Task 11: Verify all existing tests pass (npm test)
- [ ] Task 12: Create example documentation for adding new stage schemas
- [x] All 14 pipeline stages have JSON schemas in `config/stage-schemas/`
- [x] Schemas follow JSON Schema draft 2020-12 standard with `$schema` and `$id`
- [x] `validate_stage_output()` function exists and validates artifacts against schemas
- [x] Validation runs after each stage completion in pipeline execution
- [x] Invalid artifacts are detected and reported with clear error messages
- [x] Error messages show expected schema vs. actual artifact structure
- [x] Validation failures can be configured to fail (strict mode) or warn (default)
- [x] Validation metrics recorded to `~/.shipwright/validation-metrics.jsonl`

## Notes
- Generated from pipeline plan at 2026-06-19T19:07:22Z
- Pipeline will update status as tasks complete
