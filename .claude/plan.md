# Plan: Script Dependency Graph Analyzer with Coupling Hotspot Detection

## Brainstorming: Design Decisions

### Requirements Clarity
**Minimum viable change**: A single bash script (`sw-analyze.sh`) that scans `scripts/*.sh` for `source`/`.` statements, builds a JSON dependency graph, detects cycles via DFS, identifies high-coupling nodes (in-degree >10), generates a Markdown report with Mermaid diagram, and integrates into the CLI via `shipwright analyze dependencies`.

**Implicit requirements**: Must follow all Shipwright conventions — Bash 3.2 compat, `set -euo pipefail`, VERSION variable, helpers.sh sourcing, atomic file writes, `emit_event` logging, jq for JSON.

### Alternatives Considered

**Approach A: Single monolithic script** — One `sw-analyze.sh` with all logic (parse, graph build, cycle detect, report). ~500-700 lines.
- *Pro*: Simple, self-contained, follows most existing scripts' pattern
- *Pro*: Minimal blast radius — one new file + CLI routing
- *Con*: Harder to test individual components

**Approach B: Library decomposition** — Core graph logic in `scripts/lib/dependency-graph.sh`, thin CLI in `sw-analyze.sh`.
- *Pro*: Reusable graph functions for other tools (architecture enforcer, intelligence)
- *Con*: Two new files, more complexity for a P6 feature
- *Con*: Premature abstraction — nothing else needs this yet

**Decision: Approach A** — Single script. The feature is self-contained and P6 priority. If other tools need graph analysis later, extract then. Minimizes blast radius (3 new files: script, test, package.json entry).

### Risk Assessment
- **Cycle detection in bash**: DFS in bash is verbose but feasible with temporary files for visited/stack tracking. Risk: performance on 200+ scripts. Mitigation: the scan is O(V+E) where V~200, E~500 — trivially fast.
- **Regex for parsing source statements**: Three patterns to match (`source "$SCRIPT_DIR/..."`, `. "$SCRIPT_DIR/..."`, conditional variants). Risk: missing edge cases. Mitigation: test against actual codebase patterns identified in exploration.
- **`jq` string building**: Building a JSON graph with 200+ nodes. Risk: jq pipeline failures. Mitigation: use `jq --arg` and `--slurpfile`, build incrementally with temp files.

---

## Component Diagram

```
┌─────────────────────────────────────────────┐
│            sw-analyze.sh (CLI)              │
│  ┌──────────┐ ┌──────────┐ ┌─────────────┐ │
│  │  Parser   │ │  Graph   │ │  Reporter   │ │
│  │(scan .sh) │ │(cycles,  │ │(markdown,   │ │
│  │           │ │ metrics) │ │ mermaid)    │ │
│  └──────────┘ └──────────┘ └─────────────┘ │
└─────────────────────────────────────────────┘
         │              │              │
         ▼              ▼              ▼
   scripts/*.sh   dependency-    coupling-
   (read-only)    graph.json     report.md
```

### Data Flow
1. **Parser** scans all `scripts/*.sh` and `scripts/lib/*.sh` → extracts source/dependency edges
2. **Graph Builder** assembles JSON graph → runs cycle detection (DFS) → computes in-degree/out-degree metrics
3. **Reporter** reads graph JSON → generates Markdown with Mermaid diagram, hotspot table, refactor suggestions

### Interface Contracts

```
# CLI entry points
analyze_dependencies()  → exit 0 on success, exit 1 on error
  --json          → output raw JSON graph to stdout
  --report        → generate coupling-report.md (default)
  --mermaid       → output Mermaid diagram to stdout
  --threshold N   → override hotspot threshold (default: 10)

# Internal functions
parse_dependencies(script_dir) → writes edges to tmp file (tsv: source\ttarget\ttype)
build_graph_json(edges_file)   → writes ~/.shipwright/dependency-graph.json
detect_cycles(graph_json)      → prints cycle paths, returns 0 if none, 1 if found
compute_metrics(graph_json)    → prints JSON with in_degree, out_degree, hotspots
generate_report(graph_json, metrics_json) → writes scripts/coupling-report.md
generate_mermaid(graph_json)   → prints Mermaid flowchart to stdout
```

### Error Boundaries
- **Parser errors** (missing files, permission): logged via `warn()`, skipped, non-fatal
- **jq errors** (malformed JSON): caught by pipefail, reported with file context
- **Cycle detection**: always succeeds (empty result = no cycles)
- **Report generation**: atomic write via tmp + mv

---

## Files to Modify

| File | Action | Purpose |
|------|--------|---------|
| `scripts/sw-analyze.sh` | **Create** | Main analyzer script (~600 lines) |
| `scripts/sw-analyze-test.sh` | **Create** | Test suite (~350 lines) |
| `scripts/sw` | **Modify** | Add `analyze` case to CLI router |
| `package.json` | **Modify** | Register test in `npm test` chain |

---

## Implementation Steps

### Step 1: Create `scripts/sw-analyze.sh` — Parser Module

Implement the dependency parser that scans scripts for source statements:

```bash
parse_dependencies() {
    local script_dir="${1:-.}"
    local edges_file="$2"
    # Patterns to match:
    # 1. source "$SCRIPT_DIR/lib/foo.sh"
    # 2. . "$SCRIPT_DIR/lib/foo.sh"  
    # 3. [[ -f "$SCRIPT_DIR/lib/foo.sh" ]] && source "$SCRIPT_DIR/lib/foo.sh"
    # 4. source "$SCRIPT_DIR/sw-db.sh" 2>/dev/null || true
    # Extract relative paths, normalize to basename
}
```

Key regex: `(source|\.) +["']?\$\{?SCRIPT_DIR\}?/([^"' ]+)["']?` — captures the target path after SCRIPT_DIR.

### Step 2: Create `scripts/sw-analyze.sh` — Graph Builder

Build the JSON dependency graph in node/edge format:

```json
{
  "generated_at": "2026-04-05T01:00:00Z",
  "version": "1.0",
  "nodes": [
    {"id": "sw-loop.sh", "type": "command", "path": "scripts/sw-loop.sh"}
  ],
  "edges": [
    {"source": "sw-loop.sh", "target": "lib/helpers.sh", "type": "source", "conditional": false}
  ],
  "metrics": {
    "total_nodes": 200,
    "total_edges": 500,
    "cycles": [],
    "hotspots": []
  }
}
```

Uses `jq` to build the JSON atomically — collect edges in a temp TSV, then one `jq` invocation to produce the final JSON.

### Step 3: Create `scripts/sw-analyze.sh` — Cycle Detection

DFS-based cycle detection using temp files for visited/recursion-stack state (Bash 3.2 compatible — no associative arrays):

```bash
detect_cycles() {
    local graph_json="$1"
    local visited_file="$(mktemp)"
    local stack_file="$(mktemp)"
    local cycles_file="$(mktemp)"
    # For each unvisited node, run DFS
    # If we encounter a node already on the stack → cycle found
    # Record cycle path in cycles_file
}
```

Uses temp files with `grep -q` for O(1)-ish membership checks on small sets.

### Step 4: Create `scripts/sw-analyze.sh` — Metrics & Hotspot Detection

Compute in-degree and out-degree from the edge list using `jq`:

```bash
compute_metrics() {
    local graph_json="$1"
    # in_degree: count edges where target == node
    # out_degree: count edges where source == node
    # hotspots: nodes with in_degree > threshold (default 10)
    jq '{
      hotspots: [.nodes[] | select(.in_degree > $threshold)] | sort_by(-.in_degree)
    }' --argjson threshold "$THRESHOLD" "$graph_json"
}
```

### Step 5: Create `scripts/sw-analyze.sh` — Report Generator

Generate `scripts/coupling-report.md` with:
- Summary statistics (nodes, edges, cycles, hotspots)
- Hotspot table (script, in-degree, dependents list)
- Cycle list with full paths
- Refactor recommendations (extract interface, reduce direct sourcing)
- Mermaid flowchart diagram

### Step 6: Create `scripts/sw-analyze.sh` — CLI Boilerplate & Help

Standard Shipwright script boilerplate: shebang, `set -euo pipefail`, VERSION, SCRIPT_DIR, helpers sourcing, `show_help()`, argument parsing, `main()`.

Subcommands:
- `shipwright analyze dependencies` — full analysis + report (default)
- `shipwright analyze dependencies --json` — raw graph JSON to stdout
- `shipwright analyze dependencies --mermaid` — Mermaid diagram to stdout
- `shipwright analyze dependencies --threshold N` — custom hotspot threshold

### Step 7: Register in CLI Router (`scripts/sw`)

Add `analyze` case to the main case statement in `scripts/sw`:

```bash
analyze)
    exec "$SCRIPT_DIR/sw-analyze.sh" "$@"
    ;;
```

Place it alphabetically near other commands.

### Step 8: Create `scripts/sw-analyze-test.sh`

Test suite covering:
1. **Parser tests**: Create fixture scripts with known source patterns → verify edges extracted
2. **Graph JSON structure**: Validate schema (nodes, edges, metrics keys)
3. **Cycle detection**: Create circular fixture (A→B→C→A) → verify cycle detected
4. **No false cycles**: Linear fixture (A→B→C) → verify no cycle
5. **Hotspot detection**: Create fixture where one lib is sourced by 12 scripts → verify flagged
6. **Below-threshold**: Lib sourced by 5 scripts → verify NOT flagged as hotspot
7. **Report generation**: Verify report file created with expected sections
8. **Mermaid output**: Verify valid Mermaid syntax
9. **CLI flags**: `--help`, `--version`, `--json`, `--threshold`
10. **Real codebase scan**: Run against actual `scripts/` dir → verify `lib/helpers.sh` appears as high-coupling

### Step 9: Register Test in `package.json`

Add `bash scripts/sw-analyze-test.sh` to the `npm test` chain.

### Step 10: Verify CLI Discoverability

Ensure `shipwright analyze dependencies` routes correctly and `shipwright analyze --help` shows usage.

---

## Task Checklist

- [ ] Task 1: Create `sw-analyze.sh` with boilerplate (shebang, safety, VERSION, helpers, help text, main)
- [ ] Task 2: Implement `parse_dependencies()` — scan scripts for source/. patterns, output edge TSV
- [ ] Task 3: Implement `build_graph_json()` — convert edges to JSON node/edge format with jq
- [ ] Task 4: Implement `detect_cycles()` — DFS cycle detection using temp files (Bash 3.2 safe)
- [ ] Task 5: Implement `compute_metrics()` — in-degree/out-degree calculation, hotspot identification
- [ ] Task 6: Implement `generate_report()` — Markdown report with hotspots, cycles, refactor suggestions
- [ ] Task 7: Implement `generate_mermaid()` — Mermaid flowchart generation
- [ ] Task 8: Add `analyze` command to CLI router in `scripts/sw`
- [ ] Task 9: Create `sw-analyze-test.sh` — unit tests with fixture scripts for parser, cycles, hotspots
- [ ] Task 10: Create integration test — run against real codebase, verify lib/helpers.sh is a hotspot
- [ ] Task 11: Register test in `package.json` test chain
- [ ] Task 12: Run full test suite (`npm test`) to verify no regressions

---

## Testing Approach

### Test Pyramid Breakdown
- **10 unit tests** (70%): Parser edge extraction, JSON schema validation, cycle detection on fixtures, hotspot threshold logic, Mermaid syntax, CLI flag parsing
- **3 integration tests** (20%): Full pipeline (scan → graph → report) on fixture directory, real codebase scan validating known hotspots
- **1 E2E test** (10%): `shipwright analyze dependencies` CLI invocation end-to-end

### Coverage Targets
- Parser: 100% of known source patterns (unconditional, conditional, error-suppressed, cross-script)
- Cycle detection: positive (has cycle) and negative (no cycle) cases
- Hotspot detection: above-threshold and below-threshold cases
- Report: sections present (summary, hotspots, cycles, mermaid)

### Critical Paths to Test
- **Happy path**: Scan scripts/ → produce graph JSON → generate report with hotspots
- **Error case 1**: Empty directory (no scripts) → graceful empty report
- **Error case 2**: Script with no dependencies → node with 0 edges
- **Edge case 1**: Self-referencing script (sources itself) → detected as trivial cycle
- **Edge case 2**: Diamond dependency (A→B, A→C, B→D, C→D) → no false cycle

---

## Endpoint Specification

**CLI Endpoint**: `shipwright analyze dependencies`

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--json` | boolean | false | Output raw graph JSON to stdout |
| `--report` | boolean | true | Generate coupling-report.md |
| `--mermaid` | boolean | false | Output Mermaid diagram to stdout |
| `--threshold` | integer | 10 | In-degree threshold for hotspot |
| `--dir` | path | scripts/ | Directory to scan |
| `--help` | boolean | false | Show usage |
| `--version` | boolean | false | Show version |

**Success**: exit 0, report written to `scripts/coupling-report.md`, graph to `~/.shipwright/dependency-graph.json`
**Error**: exit 1 with descriptive message via `error()`

**Error Codes**: N/A (CLI tool, not HTTP API)
**Rate Limiting**: N/A
**Versioning**: Graph JSON has `"version": "1.0"` field for future schema evolution

---

## Definition of Done

- [ ] `shipwright analyze dependencies` produces `~/.shipwright/dependency-graph.json` with valid node/edge schema
- [ ] Circular dependencies detected in test fixtures and reported
- [ ] High-coupling nodes (in-degree >10) identified — `lib/helpers.sh` appears as hotspot on real codebase
- [ ] `scripts/coupling-report.md` contains: summary stats, hotspot table, cycle list, Mermaid diagram, refactor suggestions
- [ ] Mermaid diagram renders valid syntax (parseable by Mermaid)
- [ ] All new tests pass (`sw-analyze-test.sh`)
- [ ] Full `npm test` suite passes (no regressions)
- [ ] CLI help text is accessible via `shipwright analyze --help`
- [ ] Script follows all conventions: `set -euo pipefail`, Bash 3.2 compat, VERSION, atomic writes, emit_event

---

## Risk Analysis

| Risk | Impact | Mitigation |
|------|--------|------------|
| Regex misses source patterns | Incomplete graph | Test against 5+ real pattern variants from exploration; add patterns incrementally |
| DFS cycle detection slow on large graphs | Slow CLI response | Graph is ~200 nodes — worst case O(V+E) = O(700), trivially fast |
| jq pipeline fails on large edge sets | Broken JSON output | Build JSON in single jq invocation from TSV, not incrementally |
| Mermaid diagram too large to render | Unusable visualization | Limit to top-30 most-connected nodes in Mermaid output; full graph in JSON |
| Report generation overwrites user edits | Lost manual annotations | Report is auto-generated (not user-edited); add "AUTO-GENERATED" header |

---

## Failure Mode Analysis

### 1. Runtime Failure: `jq` Not Installed
**What breaks**: All JSON graph construction and metric computation fails.
**Mitigation**: `jq` is already a prerequisite checked by `shipwright doctor`. Add an early check: `command -v jq >/dev/null || { error "jq required"; exit 1; }`.

### 2. Concurrency Risk: Simultaneous Analyzer Runs
**What breaks**: Two concurrent runs could write to `~/.shipwright/dependency-graph.json` simultaneously, producing corrupt JSON.
**Mitigation**: Atomic file writes (write to tmp, then `mv`). This is already the Shipwright convention. Each run produces a complete file; last writer wins with a valid file.

### 3. Scale Risk: Future Growth Beyond 500 Scripts
**What breaks**: DFS with temp-file-based visited tracking uses `grep -q` which is O(n) per lookup, making cycle detection O(V*E) in the worst case. At 500 nodes / 2000 edges this could take 5-10 seconds.
**Mitigation**: For the current ~200 scripts this is sub-second. If it grows, switch visited tracking to sorted file + `comm` or binary search. Not needed now — premature optimization.

### 4. Rollback Story
**Fully safe to revert**: This feature adds 3 new files and modifies 2 existing files (one-line additions). Revert = remove files + remove CLI route + remove test registration. No data migration, no schema changes, no persistent state beyond the output JSON/report which are regenerated on each run.

### Critical Failure Addressed in Plan
**Failure #1 (jq not installed)** is addressed by adding an explicit prerequisite check at the top of `sw-analyze.sh` before any graph operations, following the same pattern used in `sw-db.sh` for sqlite3.
