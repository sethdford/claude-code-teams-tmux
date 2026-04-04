# {{PROJECT_NAME}} — Project Starter Guide

This guide documents conventions and setup procedures for {{PROJECT_NAME}}.

## Project Overview

{{PROJECT_NAME}} is a project with the following stack:
- **Language**: {{LANGUAGE}}
- **Framework**: {{FRAMEWORK}}{{BUILD_TOOL:+ (Build tool: {{BUILD_TOOL}})}}

**Quick Links:**
- Test command: `{{TEST_CMD}}`
- Build command: `{{BUILD_CMD}}`

## Project Structure

```
{{PROJECT_NAME}}/
├── src/                    # Source code
├── tests/                  # Test files
├── docs/                   # Documentation
├── .github/workflows/      # CI/CD configuration
└── README.md               # Project overview
```

## Build & Test

### Installation
Review the README.md or project documentation for environment setup.

### Running Tests
```bash
{{TEST_CMD}}
```

### Building for Production
```bash
{{BUILD_CMD}}
```

## Code Conventions

### General Guidelines
1. **Consistency**: Follow existing code style in the project
2. **Testing**: Write tests for new features
3. **Documentation**: Document public APIs and complex logic
4. **Git Hygiene**: Use descriptive commit messages

### Naming Conventions
- Adopt the project's existing naming patterns
- Classes/Types: PascalCase
- Functions/Methods: camelCase or snake_case (whichever is predominant)
- Constants: UPPER_SNAKE_CASE

### Testing Requirements
- **Minimum coverage**: New code should have corresponding tests
- Test files colocated with implementation or in separate test directory
- Run tests locally before submitting PRs

### Code Quality
- Run linter/formatter if available (e.g., `eslint`, `black`, `clippy`)
- Use editor integration for real-time feedback
- Address all warnings before commit

## Common Tasks

### Run Tests
```bash
{{TEST_CMD}}
```

### Update Dependencies
Review project documentation for dependency management practices.

### Submit a Change
1. Create a feature branch
2. Make your changes
3. Run tests: `{{TEST_CMD}}`
4. Commit with descriptive message
5. Submit a pull request

## Troubleshooting

### Build or Test Failures
1. Check that all dependencies are installed
2. Verify Node/Python/Go/Rust version matches project requirements
3. Review recent changes or CI logs
4. Ask in project chat or check open issues

### Environment Setup Issues
- Check for `.env.example` template
- Review CI configuration (`.github/workflows`, `Makefile`, etc.)
- Look for setup scripts in `scripts/` or `tools/`

## Next Steps

1. **Run tests**: `{{TEST_CMD}}` should pass
2. **Read README.md** for project-specific information
3. **Check for ARCHITECTURE.md** or similar documentation
4. **Look for CONTRIBUTING.md** for contribution guidelines
5. **Review recent PRs** to understand current patterns

---

**Note**: This is a generic starter guide. For framework-specific guidance, consult the framework's official documentation.
