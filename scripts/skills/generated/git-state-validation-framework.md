## Git State Validation Framework

This skill guides design and implementation of git state validators that run before/after each pipeline stage, catching dirty state that could cascade into later failures.

### Core Concepts

**Validation Timing**:
- **Before-stage validation**: Check for uncommitted changes, untracked files in src dirs, unexpected branches. Abort or auto-stash based on stage requirements.
- **After-stage validation**: Compare actual file changes against stage manifest. Flag unexpected changes (dead code, leftover artifacts, IDE files) for manual review or auto-cleanup.

**Stage Manifests**:
- Each stage declares expected outputs: files that SHOULD change, patterns that MUST NOT change (node_modules, .env, dist/legacy)
- Manifest examples: build stage expects src/**/*.js modified; test stage expects .coverage updated; review stage expects .github/CODEOWNERS or commits only
- Manifests live in `.claude/pipeline-artifacts/stage-manifests.json` (generated at design time, audited per PR)

**Recovery Strategies**:
1. **Auto-stash** (safe stages): Preserve user changes, clear working tree. Example: before build, stash any local edits so clean build runs.
2. **Abort with diagnostics** (gated stages): Don't proceed if state is dirty. Include: file list, branch status, suggested `git stash` or `git checkout -- .` commands.
3. **Warn-only** (deploy stage): Log unexpected changes but proceed (human reviewer should inspect PR).

**Implementation Patterns**:

```bash
# Before-stage check
validate_before_stage "build" --allow-dirty-list ".env.local,.DS_Store" || abort

# After-stage check
validate_after_stage "build" --manifest ".claude/pipeline-artifacts/stage-manifests.json" || abort

# Auto-stash on conflict
if ! validate_before_stage "test"; then
  git stash && git stash drop  # or: git checkout -- . for untracked
  validate_before_stage "test" || abort  # re-check
fi
```

**Cross-Platform Considerations**:
- Line endings (CRLF vs LF) on Windows CI—use `git config core.autocrlf`
- IDE-generated files (.vscode, .idea, .DS_Store)—allow-list in manifest
- Docker/VM-specific paths in .gitignore—respect repo rules
- Worktrees each have isolated git state—validate per worktree context

**Manifest Evolution**:
- Start with permissive manifests (only ban truly unexpected: node_modules, .env)
- Tighten over time based on false positives (collect in pipeline metrics)
- PRs that change manifests require explicit sign-off (safety gate)

**Performance**:
- Use `git status --porcelain` (fast) not `git diff` (slow on large repos)
- Cache manifest parsing if validation runs multiple times per stage
- For large repos, validate only changed files or use sparse checkout hints

**Testing the Validators**:
- Unit tests: validate() function with mock git state (dirty files, untracked, etc.)
- Integration tests: real git repo with intentional dirty state, verify detection + recovery
- Regression: run full pipeline with injected dirty state after each stage, confirm caught
