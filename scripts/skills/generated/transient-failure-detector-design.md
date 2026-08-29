## Transient Failure Detection & Backoff Strategy

### Identifying Transient Signatures
Transient infrastructure errors are temporary, retryable, and indicate no code change is needed. Distinguish these from code/test failures:

**HTTP/Network Signatures:**
- Exit code 28: curl timeout (OPERATION_TIMEDOUT)
- Exit code 35: SSL/TLS connection reset (SSL_CONNECT_ERROR)
- Exit code 52: empty HTTP response (NO_CONTENT_LENGTH)
- HTTP 429: rate-limit (check response headers for Retry-After)
- HTTP 503: service unavailable (transient)
- "Connection reset by peer" / "No route to host" in stderr

**Auth Signatures:**
- "401 Unauthorized" with Auth-related headers (token expired)
- "credentials expired" in stderr
- EACCES on GitHub API calls

**Test Infrastructure:**
- "Timeout waiting for..." in test runner output
- "ECONNREFUSED" from database/cache connections
- "Port already in use" (flaky test isolation)

### Backoff Strategy (Without Iteration Cost)
```
Backoff(attempt) = min(base * (multiplier ^ attempt), max_delay) + jitter
Defaults: base=100ms, multiplier=2, max_delay=30s, jitter=±10%
Max retries: 5 for transient, fail after that
```

**Critical:** Transient retries must:
- NOT increment loop iteration counter (stays at N for user's mental model)
- NOT consume restart budget (detected before restart logic)
- Record retry count in error-summary.json under `transient_retries` field
- Log backoff delay and attempt number for debugging

### Backoff Placement in Build Loop
```
1. Command fails (exit code X)
2. Check exit code/stderr against transient signatures
3. If transient detected:
   a. Calculate backoff delay
   b. Sleep + retry (loop 5 times max)
   c. Record in error-summary.json: {"classification": "transient_infra", "retries": N}
   d. If retries exhausted, fall through to normal classification
4. If NOT transient:
   a. Proceed to existing code-error classification logic
   b. Record in error-summary.json: {"classification": "code_error"}
```

### false-Positive Prevention
- Never classify test output with actual failures (FAILED, AssertionError) as transient
- Never classify compilation errors or syntax errors as transient
- Transient check must happen on COMMAND exit code + stderr, not test output parsing
- Add an explicit allowlist: only known transient signatures trigger backoff, not catch-all patterns

### error-summary.json Schema Update
```json
{
  "classification": "transient_infra|code_error",
  "transient_retries": 3,
  "backoff_final_delay_ms": 8000,
  "signature_matched": "http_429",
  "error_snippet": "Rate limit exceeded..."
}
```

### Testing Checklist
- Unit test: HTTP 429 detected as transient, retried up to 5 times
- Unit test: ECONNREFUSED detected as transient
- Unit test: Timeout (exit 28) detected as transient
- Unit test: Auth-expired (401) detected as transient
- Unit test: Actual test failure (FAILED in output) NOT misclassified as transient
- Integration test: Transient backoff doesn't increment loop iteration counter
- Integration test: Transient backoff doesn't consume restart budget
- Edge case: Transient detected on iteration 10, retries 3 times and succeeds → iteration count stays 10
