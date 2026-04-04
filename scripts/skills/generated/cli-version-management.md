## CLI Version Management: Package.json Integration

**Pattern**: Read version from package.json, format for display, handle edge cases.

### Version Source Resolution
- **Canonical source**: Always read from `package.json` at repo root or script-relative location
- **Path resolution**: Use `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` to find script dir, then traverse up to repo root (where package.json lives)
- **Validation**: Verify JSON is valid before parsing; provide actionable error if missing/corrupt

### Version Extraction & Formatting
- **Parser**: Use `jq '.version' package.json` (safer than regex or sed)
- **Format standard**: `Shipwright vX.Y.Z` (prefix + space + v + semver)
- **Validation**: Warn if version doesn't match semver (x.y.z pattern); don't fail, but log warning

### Error Handling
- Missing file: `error "package.json not found at <path>"` → exit 1
- Invalid JSON: Catch jq error → `error "package.json is malformed"` → exit 1
- Missing version field: `error "version field missing in package.json"` → exit 1

### Testing Pattern
- **Unit test**: Create temp package.json with known version, invoke command, assert exact output
- **Isolation**: Don't depend on real package.json; create fixtures for each test case
- **Edge cases**: test missing file, malformed JSON, missing version field, non-semver version
- **Bash 3.2 safe**: Use `$()` not `<()`, no `readarray`, no `declare -A`

### CLI Display
- **Standard output**: Version string only (e.g., `Shipwright v1.2.3`), no extra whitespace or formatting
- **Exit code**: 0 on success, 1 on error
- **Integration**: `sw hello` should output version alongside any other greeting output
