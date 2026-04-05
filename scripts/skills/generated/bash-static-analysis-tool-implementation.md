## Bash Static Analysis Tool Implementation

### Challenge: Safe Parsing Without Full Interpretation
Bash allows dynamic features (variable expansion, conditionals, command substitution) that make full parsing unsafe. Balance **accuracy vs. robustness**:

1. **Regex-based extraction** (fast, safe, lossy):
   - Pattern: `^\s*(?:\.|source)\s+(['\"]?)([^'\"]+)` captures `source` and `.` statements
   - Handles common cases: `source script.sh`, `. "$DIR/file.sh"`, `source '$LIB'`
   - Ignore comments, already-handled elsewhere
   - Document limitations: won't catch variable-expanded paths like `source "${SCRIPT_DIR}/lib"`

2. **Edge cases to handle**:
   - Quoted strings: `source "path with spaces"`
   - Single/double quotes: track which delimiter started the string
   - Comments: strip `#...` before parsing (but watch for `"#"` inside strings)
   - Variable references: `$SCRIPT_DIR`, `${VAR}` — try simple extraction, fallback to unresolved
   - Subshells: `( source ... )` — extract dependencies normally
   - Conditionals: `if [[ ... ]]; then source; fi` — extract anyway (over-approximate)
   - Already-sourced detection: use `sort -u` on the final list

### Graph Data Structure
Store in JSON for durability and downstream tooling:

```json
{
  "nodes": [
    { "id": "scripts/sw-pipeline.sh", "type": "script", "in_degree": 5 },
    { "id": "scripts/lib/compat.sh", "type": "library", "in_degree": 12 }
  ],
  "edges": [
    { "source": "scripts/sw-daemon.sh", "target": "scripts/lib/compat.sh" }
  ]
}
```

### Cycle Detection: Tarjan's Algorithm
Detect strongly connected components (cycles) in one pass—more efficient than Floyd-Warshall:

- Build adjacency list from edges
- Run DFS-based SCC algorithm (Tarjan or Kosaraju)
- Any SCC with >1 node = cycle
- Report: `["sw-a.sh", "sw-b.sh", "sw-a.sh"]` as a cycle

### Coupling Hotspot Detection
In-degree threshold: count incoming edges.
- High-coupling: in-degree >= 10 (configurable)
- Report format: `{ "script": "lib/compat.sh", "in_degree": 12, "dependents": ["sw-a.sh", ...] }`
- Refactor suggestion: break into smaller, more focused libraries

### Output Generation
- **JSON**: `~/.shipwright/dependency-graph.json` — for downstream tooling
- **Markdown report**: `scripts/coupling-report.md` with:
  - Summary: total scripts, edges, cycles found, hotspots
  - Cycles section: each cycle as a list
  - Hotspots section: sorted by in-degree, with dependents list
  - Refactor suggestions: e.g., "extract monitoring functions from lib/compat.sh into lib/monitoring.sh"
- **Mermaid visualization**: ASCII graph or Mermaid syntax

### Error Handling
- Non-existent sourced files: warn, don't fail (external deps)
- Malformed scripts: skip, report in diagnostics section
- Timeout on very large graphs: cap at 10k nodes, warn user

### Testing Hooks
- **Unit tests**: cycle detection on synthetic graphs
- **Integration test**: fixture with real circular dependency (test/fixtures/circular-deps.sh) and verify detection
- **Regression**: run on Shipwright repo itself, validate hotspots match expectations
