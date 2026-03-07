## Pipeline Stall Detection Patterns

### What Makes a Build Stuck

Distinguish between:
- **Slow but healthy**: Making progress (file changes, new errors explored, test count improving)
- **Stuck deadlock**: Repeating the same state with no forward motion

### Progress Indicators

#### 1. File Change Delta
```
track: set of files modified in iteration N
stall_signal: if file_delta[i] == {} for 3+ consecutive iterations
risk: generated files, cache directories — must filter
```

#### 2. Error Signature Hashing
```
hash_error(msg):
  - strip timestamps, line numbers, dynamic values
  - compare error_hash[i] across iterations
deadlock_signal: if error_hash[i] == error_hash[i-1] == error_hash[i-2] for 5+ iterations
risk: similar but different errors (e.g., "timeout at line 42" vs "timeout at line 50")
```

#### 3. Test Result Delta
```
track: pass_count, fail_count, error_set per iteration
stall_signal: if pass_count[i] == pass_count[i-1] AND fail_set[i] == fail_set[i-1] for N iterations
```

### Safe Abort Procedure

1. **Preserve state**: Don't discard progress.md or recent commits
2. **Capture diagnostics**: What iteration? What errors? What file changes were attempted?
3. **Save to memory**: Append to memory system with stall pattern and context
4. **Signal daemon**: Mark job with `stall_detected` reason (not a code error)
5. **Suggest recovery**: Output actionable next steps (manual intervention? test isolation?)

### Integration with Daemon Retry

When daemon sees `stall_detected`:
- Increment `max_restarts` for retry (fresh session may unstick)
- Inject memory context into next attempt
- Log stall pattern for aggregate analysis
- If stalls persist across restarts → escalate to human

### False Positive Prevention

- **Whitelist safe iterations**: Some tests legitimately produce no file changes (e.g., type checking)
- **Time-based grace period**: Don't abort in first 2 iterations (setup/analysis phase)
- **Error uniqueness**: Count *unique* errors, not raw count
- **Diff accuracy**: Use `git diff --name-only` to avoid counting generated files

### Dashboard Representation

- Show iteration timeline with file change bars
- Highlight error signature patterns
- Display stall detection threshold (e.g., "3 of 3 iterations, 0 file changes")
- Show previous stalls from memory system
