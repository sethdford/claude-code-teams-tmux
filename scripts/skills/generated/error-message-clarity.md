## Error Message Clarity & Actionability Framework

Well-designed error messages cut debugging time in half. Poor ones waste hours. Use this framework to transform cryptic errors into user-friendly debugging guides.

### The Three-Part Structure

Every enhanced error message should clearly answer:

**1. What Happened (specific condition, not generic label)**
- ❌ Bad: "Build failed"
- ✅ Good: "Convergence detector timed out waiting for LOOP_COMPLETE signal after 45 minutes in iteration 12 at line 487 of sw-loop.sh"
- Include: specific failure point, timing, context values

**2. Why It Happened (root cause or common causes)**
- ✅ "This usually happens when: detector process crashed, or stage timeout was too short, or convergence stuck in infinite loop"
- List causes in order of likelihood
- Omit if cause is obvious from condition

**3. What To Do (concrete, testable next steps)**
- ✅ Step 1 (diagnosis): `ps aux | grep convergence-detector` — verify process is running
- ✅ Step 2 (state review): Check `.claude/pipeline-state.md` for last known iteration
- ✅ Step 3 (recovery): `shipwright pipeline resume` — continue from checkpoint
- Escalation: "If still stuck after step 3, see troubleshooting at [wiki-link]"

### Design Rules

**Clarity**
- Start with the specific failure, then zoom out
- Use exact file paths and line numbers when available
- Include variable values (timeout 45m, iteration 12, status code 137)
- Avoid jargon; explain technical terms on first use

**Actionability**
- Every error must have at least one concrete action
- Actions must be testable (not "debug further" or "investigate")
- Order by likelihood and diagnostic value, not alphabetically
- Distinguish diagnosis steps (to understand) from recovery steps (to fix)

**Consistency**
- Use the same format for related errors across all scripts
- Timeout errors always include: duration, what was being waited for, typical causes
- Missing file errors always include: expected path, how it should have been created, verification command
- Process exit errors always include: exit code, last log output, retry command

**Parseability**
- Preserve error codes/types for log aggregation: `ERROR_CODE=LOOP_TIMEOUT_45M`
- Keep structured markers in consistent positions so alerts still work
- Test that existing log parsing/alerting doesn't break

### Validation Checklist

Before merging enhanced error messages:
- [ ] Would someone unfamiliar with this code understand what went wrong?
- [ ] Can the user perform at least one suggested next step immediately?
- [ ] Does the error include enough state context (not overly verbose, not missing details)?
- [ ] Are similar errors across different scripts using the same pattern?
- [ ] Can your log aggregation/alerting systems still parse the error?
- [ ] Does the error pinpoint the failure (line number, function, condition) not just the symptom?

### Common Error Patterns & Templates

**Timeout Errors:**
```
Timeout: [process/operation] did not complete after [duration]
Likely cause: [most common reason], [secondary reason]
Diagnose: [check command]
Recover: [restart/resume command]
Details: Expected completion by [milestone], last progress [state]
```

**Missing File/Dependency:**
```
[File/dependency] not found at [path]
Expected here because: [setup step that should have created it]
Fix: [specific install command or setup step]
Verify: [command to confirm file exists and is valid]
```

**Process Crash/Exit:**
```
[Process] exited with code [N] (meaning: [interpretation])
Last output: [last 2-3 lines of relevant log]
Typically caused by: [list 2-3 most likely issues]
Check: [diagnostic command to see what went wrong]
Retry: [command to restart]
```

**Resource Constraint (OOM, disk, timeout):**
```
[Resource] exhausted: [metric reached limit]
Current state: [amount used], limit [max]
Usually because: [common cause], [secondary cause]
Fix: [increase limit or optimize usage], then retry
Monitor: [command to watch resource during next attempt]
```

### Real Examples from Shipwright

**Before**: "SCRIPT_DIR corruption breaking all pipeline runs" ← Cryptic, no action
**After**: "SCRIPT_DIR environment variable is empty or corrupted. This breaks all pipeline operations because scripts cannot locate themselves. Fix: Restart your shell or run `export SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`. Verify: `echo $SCRIPT_DIR` should show the path to your scripts directory."

**Before**: "LOOP_COMPLETE signal not received" ← Missing context
**After**: "Convergence detector stopped but did not write LOOP_COMPLETE signal after 45 minutes. This happens when: (1) detector process crashed—check `ps aux | grep convergence`, (2) detector timed out waiting for convergence—review iterations in `.claude/pipeline-state.md`, or (3) signal file couldn't be written—check disk space. Next: `shipwright pipeline resume` to continue from checkpoint. If that fails, check pipeline-state.md for last error."

### Metrics to Track

Post-deployment, measure these DX improvements:
- Time from error message seen to problem fixed (should decrease)
- Support/debug questions about specific errors (should decrease)
- User success rate on first suggested action (should be >60%)
- Cases where users needed to read source code to understand error (should be ~0%)
