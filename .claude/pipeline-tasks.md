# Pipeline Tasks — Error Message Clarity Enhancement Pass for Top 5 Cryptic Errors

## Implementation Checklist
- [ ] 5 error messages enhanced with context, root cause, and next steps
- [ ] Before/after examples documented in a test suite
- [ ] All 102 test suites pass after enhancements
- [ ] Error messages appear correctly in failure scenarios
- [ ] No regression in script exit codes or side effects
- [ ] Task 1: Review error-message-clarity.md framework and extract template patterns
- [ ] Task 2: Read each of the 5 failing scripts to understand error context
- [ ] Task 3: Create test helper function to validate error messages appear correctly
- [ ] Task 4: Enhance sw-cleanup.sh --force output error (22 occurrences)
- [ ] Task 5: Enhance sw-feedback-test.sh JSON validation error (21 occurrences)
- [ ] Task 6: Enhance sw-hello-test.sh mktemp directory error (3 occurrences)
- [ ] Task 7: Enhance sw-code-review-test.sh sed -e flag error (2 occurrences)
- [ ] Task 8: Enhance sed quoting errors across test files (5 occurrences)
- [ ] Task 9: Run each affected test suite to confirm enhanced error messages appear
- [ ] Task 10: Run full test suite (npm test) to ensure no regressions
- [ ] Task 11: Document before/after examples for PR description
- [ ] All 5 error messages enhanced with three-part structure
- [ ] Enhanced messages preserve error codes for log parsing
- [ ] Enhanced messages fit in standard terminal width (80-100 chars)
- [ ] Each error message can be triggered in a test environment

## Context
- Pipeline: standard
- Branch: refactor/error-message-clarity-enhancement-pass-f-266
- Issue: #266
- Generated: 2026-03-14T21:21:00Z
