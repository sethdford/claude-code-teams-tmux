# Tasks — Misleading "jq not available" warning when Claude outputs JSON object instead of array

## Status: In Progress
Pipeline: autonomous | Branch: fix/misleading-jq-not-available-warning-when-242

## Checklist
- [ ] Task 1: Extend Case 2 condition to match both `[` and `{` first characters
- [ ] Task 2: Add branching jq extraction logic for array vs object JSON
- [ ] Task 3: Add `.content` fallback path for object JSON (parallel to array fallback)
- [ ] Task 4: Fix Case 3 warning message to check jq availability and show accurate message
- [ ] Task 5: Add test case for JSON object with `.result` field extraction
- [ ] Task 6: Add test case for JSON object without `.result` field (fallback behavior)
- [ ] Task 7: Run existing test suite to verify no regressions
- [ ] JSON object `{"type":"result","result":"Hello"}` extracts "Hello" (not raw JSON)
- [ ] JSON array `[{"type":"result","result":"Hello"}]` still extracts "Hello" (no regression)
- [ ] When jq IS available and input is `{...}`, no "jq not available" warning is printed
- [ ] When jq is NOT available, the warning accurately says "jq not available"
- [ ] Plain text pass-through still works
- [ ] Empty file handling still works
- [ ] All existing tests pass
- [ ] New test cases for JSON object extraction pass

## Notes
- Generated from pipeline plan at 2026-03-10T06:17:32Z
- Pipeline will update status as tasks complete
