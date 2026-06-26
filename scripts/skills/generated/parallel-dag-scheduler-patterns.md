## Parallel DAG Scheduler Design Patterns

Implementing a dependency-aware parallel scheduler requires careful handling of graph structure, execution ordering, and distributed failure modes. These patterns ensure correctness and reliability.

### 1. DAG Representation & Validation

**Pattern**: Represent stages as nodes; dependencies as directed edges. Detect cycles before execution.

```bash
# Cycle detection via topological sort
if ! topological_sort(dag) 2>/dev/null; then
  echo "ERROR: Circular dependency in stages" >&2; exit 1
fi
```

Why: Cycles deadlock the scheduler. Detect early, fail fast, with clear error message showing the cycle path.

Pitfall: `A depends_on B, B depends_on A` is a direct cycle. But also check transitive: `A→B→C→A`.

### 2. Topological Sorting for Execution Order

**Pattern**: Sort nodes by in-degree. Execute a node only after all its dependencies complete.

```
Input DAG:  A → B → D
            A → C → D

Execution layers (no stage in layer N depends on anything outside layers 0..N-1):
  Layer 0: [A]
  Layer 1: [B, C]  # Both depend on A, can run in parallel
  Layer 2: [D]     # Depends on B and C
```

Why: Layers directly map to synchronization points. You can spawn all stages in a layer as parallel processes, then wait for the layer to complete before advancing.

Pitfall: Don't execute layer 1 stages sequentially—that defeats parallelism.

### 3. Coordinating Parallel Execution

**Pattern**: Spawn stages in the same layer in separate tmux panes/processes. Use file-based signaling or process exit codes to detect completion.

```bash
for stage in ${layer[@]}; do
  tmux new-window -t $session -n $stage "run_stage $stage && echo $stage > /tmp/$session/$stage.done"
done

# Wait for all panes to signal completion
while [ $(ls /tmp/$session/*.done 2>/dev/null | wc -l) -lt ${#layer[@]} ]; do
  sleep 0.1
done
```

Why: Tmux panes run asynchronously; you need explicit synchronization. File-based signaling is bash 3.2 compatible and survives pane crashes.

Pitfall: `wait` builtin waits for background jobs, but tmux panes are not jobs—use explicit signaling or `tmux capture-pane` polling.

### 4. Error Handling & Partial Failure

**Pattern**: When a stage fails, immediately cancel dependent stages (siblings can continue), then fail the pipeline.

```bash
if [ -f /tmp/$session/$stage.error ]; then
  echo "Stage $stage failed. Canceling dependents: ${dependents[@]}"
  for dep in ${dependents[@]}; do
    tmux kill-pane -t $session:$dep
  done
  exit 1
fi
```

Why: Clean shutdown prevents cascading timeouts and logs. Allows independent stages to finish (useful for diagnostics).

Pitfall: `kill -9` on a process may leave cleanup incomplete (temp files, locks). Use process groups and SIGTERM, with timeout fallback to SIGKILL.

### 5. Logging Aggregation

**Pattern**: Each stage logs to its own file. After execution, merge logs in execution order (or by timestamp) for readability.

```bash
# Stage runs with dedicated log
run_stage $stage > /tmp/$session/$stage.log 2>&1

# After all complete, merge
for stage in $(cat /tmp/$session/execution-order.txt); do
  cat /tmp/$session/$stage.log
done > .claude/pipeline-artifacts/unified.log
```

Why: Avoids interleaved output chaos. Timestamps let readers reconstruct actual execution order even if logs are merged out of order.

Pitfall: Stage logs contain ANSI color codes and tmux escape sequences—sanitize before merging.

### 6. Deadlock Prevention

**Pattern**: Avoid circular waits. A stage must not wait for another stage's output (stages are independent by definition). If one stage needs output from another, they have a dependency—encode it in the DAG.

Why: Cycles in waits = deadlock. The DAG already encodes all true dependencies.

Pitfall: Implicit inter-stage dependencies (e.g., stage B reads a file stage A writes) must be explicit in DAG, or parallelization breaks correctness.

### 7. Performance Tuning

**Pattern**: Measure actual parallelism achieved. Wall-clock time is the metric, not "number of stages in parallel."

```bash
time ./pipeline --parallel  # Should be ~max(all_dependency_paths) in duration
```

Why: A pipeline with 10 stages in parallel but with deep sequential chains gains little speedup.

Pitfall: Overhead of spawning tmux panes, logging, and coordination can outweigh gains for short-running stages. Minimum stage duration matters.

### 8. Testing Parallel Execution

**Pattern**: Use mock stages with controllable duration. Run the same DAG multiple times (different random orderings of shell command execution due to scheduling variance). Verify output is identical each run.

```bash
for i in {1..10}; do
  ./pipeline --seed $RANDOM > /tmp/run-$i.log
  diff -q /tmp/run-1.log /tmp/run-$i.log || echo "Non-deterministic output on run $i"
done
```

Why: Catches race conditions that only manifest under certain scheduling. A deterministic pipeline must produce identical output regardless of execution order.

Pitfall: Mock stages that are too fast (return instantly) hide real-world timing issues. Include realistic sleep durations.
