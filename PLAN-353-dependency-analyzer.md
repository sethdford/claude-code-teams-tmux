# Implementation Plan: Script Dependency Graph Analyzer with Coupling Hotspot Detection

**Issue**: #353  
**Goal**: Script Dependency Graph Analyzer with Coupling Hotspot Detection  
**Complexity**: Standard  
**Status**: Plan Stage  
**Generated**: 2026-04-05

---

## Executive Summary

Build a bash-based system for analyzing script dependencies in Shipwright, detect circular dependencies and high-coupling hotspots, and generate refactoring recommendations. This supports P6: Platform Self-Improvement by enabling architectural health analysis and guiding decoupling efforts.

**Key Deliverables**:

- JSON dependency graph: `~/.shipwright/dependency-graph.json`
- Markdown report: `scripts/coupling-report.md` with Mermaid visualization
- CLI command: `shipwright analyze dependencies`
- Test suite with circular dependency detection validation

---

## Requirements Analysis

### Acceptance Criteria (From Issue)

- ✓ Parse all `scripts/*.sh` for `. "$SCRIPT_DIR/..."` and `source ...` statements
- ✓ Build dependency graph in JSON with node/edge format
- ✓ Detect circular dependencies and high-coupling nodes (in-degree >10)
- ✓ Generate report with hotspots and refactor suggestions
- ✓ Visualize graph in Mermaid format
- ✓ Integration test: detect circular deps in fixture, identify lib scripts as high-coupling
- ✓ CLI: `shipwright analyze dependencies` outputs report

### Implicit Requirements

- Handle `$SCRIPT_DIR` variable expansion in paths
- Warn on non-existent sourced files (external dependencies)
- Skip comments and malformed scripts gracefully
- Support both single and double-quoted strings
- Deduplicate dependencies (normalize paths)

### Design Constraints

- **Bash 3.2 compatible** - no associative arrays, no `${var,,}` syntax
- **set -euo pipefail** on all scripts
- **Atomic writes** - use temp file + `mv`, never direct `echo > file`
- **JSON escaping** - use `jq --arg` for all variables
- **No subshell directory changes** - use `( cd ... )` when needed
- **EVENT_LOGGING** - emit events for observability
- **No circular sourcing** - lib files must not source main scripts

---

## Component Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    CLI Router (scripts/sw)                              │
│                   [analyze dependencies]                                │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│          sw-analyze-dependencies.sh (Main Script)                       │
│  - Parse arguments, validate repo, orchestrate analysis, output results │
└────────────────────────┬────────────────────────┬──────────────────────┘
                         │                        │
         ┌───────────────▼────────────┐  ┌───────▼──────────────────┐
         │  lib/dependency-           │  │  lib/graph-analysis.sh   │
         │  parser.sh                 │  │ (Cycle + Coupling Detect)│
         │                            │  │                          │
         │ - Extract ./*source        │  │ - Tarjan's Algorithm     │
         │ - Resolve $SCRIPT_DIR      │  │ - In-degree Analysis     │
         │ - Normalize paths          │  │ - Coupling Thresholds    │
         └────────────┬───────────────┘  └────────┬─────────────────┘
                      │                           │
         ┌────────────▼───────────────────────────▼──────────┐
         │  lib/graph-builder.sh                             │
         │ - JSON graph structure                            │
         │ - Node/edge management                            │
         │ - Deduplication                                   │
         └────────────┬─────────────────────────────────────┘
                      │
         ┌────────────▼───────────────────────────────┐
         │  lib/report-generator.sh                   │
         │ - Markdown formatting                      │
         │ - Mermaid graph visualization              │
         │ - Refactor recommendations                 │
         └────────────┬─────────────────────────────┘
                      │
         ┌────────────▼───────────────────────────────┐
         │  Output Files                              │
         │ - ~/.shipwright/dependency-graph.json      │
         │ - scripts/coupling-report.md (with Mermaid)│
         └────────────────────────────────────────────┘
```

### Component Responsibilities

| Component             | Responsibility                              | Inputs                      | Outputs                        |
| --------------------- | ------------------------------------------- | --------------------------- | ------------------------------ |
| **CLI Router**        | Dispatch `analyze dependencies` subcommand  | Command args                | Invokes main script            |
| **Parser**            | Extract dependencies from bash scripts      | File paths, $SCRIPT_DIR var | List of (source, target) pairs |
| **Graph Builder**     | Construct directed graph data structure     | Dependencies list           | Node/edge JSON objects         |
| **Cycle Detector**    | Find strongly connected components          | Graph edges                 | List of cycles                 |
| **Coupling Analyzer** | Calculate in-degree, identify hotspots      | Graph nodes/edges           | Hotspot list with dependents   |
| **Report Generator**  | Format markdown + Mermaid visualization     | Graph, cycles, hotspots     | coupling-report.md             |
| **Main Script**       | Orchestrate pipeline, handle errors, output | Repo path, options          | JSON graph + report            |

---

## Interface Contracts

### Public Functions

#### `parse_dependencies(script_path)`

**Purpose**: Extract source/library statements from a bash script  
**Input**:

- `script_path` (string) - absolute path to .sh file

**Output** (to stdout, one per line):

```
source_script target_script
```

**Errors**:

- Non-existent file → warn and return empty
- Unreadable file → warn and return empty
- Malformed script → skip problematic lines, warn once

**Preconditions**: Script path is absolute  
**Postconditions**: Output is sorted and deduplicated

---

#### `build_graph(dependencies_list)`

**Purpose**: Construct JSON graph from dependency pairs  
**Input** (stdin): dependency pairs  
**Output** (stdout): JSON graph object with nodes and edges

**Error Contract**:

- Invalid JSON input → return error with line number
- Duplicate edges → deduplicate silently
- Self-loops → include in graph, flag in diagnostics

---

#### `detect_cycles(graph_json)`

**Purpose**: Find all circular dependencies  
**Input**: JSON graph object  
**Output** (stdout): JSON array of cycles

**Errors**:

- Invalid graph → return error message
- Timeout (>1000 nodes) → return partial results with warning

---

#### `analyze_coupling(graph_json, threshold=10)`

**Purpose**: Identify high-coupling nodes  
**Input**:

- JSON graph
- Coupling threshold (in-degree ≥ threshold)

**Output** (stdout): JSON array of hotspots

**Error Contract**:

- Threshold < 0 → use default (10)
- Threshold > node count → return empty array

---

### Error Boundaries

| Layer                 | Errors Handled                             | Propagation                                   |
| --------------------- | ------------------------------------------ | --------------------------------------------- |
| **Parser**            | File not found, unreadable, malformed bash | Warn, skip file, continue                     |
| **Graph Builder**     | Invalid JSON, duplicate edges, self-loops  | Flag in diagnostics, include anyway           |
| **Cycle Detector**    | Timeout, invalid graph structure           | Partial results + timeout warning             |
| **Coupling Analyzer** | Invalid threshold, empty graph             | Use defaults, return empty results            |
| **Report Generator**  | File write failures, path errors           | Exit 1 with detailed message                  |
| **Main Script**       | All of above + missing directories         | Aggregate errors, output to stderr, exit code |

---

## Task Decomposition

### Phase 1: Foundation (Tasks 1-3)

- [ ] **Task 1: Create JSON schema and library structure**
  - Create `.claude/dependency-graph-schema.json` (formal JSON schema)
  - Create `scripts/lib/dependency-graph.sh` (data structure helpers)
  - Define node/edge structure, validation helpers
  - **Dependencies**: None (foundational)

- [ ] **Task 2: Implement dependency parser**
  - Create `scripts/lib/dependency-parser.sh`
  - Implement `parse_dependencies(script_path)` function
  - Handle `. "$SCRIPT_DIR/..."` and `source ...` patterns
  - Resolve $SCRIPT_DIR variable expansion
  - Normalize and deduplicate paths
  - **Dependencies**: Task 1

- [ ] **Task 3: Implement graph builder**
  - Create `scripts/lib/graph-builder.sh`
  - Implement `build_graph()` function
  - Build node/edge JSON structure
  - Calculate in-degrees
  - **Dependencies**: Task 1, Task 2

### Phase 2: Analysis (Tasks 4-5)

- [ ] **Task 4: Implement cycle detection (Tarjan's algorithm)**
  - Create `scripts/lib/graph-analysis.sh`
  - Implement `detect_cycles(graph_json)` function
  - Use Tarjan's SCC algorithm for efficiency
  - Return strongly connected components
  - **Dependencies**: Task 3

- [ ] **Task 5: Implement coupling analysis**
  - In `scripts/lib/graph-analysis.sh`, add `analyze_coupling(graph_json, threshold)`
  - Identify nodes with in-degree ≥ threshold
  - Collect dependents for each hotspot
  - Generate refactor suggestions
  - **Dependencies**: Task 3

### Phase 3: Reporting (Tasks 6-7)

- [ ] **Task 6: Implement report generator**
  - Create `scripts/lib/report-generator.sh`
  - Implement `generate_report()` function
  - Markdown formatting: sections for summary, cycles, hotspots
  - Mermaid graph visualization code
  - Refactor recommendations based on hotspots
  - **Dependencies**: Task 4, Task 5

- [ ] **Task 7: Create main orchestration script**
  - Create `scripts/sw-analyze-dependencies.sh`
  - Parse arguments (--threshold, --output, --format)
  - Discover all scripts in `scripts/` directory
  - Orchestrate: parse → build → analyze → report
  - Handle errors and output results
  - **Dependencies**: Task 2-6

### Phase 4: Integration & Testing (Tasks 8-10)

- [ ] **Task 8: Integrate with CLI router**
  - Modify `scripts/sw` to add `analyze` subcommand
  - Route `shipwright analyze dependencies` to main script
  - Update help text
  - **Dependencies**: Task 7

- [ ] **Task 9: Create comprehensive test suite**
  - Create `scripts/sw-analyze-dependencies-test.sh`
  - Unit tests for parser, graph builder, cycles, coupling, report
  - Integration tests on real codebase
  - **Dependencies**: Task 2-7

- [ ] **Task 10: Run on actual codebase and validate**
  - Execute analyzer on Shipwright repo
  - Verify lib/compat.sh identified as high-coupling hotspot
  - Identify any circular dependencies
  - Create test fixture with known circular dependency
  - **Dependencies**: Task 9

### Phase 5: Documentation & Validation (Tasks 11-12)

- [ ] **Task 11: Write documentation**
  - Add section to CLAUDE.md or create docs/dependency-analyzer.md
  - Document usage and interpret report output
  - **Dependencies**: Task 10

- [ ] **Task 12: Add integration test to npm test suite**
  - Register test in `package.json`
  - Verify test runs as part of CI
  - **Dependencies**: Task 9

---

## Risk Analysis

### Risk 1: Parser False Positives/Negatives

**Severity**: HIGH  
**Mitigation**: Use conservative regex, validate paths, test extensively with edge cases

### Risk 2: Tarjan's Algorithm Implementation Bug

**Severity**: HIGH  
**Mitigation**: Test on synthetic graphs, validate output against hand-traced cycles

### Risk 3: Performance on Large Repo

**Severity**: MEDIUM  
**Mitigation**: Cap node count at 10k, add progress indicators, timeout cycle detection at 30s

### Risk 4: Variable Expansion Edge Cases

**Severity**: MEDIUM  
**Mitigation**: Simple variable expansion, document limitations, test with real examples

### Risk 5: Circular Sourcing in Graph Builder

**Severity**: LOW  
**Mitigation**: Generate explicit warning in report for lib → main dependencies

### Risk 6: File Write Atomicity

**Severity**: LOW  
**Mitigation**: Write to temp file then `mv`, validate JSON before finalizing

---

## Alternatives Considered

### Alternative 1: Regex-based Parsing (CHOSEN)

**Pros**: Fast, safe, handles 95% of real-world cases  
**Cons**: Misses dynamic paths, vulnerable to false positives  
**Trade-off**: Speed/safety vs completeness - acceptable for this use case

### Alternative 2: Full Bash AST Parser (REJECTED)

**Pros**: Near-perfect accuracy  
**Cons**: Too slow, complex, overkill

### Alternative 3: strace-based Detection (REJECTED)

**Pros**: Captures actual sourcing at runtime  
**Cons**: Intrusive, risky side effects, slow

### Alternative 4: Floyd-Warshall for Cycles (REJECTED)

**Pros**: Simpler algorithm  
**Cons**: O(V³) complexity, inefficient for sparse graphs

### Alternative 5: SQLite Storage (REJECTED)

**Pros**: Queryable, can store history  
**Cons**: Adds dependency, JSON sufficient for now

---

## Failure Mode Analysis

### Failure Mode 1: Parser Misses Sourced Files Due to Quoting

**Scenario**: Script has `source '$LIB_DIR/file.sh'` (dynamic variable)  
**Impact**: Dependency not detected, graph incomplete  
**Likelihood**: MEDIUM  
**Mitigation**: Extract quoted strings, remove quotes, document limitations  
**Recovery**: User can manually add to graph JSON, re-run analyzer

---

### Failure Mode 2: Circular Sourcing in lib/ Scripts

**Scenario**: `lib/a.sh` sources `sw-x.sh`, which sources `lib/a.sh` indirectly  
**Impact**: Cycle detected but indicates architectural violation  
**Likelihood**: LOW  
**Mitigation**: Flag lib → sw-\* dependencies as violations, include warning in report  
**Recovery**: Move problematic code to new shared helper lib

---

### Failure Mode 3: Timeout on Cycle Detection in Large Graph

**Scenario**: Repo grows to 500+ scripts, Tarjan's DFS exceeds 30s timeout  
**Impact**: Report incomplete, user doesn't know if cycles exist  
**Likelihood**: LOW  
**Mitigation**: Implement 30s timeout, return partial results with warning  
**Recovery**: Run on subset of scripts with `--max-nodes` flag

---

### Failure Mode 4: Cannot Write Report Due to Permission Error

**Scenario**: User runs analyzer, `scripts/` directory is read-only  
**Impact**: Analyzer fails, no report generated  
**Likelihood**: MEDIUM  
**Mitigation**: Write to `~/.shipwright/` by default, allow `--output` flag  
**Recovery**: Fix permissions, re-run with explicit output path

---

### Failure Mode 5: Bash Script Syntax Error Halts Parser

**Scenario**: Script contains syntax error, parser crashes  
**Impact**: Analysis incomplete  
**Likelihood**: LOW  
**Mitigation**: Wrap parser in error handling, skip files with errors, warn once  
**Recovery**: Fix syntax error, re-run analyzer

---

### Failure Mode 6: Very Deep Tarjan's Recursion Stack Overflow

**Scenario**: Graph with 1000+ deep dependency chain  
**Impact**: Bash recursion limit exceeded  
**Likelihood**: VERY LOW  
**Mitigation**: Accept as rare crash (cost of fix > benefit), recovery via --skip-cycles

---

## Definition of Done

### Functionality

- [ ] Parser correctly extracts dependencies from all 100+ scripts
- [ ] Graph JSON schema is formal and documented
- [ ] Cycle detection identifies known test fixture cycles
- [ ] Coupling analysis identifies lib/compat.sh as hotspot
- [ ] Report generated with Mermaid visualization
- [ ] `shipwright analyze dependencies` command works end-to-end

### Quality

- [ ] All unit tests pass (parser, graph, cycles, coupling, report)
- [ ] Integration test verifies circular dependency detection
- [ ] Test coverage ≥ 80% for core logic
- [ ] Code follows bash conventions (set -euo pipefail, bash 3.2 compatible)
- [ ] No shellcheck warnings (excluding intentional disables)

### Performance

- [ ] Analysis completes in <1 second on Shipwright repo
- [ ] Memory usage <50MB
- [ ] JSON graph file <1MB

### Integration

- [ ] Test registered in `package.json`
- [ ] CI passes on Linux and macOS
- [ ] No regressions in existing tests

---

## Testing Strategy

### Test Pyramid: 70 Tests Total (85% Coverage)

**Unit Tests (45 tests, 70%)**:

- Parser: 12 tests (quotes, comments, escapes, $SCRIPT_DIR, dedup)
- Graph Builder: 12 tests (nodes, edges, in-degree, sorting, schema validation)
- Cycle Detection: 12 tests (2/3/5-node cycles, self-loops, disconnected components)
- Coupling Analysis: 9 tests (threshold variations, sorting, dependents list)

**Component Integration Tests (8 tests, 20%)**:

- Full pipeline: parse → build → analyze (no cycles)
- Full pipeline: graph with known 3-node cycle
- Real Shipwright scripts analysis
- Graph deduplication across files
- Cycle detector: fixture with circular dependency
- Coupling analyzer: identify lib/compat.sh hotspot
- Report generator: valid Markdown and Mermaid
- Report generator: Mermaid syntax validation

**E2E Tests (3 tests, 10%)**:

- Analyze actual Shipwright repo (verify lib/compat.sh hotspot, no cycles)
- Analyze test fixture with intentional circular dependency
- Test CLI options (--threshold, --output, --help, exit codes)

### Coverage Targets

| Component         | Target | Rationale                              |
| ----------------- | ------ | -------------------------------------- |
| Parser            | 90%    | Critical, must handle edge cases       |
| Graph Builder     | 85%    | Straightforward logic                  |
| Cycle Detector    | 95%    | Core algorithm, must be correct        |
| Coupling Analyzer | 80%    | Simple threshold check                 |
| Report Generator  | 75%    | Formatting logic                       |
| Main Script       | 70%    | Orchestration, integration tests cover |

---

## Architecture Decision Records

### ADR-1: Regex-Based Parser vs Full Interpretation

**Decision**: Conservative regex extraction  
**Rationale**: Fast, safe, handles 95% of cases, no eval risk  
**Consequences**: Will miss dynamic paths, document limitations

### ADR-2: Tarjan's Algorithm for Cycle Detection

**Decision**: Use Tarjan's SCC algorithm (O(V+E))  
**Rationale**: Efficient for sparse graphs, well-tested  
**Consequences**: May have deep recursion on long chains (mitigated by timeout)

### ADR-3: JSON for Graph Storage

**Decision**: Store in JSON (`~/.shipwright/dependency-graph.json`)  
**Rationale**: Universal, queryable, human-readable, integrates with jq  
**Consequences**: Must regenerate each run, large graphs have large files

### ADR-4: Threshold for High-Coupling Detection

**Decision**: Default threshold = 10 (in-degree ≥ 10)  
**Rationale**: Middle-ground between strictness and false positives  
**Consequences**: Threshold is configurable, user must understand meaning

---

## Files to Create

| File                                      | Purpose                              |
| ----------------------------------------- | ------------------------------------ |
| `scripts/lib/dependency-graph.sh`         | Graph data structure and validation  |
| `scripts/lib/dependency-parser.sh`        | Parser for bash source statements    |
| `scripts/lib/graph-builder.sh`            | JSON graph construction              |
| `scripts/lib/graph-analysis.sh`           | Cycle and coupling analysis          |
| `scripts/lib/report-generator.sh`         | Markdown report + Mermaid generation |
| `scripts/sw-analyze-dependencies.sh`      | Main orchestration script            |
| `scripts/sw-analyze-dependencies-test.sh` | Comprehensive test suite             |
| `.claude/dependency-graph-schema.json`    | Formal JSON schema                   |

---

## Files to Modify

| File           | Changes                            |
| -------------- | ---------------------------------- |
| `scripts/sw`   | Add `analyze` subcommand routing   |
| `package.json` | Register test in test suite        |
| `CLAUDE.md`    | Document analyzer usage (optional) |

---

## Implementation Sequence

1. **Tasks 1-3**: Create data structures and parser (foundation)
2. **Tasks 4-5**: Implement analysis algorithms (core logic)
3. **Task 6**: Report generation (formatting)
4. **Task 7**: Main script (orchestration)
5. **Task 8**: CLI integration (user-facing)
6. **Task 9**: Test suite (validation)
7. **Task 10**: Real codebase validation (verification)
8. **Tasks 11-12**: Documentation and CI integration (polish)

---

## Success Metrics

✓ All 70 tests passing  
✓ <1 second execution time on Shipwright repo  
✓ lib/compat.sh identified as high-coupling (in-degree ≥10)  
✓ No false-positive cycles detected  
✓ Mermaid visualization readable (not too dense)  
✓ Report provides actionable refactor suggestions  
✓ Zero regressions in existing tests
