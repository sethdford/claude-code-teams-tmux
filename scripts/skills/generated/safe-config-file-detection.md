## Safe Configuration File Detection & Project Type Classification

### Detection Strategy
Follow this priority order to reliably classify project types:

1. **Read configuration files safely** — Use `test -f` to check existence, `jq` or safe parsing for JSON/TOML
2. **Definitive markers** — Some files uniquely identify a type: package.json → Node.js, go.mod → Go, Cargo.toml → Rust
3. **Fallback heuristics** — Check for alternative config files (e.g., setup.py or pyproject.toml → Python)
4. **Directory structure** — When multiple types detected, use file layout to identify primary language
5. **Metadata files** — Look at hidden files and directories (.python-version, .ruby-version, etc.) as secondary signals

### Common Detection Markers
- **Node.js**: package.json present + (npm/yarn/pnpm lockfile or node_modules/)
- **Go**: go.mod or go.sum present
- **Python**: pyproject.toml, setup.py, requirements.txt, Pipfile, or .python-version present
- **Rust**: Cargo.toml present
- **Java**: pom.xml (Maven), build.gradle (Gradle), or settings.gradle present

### Handling Ambiguous Cases
1. **Monorepos**: If both package.json and go.mod exist, check top-level directory structure — which has more subdirectories of that type?
2. **Polyglot projects**: Detect primary language from most abundant source files (count .js vs .go vs .py files in src/)
3. **Minimal projects**: If detection uncertain, prompt user for explicit selection rather than guessing
4. **Log confidence**: Record detection confidence (high/medium/low) to help debug why a template was selected

### Security & Performance
- **Safe parsing**: Use `jq` for JSON (never `eval`), grep for text markers — never execute detected content
- **Path safety**: Always use absolute paths, validate file paths don't escape repo root
- **Performance**: Cache detection results; detection should complete in <1 second even for large repos
- **Empty/malformed files**: Handle gracefully — a missing or empty config file is a valid signal

### Test Coverage
Minimum test cases:
- Valid single-type projects for each of 5+ types
- Monorepos with multiple types (Node + Go, Python + Rust, etc.)
- Empty/malformed configuration files
- Minimal projects (only one tiny config file)
- Edge case: symlinked config files
- Performance: detection time on a 1000-file repo
