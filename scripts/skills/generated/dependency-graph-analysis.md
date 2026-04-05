# Design: Script Dependency Graph Analyzer with Coupling Hotspot Detection

## Context

Shipwright's `scripts/` directory contains **278 shell scripts** and **81 library files** in `scripts/lib/`, forming a large dependency graph via `source` and `.` statements. There is no tooling to answer basic architectural questions: which libraries are coupling hotspots? Are there circular dependencies? Which refactoring would yield the most decoupling?

**Codebase constraints:**

- All scripts are Bash 3.2 compatible (no associative arrays, no `${var,,}`)
- All scripts use `set -euo pipefail`
- Sourcing follows a consistent pattern: `[[ -f "$SCRIPT_DIR/lib/foo.sh" ]] && source "$SCRIPT_DIR/lib/foo.sh"`
- Libraries use include guards: `[[ -n "${_LIB_LOADED:-}" ]] && return 0`
- JSON manipulation uses `jq --arg` (never string interpolation)
- File writes use atomic temp+mv pattern
- CLI routing uses `case` statements in `scripts/sw` with `exec` dispatch and grouped sub-routers (`route_quality`, `route_observe`, etc.)
- Tests use the shared harness in `scripts/lib/test-helpers.sh` with PASS/FAIL counters and `assert_*` functions
- Tests are registered in `package.json` `"test"` script as `&& bash scripts/sw-*-test.sh` chains

## Decision

### Approach: Regex-based static parser + Tarjan's SCC algorithm + JSON intermediate format

Build a pipeline of 5 focused bash library modules orchestrated by a single CLI script, following the existing `scripts/lib/*.sh` + `scripts/sw-*.sh` pattern.

### Component Diagram

```
                    scripts/sw
                   (case "analyze")
                        │
                        │ exec
                        ▼
          sw-analyze-dependencies.sh
          ┌─────────────────────────┐
          │  CLI args, orchestrate  │
          │  parse → build →        │
          │  analyze → report       │
          └────┬──────┬──────┬──────┘
               │      │      │
     ┌─────────▼┐ ┌───▼────┐ │
     │dependency-│ │graph-  │ │
     │parser.sh  │ │builder.│ │
     │           │ │sh      │ │
     │ regex     │ │ JSON   │ │
     │ extract   │ │ struct │ │
     └───────────┘ └────────┘ │
                    ┌─────────▼──────┐
                    │graph-analysis. │
                    │sh              │
                    │ Tarjan's SCC   │
                    │ in-degree      │
                    │ hotspot score  │
                    └───────┬────────┘
                    ┌───────▼────────┐
                    │report-         │
                    │generator.sh    │
                    │ Markdown       │
                    │ Mermaid        │
                    │ Suggestions    │
                    └───────┬────────┘
                            │
                 ┌──────────┼──────────┐
                 ▼          ▼          ▼
          graph.json   report.md   stdout
```

**Data flow:** Discover `.sh` files → regex-extract source/. statements → build adjacency list as JSON → detect SCCs (cycles) → compute in-degree/coupling scores → generate Markdown+Mermaid report.

### Interface Contracts

```typescript
// dependency-parser.sh
// Reads a single .sh file, writes dependency pairs to stdout
function parse_dependencies(script_path: string): void
  // stdout: "source_file\ttarget_file\n" per dependency (tab-separated, normalized paths)
  // stderr: warnings for unresolvable paths
  // exit 0 always (skip-and-warn on errors)

// graph-builder.sh
// Reads dependency pairs from stdin, writes JSON graph to stdout
function build_graph(): void
  // stdin: tab-separated pairs from parser
  // stdout: {"nodes": [{id, in_degree, out_degree}], "edges": [{from, to, type}]}
  // Deduplicates edges, computes degree counts
  // exit 0 always

// graph-analysis.sh
function detect_cycles(graph_json_path: string): void
  // stdout: JSON array of cycles: [{"path": ["a.sh","b.sh","a.sh"], "length": 2}]
  // Uses Tarjan's SCC algorithm (O(V+E))
  // exit 0 always (empty array if no cycles)

function analyze_coupling(graph_json_path: string, threshold: number = 10): void
  // stdout: JSON array of hotspots: [{"script": "lib/compat.sh", "in_degree": 45,
  //   "out_degree": 3, "dependents": [...], "score": 0.92, "recommendation": "..."}]
  // Score = 0.7 * norm_in_degree + 0.2 * norm_out_degree + 0.1 * bridge_factor
  // exit 0 always

// report-generator.sh
function generate_report(
  graph_json: string,
  cycles_json: string,
  hotspots_json: string,
  output_path: string
): void
  // Writes Markdown report with Mermaid diagram to output_path
  // Uses atomic write (tmp + mv)
  // exit 1 only on write failure

// sw-analyze-dependencies.sh (main)
function main(
  --threshold N,
  --output PATH,
  --format json|markdown|both,
  --scripts-dir PATH
): void
  // Orchestrates full pipeline
  // Default: threshold=10, output=~/.shipwright/, format=both, scripts-dir=./scripts
  // exit 0 on success, exit 1 on fatal error
```

### Error Boundaries

| Component             | Handles                                            | Propagation                                                                              |
| --------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **Parser**            | Missing files, unreadable files, unparseable lines | Warn to stderr, skip file, continue. Never exit non-zero.                                |
| **Graph Builder**     | Duplicate edges, self-loops, empty input           | Deduplicate silently. Self-loops included but flagged. Empty input produces empty graph. |
| **Cycle Detector**    | Graphs >1000 nodes, malformed JSON                 | Cap at 1000 nodes with warning. `jq` validation on entry.                                |
| **Coupling Analyzer** | Invalid threshold, empty graph                     | Default to 10 if invalid. Return `[]` for empty graph.                                   |
| **Report Generator**  | Write failures, missing output dir                 | Create output dir if missing. Exit 1 on unrecoverable write failure.                     |
| **Main Script**       | All above + missing `jq`, missing `scripts/` dir   | Pre-flight checks for `jq`. Aggregate warnings, report count at end.                     |

### Key Design Decisions

**ADR-1: Regex-based source extraction**

Context: Need to extract `source` and `.` statements from bash scripts safely.
Decision: Use `grep -nE '^\s*(\.|source)\s+'` followed by path extraction, handling `"$SCRIPT_DIR/lib/foo.sh"`, `'$SCRIPT_DIR/lib/foo.sh'`, and unquoted forms. Resolve `$SCRIPT_DIR` to the file's parent directory. This handles the `[[ -f ... ]] && source ...` pattern used throughout the codebase.
Consequence: Will miss dynamic paths where the variable is not `SCRIPT_DIR`. Acceptable because this codebase uses `$SCRIPT_DIR` exclusively.

**ADR-2: Tarjan's SCC in bash 3.2**

Context: Need O(V+E) cycle detection without associative arrays.
Decision: Map node IDs to integer indices via sorted arrays. Stack maintained as newline-delimited string. Use indexed arrays only.
Consequence: Slightly more complex implementation, but correct complexity class and bash 3.2 safe.

**ADR-3: Coupling score formula**

Context: Need to rank hotspots beyond simple in-degree count.
Decision: `score = 0.7 * (in_degree / max_in_degree) + 0.2 * (out_degree / max_out_degree) + 0.1 * bridge_factor`. Bridge detection uses DFS reachability check.
Consequence: Weights "how many scripts depend on me" highest (0.7), which is the primary coupling signal. Bridge detection adds O(V+E) per candidate but only runs on top-N nodes.

**ADR-4: JSON intermediate format**

Context: Need a durable, queryable output format.
Decision: Write `~/.shipwright/dependency-graph.json` with nodes, edges, cycles, and hotspots arrays. Schema defined in `.claude/dependency-graph-schema.json`.
Consequence: Downstream tools (dashboard, intelligence engine, CI) can consume the JSON. Human inspection via `jq`. No new dependencies beyond `jq` (already required).

## Alternatives Considered

1. **Full AST parsing (shfmt --tojson)** — Pros: handles all syntax correctly, resolves nested constructs / Cons: external dependency (shfmt not guaranteed), overkill for extracting `source` statements, slower on 350+ files. Rejected: regex handles 95%+ of the consistent sourcing patterns in this codebase.

2. **strace-based dynamic analysis** — Pros: captures actual runtime dependencies including dynamic paths / Cons: requires executing scripts (unsafe side effects), misses conditional branches not taken, enormous overhead, not CI-friendly. Rejected: static analysis is safe, fast, and sufficient.

3. **Floyd-Warshall for cycle detection** — Pros: simpler to implement / Cons: O(V^3) — with 350+ nodes that's ~43M operations vs Tarjan's ~700. Rejected: Tarjan's is the standard choice for SCC detection.

4. **SQLite instead of JSON** — Pros: queryable with SQL, handles large datasets / Cons: adds dependency, overkill for ~350 nodes, harder to diff/inspect in PRs. Rejected: JSON is human-readable, `jq` is already a project dependency.

5. **Single monolithic script** — Pros: simpler file structure / Cons: violates single-responsibility, untestable in isolation, inconsistent with existing `scripts/lib/*.sh` modular pattern. Rejected: modular approach matches codebase conventions.

## Implementation Plan

### Files to Create (8 files)

| File                                      | Purpose                                            | Lines (est.) |
| ----------------------------------------- | -------------------------------------------------- | ------------ |
| `scripts/lib/dependency-parser.sh`        | Regex extraction of source/. statements            | ~120         |
| `scripts/lib/graph-builder.sh`            | JSON graph construction from dependency pairs      | ~100         |
| `scripts/lib/graph-analysis.sh`           | Tarjan's SCC + coupling analysis + hotspot scoring | ~250         |
| `scripts/lib/report-generator.sh`         | Markdown report + Mermaid diagram generation       | ~150         |
| `scripts/sw-analyze-dependencies.sh`      | Main orchestration, CLI args, pre-flight checks    | ~200         |
| `scripts/sw-analyze-dependencies-test.sh` | Test suite (parser, graph, cycles, coupling, E2E)  | ~400         |
| `.claude/dependency-graph-schema.json`    | JSON Schema for `dependency-graph.json` output     | ~60          |
| `test/fixtures/circular-deps/`            | 3 small .sh files with known circular sourcing     | ~15          |

### Files to Modify (2 files)

| File                     | Change                                                                                                |
| ------------------------ | ----------------------------------------------------------------------------------------------------- |
| `scripts/sw` (line ~270) | Add `analyze)` case to main dispatch, routing to `exec "$SCRIPT_DIR/sw-analyze-dependencies.sh" "$@"` |
| `package.json`           | Append `&& bash scripts/sw-analyze-dependencies-test.sh` to `"test"` script                           |

### Dependencies

**No new external dependencies.** Uses `jq` (already required), `grep`, `sort`, `mktemp`, `mv` — all present in the project.

### Risk Areas

1. **Parser accuracy on edge cases** (HIGH) — Dynamic source paths where the variable is not `SCRIPT_DIR` will be missed. Mitigation: document limitations, mark unresolved paths as `[dynamic]`, validate against real codebase to measure miss rate.

2. **Tarjan's algorithm correctness in bash** (HIGH) — Graph algorithms in bash are unusual and error-prone. Mitigation: test on 5 synthetic graphs (no cycles, self-loop, 2-node cycle, 3-node cycle, disconnected components) plus the real codebase.

3. **Performance on full codebase** (MEDIUM) — 350+ scripts with `jq` processing. Mitigation: batch `jq` operations (build full JSON in one pass rather than per-file), target <2 seconds. If needed, parallelize parsing with `xargs -P`.

4. **CLI discoverability** (LOW) — New `analyze` command must appear in `shipwright help`. Mitigation: add to help text, verify with `shipwright help | grep analyze` before design is complete.

## Validation Criteria

- [ ] `shipwright analyze dependencies` runs end-to-end and exits 0
- [ ] `scripts/lib/compat.sh` identified as high-coupling hotspot (in-degree >= 10)
- [ ] `scripts/lib/helpers.sh` identified as high-coupling hotspot (in-degree >= 10)
- [ ] Test fixture with circular dependency is detected: `a.sh -> b.sh -> c.sh -> a.sh`
- [ ] No false-positive cycles in the real Shipwright codebase (unless real cycles exist)
- [ ] JSON output validates against `.claude/dependency-graph-schema.json`
- [ ] Mermaid diagram renders correctly (valid Mermaid syntax)
- [ ] Full analysis completes in < 2 seconds on the Shipwright repo
- [ ] All 70+ tests pass in `sw-analyze-dependencies-test.sh`
- [ ] `npm test` passes with the new test suite included
- [ ] Report includes actionable refactoring suggestions for each hotspot
- [ ] `shipwright help` lists the `analyze` command
- [ ] Graceful degradation: missing files produce warnings (not crashes), empty repos produce empty reports
