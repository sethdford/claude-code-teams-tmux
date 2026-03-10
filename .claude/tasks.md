# Tasks — Misleading "jq not available" warning when Claude outputs JSON object instead of array

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-242

## Checklist
- [x] Task 1: Extend Case 2 condition to match both `[` and `{` first characters
- [x] Task 2: Add branching jq extraction logic for array vs object JSON
- [x] Task 3: Add `.content` fallback path for object JSON (parallel to array fallback)
- [x] Task 4: Update comments to reflect new behavior
- [x] Task 5: Add test case for JSON object with `.result` field extraction
- [x] Task 6: Add test case for JSON object without `.result` field (fallback behavior)
- [x] Task 7: Run existing test suite to verify no regressions
- [x] JSON object `{"type":"result","result":"Hello"}` extracts "Hello" (not raw JSON)
- [x] JSON array `[{"type":"result","result":"Hello"}]` still extracts "Hello" (no regression)
- [x] When jq IS available and input is `{...}`, no "jq not available" warning is printed
- [x] When jq is NOT available, the warning accurately says "jq not available"
- [x] Plain text pass-through still works
- [x] Empty file handling still works
- [x] All existing tests pass (68/68)
- [x] New test cases for JSON object extraction pass (3/3)

## Notes
- Generated from pipeline plan at 2026-03-10T12:00:32Z
- Pipeline will update status as tasks complete
