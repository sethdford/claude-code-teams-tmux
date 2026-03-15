# Pipeline Tasks — daemon-config.json Schema Validator with Startup Check

## Implementation Checklist
- [ ] Task 1: Write `config/daemon-config.schema.json` with complete property definitions
- [ ] Task 2: Implement `_validate_json_schema()` in lib/config-validate.sh (core validation)
- [ ] Task 3: Implement `_validate_daemon_config()` in lib/config-validate.sh (daemon-specific)
- [ ] Task 4: Implement error reporting functions in lib/config-validate.sh
- [ ] Task 5: Source config-validate.sh in sw-daemon.sh and call validation early
- [ ] Task 6: Add SKIP flag support for optional validation bypass
- [ ] Task 7: Write test suite covering valid/invalid configs
- [ ] Task 8: Test daemon startup with invalid config (should fail gracefully)
- [ ] Task 9: Test daemon startup with valid config (should succeed)
- [ ] Task 10: Test schema file missing scenario
- [ ] Task 11: Documentation — add schema validation to CLAUDE.md comment block
- [ ] Task 12: Verify all existing test suites still pass

## Context
- Pipeline: autonomous
- Branch: ci/issue-279
- Issue: none
- Generated: 2026-03-15T09:12:32Z
