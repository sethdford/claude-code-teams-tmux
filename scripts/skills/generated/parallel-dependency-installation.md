## Parallel Dependency Installation

Parallel installation of tmux, jq, gh, Claude CLI requires careful coordination to hit <5 min target while ensuring atomicity and recoverability.

### Safety Principles

1. **Atomic Operations**: Each dependency install is all-or-nothing; use temp directories + mv for atomic swaps
2. **Dependency Ordering**: Respect installation order (e.g., gh requires curl already present)
3. **Idempotency**: Detect already-installed tools, skip reinstall (check version compatibility)
4. **Rollback**: If one dep fails, don't fail silently; offer rollback or manual install instructions
5. **Platform Detection**: Tailor install method to OS (apt/brew/nix/manual)

### Parallel Execution Pattern

```bash
# Launch N workers in background with file-based coordination
# Each worker: check if needed → install to temp dir → atomic move to final location
# Track: pid, status, progress percentage per worker
# Block until all complete or timeout after 4 minutes
# If any failed, print recovery instructions
```

### Progress Tracking

- Per-dependency progress bar (checking → downloading → installing → verified)
- Overall progress summary (N of M complete, ETA)
- Log file for debugging (`~/.shipwright/install.log`)
- On error, show which deps succeeded, which failed, and manual install cmd

### Timeout Strategy

- Global timeout: 4 minutes (leaves 1 min buffer for config + validation)
- Per-dependency timeout: 60s (most installs finish in 10-30s)
- If timeout occurs: abort parallel installs, offer to continue manually

### Verification

After install, verify each tool:
- Binary exists and is executable
- Version matches minimum required
- Can perform basic operation (e.g., `gh --version` succeeds)
- Add to PATH correctly
