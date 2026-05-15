<!-- sw:auto-start -->
# Coding Standards

## Naming
- Convention: **snake_case**
- Files: follow existing file naming patterns in the project
- Variables/functions: use **snake_case** style consistently

## Imports
- Style: **CommonJS (require/module.exports)**
- Keep imports organized: stdlib → external deps → internal modules

## Error Handling
- Use the existing error handling patterns
- Always handle promise rejections / async errors
- Provide meaningful error messages
- Do not swallow errors silently

## Testing
- Framework: **vitest**
- Write tests for all new functionality
- Test both success and error paths
- Use descriptive test names
- Keep tests focused — one assertion per test where practical

## File Organization
- Source code: `src schemas`
- Tests: `tests`
- Follow the existing directory structure — do not create new top-level dirs without discussion
<!-- sw:auto-end -->
