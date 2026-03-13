## Smoke Test Design for Infrastructure Validation

Smoke tests prove a system's essential functions work. For pipeline infrastructure, they differ fundamentally from unit tests:

### Core Design Principles

**1. Minimal Surface Area**
- Include only core machinery you're validating (file I/O, git operations, GitHub API)
- Exclude: business logic, optional features, environment setup
- Rationale: Smoke tests catch breakage fast; complexity hides real failures

**2. Real Environment, Never Mock**
- Use actual GitHub, actual git, actual filesystem
- Mocks hide environment-specific failures that smoke tests exist to catch
- This is the key difference from unit tests

**3. Observable Success Artifact**
- Create a durable proof that all machinery executed (file, commit, PR)
- Include timestamp to enable repeated runs without cleanup between iterations
- Success = artifact exists + contains expected data

**4. Fast Feedback Loop**
- Target: <7 min execution, <15 min timeout (leaves buffer for slowness)
- Long smoke tests defeat the purpose (delayed discovery of breakage)

**5. Reproducible Without Manual Intervention**
- Same input → same output every run
- Can run back-to-back without manual cleanup
- Timestamp handles file collision problem

### For This Issue: Implementation Checklist
- [ ] `minimal.json` template has single build stage with 10 min timeout
- [ ] Build goal creates `.claude/health-check-<ISO8601>.txt` with timestamp
- [ ] Artifact proves: file write succeeds → git add succeeds → git commit succeeds → PR opens
- [ ] No environment setup assumed beyond standard pipeline baseline
- [ ] Timeout leaves 3+ minute buffer (10 min timeout, expect <7 min execution)
- [ ] Document as smoke test in README with link from health-check flow
- [ ] Tested on actual repo with real GitHub token (not mocked)
- [ ] Verify: can run back-to-back 5 times without manual cleanup

### Common Failure Modes to Catch
- File already exists (use timestamp)
- Git not initialized in build directory
- GitHub token missing or invalid permissions
- PR creation fails on branch protection rules
- Build times out leaving incomplete state
