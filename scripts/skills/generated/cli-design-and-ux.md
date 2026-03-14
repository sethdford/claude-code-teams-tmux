## CLI Design and User Experience

When designing command-line interfaces for developer tools, prioritize clarity and responsiveness:

### Command Structure
- Keep command names short and discoverable: `shipwright quickstart` (not `quick-start-setup`)
- Subcommands should follow a hierarchy that mirrors mental models: `quickstart --detect-only` reveals detection without running init
- Use conventional flags: `--dry-run`, `--verbose`, `--skip-validation`

### Progress Feedback
- Show progress for long-running operations (>2 seconds): spinner + phase name ("Detecting project type...", "Running initialization...", "Validating setup...")
- Use structured output (`--json`) for scripting and machine consumption
- Print success/failure summary at the end with next steps (e.g., "✓ Ready! Try: shipwright pipeline start --goal ...")

### Error Recovery
- When detection is ambiguous (e.g., Node + Python), list candidates and ask for confirmation rather than guessing
- Provide actionable error messages: "Found go.mod but no go.sum. Try: `go mod tidy` then re-run quickstart"
- Idempotency: Running quickstart twice should be safe; detect if already initialized and skip redundant steps

### Cross-Platform Compatibility
- Test on macOS (bash + zsh), Linux (bash, shells vary), Windows (Git Bash)
- Avoid platform-specific commands; use `shipwright doctor` to validate environment
- Handle path separators and temp directory placement consistently

### UX Testing
- Time the full flow on reference machines (MacBook Air, standard Linux dev box)
- Capture first-time user feedback: is progress output helpful or noise? Do error messages make sense?
