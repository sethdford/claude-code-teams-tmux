# {{PROJECT_NAME}} — Node.js Starter Guide

This guide documents conventions and setup procedures for {{PROJECT_NAME}}, a {{FRAMEWORK}} project written in {{LANGUAGE}}.

## Project Overview

{{PROJECT_NAME}} is built with **{{FRAMEWORK}}** on the Node.js runtime. 

**Quick Links:**
- Test command: `{{TEST_CMD}}`
- Build command: `{{BUILD_CMD}}`
- Package manager: `{{PACKAGE_MANAGER}}`

## Project Structure

```
{{PROJECT_NAME}}/
├── src/                    # Source code
│   ├── components/         # {{FRAMEWORK}} components
│   ├── pages/              # Routes/pages
│   ├── lib/                # Shared utilities
│   └── styles/             # Stylesheets
├── tests/                  # Test files
├── public/                 # Static assets
├── package.json            # Project manifest
├── {{LOCK_FILE}}           # Dependency lock
└── tsconfig.json           # TypeScript config (if applicable)
```

## Build & Test

### Installation
```bash
{{PACKAGE_MANAGER}} install
```

### Running Tests
```bash
{{TEST_CMD}}
```

### Building for Production
```bash
{{BUILD_CMD}}
```

### Development Server
```bash
{{DEV_CMD}}
```

## Code Conventions

### Naming Conventions
- **Components**: PascalCase (e.g., `UserProfile`, `Button`)
- **Files**: Same as component name or `index.{{EXTENSION}}`
- **Utilities/Functions**: camelCase (e.g., `formatDate`, `getUserInfo`)
- **Constants**: UPPER_SNAKE_CASE (e.g., `MAX_RETRY_COUNT`, `API_BASE_URL`)
- **Private vars**: prefix with `_` (e.g., `_internalState`)

### Styling Approach
- **CSS Modules** for component-scoped styles, or **Tailwind CSS** for utilities
- BEM convention for class names when not using modules
- Avoid !important; use specificity instead

### Testing Requirements
- Test files colocated or in `tests/` directory
- Naming: `*.test.{{EXTENSION}}` or `*.spec.{{EXTENSION}}`
- **Minimum 70% coverage** for new code
- Test framework: `{{TEST_FRAMEWORK}}`

### Import Style
- Prefer **ES modules** (`import/export`)
- Absolute imports from `src/` where possible
- Organize by: external → internal → relative

## Common Tasks

### Add a New {{FRAMEWORK}} Component
```bash
# Create component file in src/components/
# Use PascalCase naming (e.g., src/components/Button.tsx)
# Include tests alongside or in tests/components/
```

### Update Dependencies
```bash
{{PACKAGE_MANAGER}} update
# Run full test suite afterward
{{TEST_CMD}}
```

### Type Check (TypeScript)
```bash
npx tsc --noEmit
```

### Lint Code
```bash
{{LINT_CMD}}
```

### Format Code
```bash
{{FORMAT_CMD}}
```

## Troubleshooting

### "Cannot find module" errors
- Check import paths are correct (absolute from `src/`, not relative through node_modules)
- Run `{{PACKAGE_MANAGER}} install` to ensure dependencies are present
- Clear `.next/` or `dist/` and rebuild if applicable

### Test failures in CI but pass locally
- Check Node version matches CI config (`.nvmrc`, `package.json` engines field)
- Ensure environment variables are set (e.g., `.env.test`)
- Check for date/time dependent tests

### Performance issues
- Profile with DevTools: `node --inspect=9229 app.js`
- Check bundle size: `npm run build && npx webpack-bundle-analyzer`
- Review slow tests: `{{TEST_CMD}} --verbose --maxWorkers=1`

## Next Steps

1. **Familiarize** yourself with the project structure
2. **Run tests**: `{{TEST_CMD}}` should pass
3. **Read ARCHITECTURE.md** for system design
4. **Check CODING-STANDARDS.md** for detailed conventions
5. **Follow DEFINITION-OF-DONE.md** when submitting PRs
