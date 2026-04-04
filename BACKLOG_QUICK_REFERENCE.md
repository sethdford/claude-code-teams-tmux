# Shipwright Backlog: Quick Reference (20-Item Priority List)

## At-a-Glance Priority Matrix

| Priority | ID  | Feature                                              | Impact   | Effort   | ROI             | Category      |
| -------- | --- | ---------------------------------------------------- | -------- | -------- | --------------- | ------------- |
| 🔴 P0    | #1  | Semantic trajectory analysis + convergence detection | 🟢🟢🟢   | 🟡🟡     | **EXCEPTIONAL** | Loop Patterns |
| 🔴 P0    | #2  | Intent Specification Engine (business → outcomes)    | 🟢🟢🟢🟢 | 🔴🔴🔴   | **EXCEPTIONAL** | Dark Factory  |
| 🔴 P0    | #3  | Vulnerability Reward Model + online RL               | 🟢🟢🟢   | 🟡🟡     | **EXCEPTIONAL** | RL/Security   |
| 🔴 P0    | #5  | Speculative Cascade Model Routing                    | 🟢🟢🟢🟢 | 🟡🟡     | **VERY HIGH**   | Cost          |
| 🟡 P1    | #4  | Episodic Memory Layer                                | 🟢🟢🟢   | 🔴🔴🔴   | **HIGH**        | Memory        |
| 🟡 P1    | #6  | Mutation Testing Feedback Loop                       | 🟢🟢🟢   | 🟡🟡     | **HIGH**        | Testing       |
| 🟡 P1    | #7  | CI Repair Agent                                      | 🟢🟢🟢   | 🔴🔴🔴   | **HIGH**        | Self-Healing  |
| 🟡 P1    | #8  | LLM-as-a-Judge validation                            | 🟢🟢     | 🟡🟡     | **HIGH**        | Quality       |
| 🟢 P2    | #9  | Explicit Conflict Detection + DAG Scheduling         | 🟢🟢     | 🟡🟡     | **MEDIUM**      | Multi-Agent   |
| 🟢 P2    | #10 | Intelligent Reasoning Budget Allocation              | 🟢🟢     | 🟡🟡     | **MEDIUM**      | Reasoning     |
| 🟢 P2    | #11 | Formal Verification Integration (Dafny/Lean)         | 🟢🟢     | 🔴🔴🔴🔴 | **MEDIUM**      | Verification  |
| 🟢 P2    | #12 | Active Context Compression + Semantic Memory         | 🟢🟢🟢   | 🔴🔴🔴   | **MEDIUM**      | Memory        |
| 🟢 P2    | #13 | Multi-Pass Mutation Generation (LLM-based)           | 🟢🟢     | 🔴🔴🔴   | **MEDIUM**      | Testing       |
| 🟢 P2    | #14 | Anomaly Detection + Predictive Repair                | 🟢🟢     | 🔴🔴🔴   | **MEDIUM**      | Self-Healing  |
| 🟢 P2    | #15 | Cross-Repo Fleet Learning                            | 🟢🟢     | 🔴🔴🔴   | **MEDIUM**      | Memory/Fleet  |
| 🟢 P3    | #16 | Quorum-Based Merge Decisions                         | 🟢       | 🟡       | **LOW**         | Quality       |
| 🟢 P3    | #17 | Privacy-Hardening Mutations                          | 🟢       | 🔴🔴     | **LOW**         | Compliance    |
| 🟢 P3    | #18 | Dependency-Aware Task Scheduling (DAG)               | 🟢       | 🟡       | **LOW**         | Multi-Agent   |
| 🟢 P3    | #19 | Symbol Caching + Semantic Search                     | 🟢       | 🟡       | **LOW**         | Performance   |
| 🟢 P3    | #20 | WebSocket Real-Time Loop Monitoring                  | 🟢       | 🟡       | **LOW**         | Observability |

---

## PHASE 1 (Weeks 1-4): Convergence & Cost

### #1 Semantic Trajectory Analysis + Convergence Detection

**What it does:** Tracks embedding-space distance of consecutive agent outputs; detects stuck (contractive) vs wandering (exploratory) loops

**Why it matters:**

- Current: Hard iteration limit (5 iterations) wastes compute on stuck loops
- SOTA: Geometric Dynamics paper (arxiv 2512.10350) shows regime detection enables early exit
- Impact: 25-40% iteration waste reduction

**How to implement:**

1. On each loop iteration: encode agent output to embedding space (use Claude's embeddings)
2. Compute cosine distance to previous iteration's embedding
3. Track distance trend (contracting = converging, diverging = exploring)
4. Early exit if contracting + distance < threshold
5. Escalate to longer thinking if diverging unbounded

**Effort:** Medium (embedding integration, vector math, tracking state)  
**Blocking:** Nothing (can implement in isolation)  
**Files to modify:** `sw-loop.sh`, `sw-convergence-test.sh`

---

### #5 Speculative Cascade Model Routing

**What it does:** Try Haiku first (short timeout), escalate to Sonnet → Opus on failure

**Why it matters:**

- Current: Pick model upfront (per `--effort` flag), no escalation
- SOTA: Google Speculative Cascades paper; 30-60% cost reduction on median tasks
- Impact: 40-60% cost reduction while maintaining quality

**How to implement:**

1. Build failure prediction model: (query_type, difficulty) → success_rate on Haiku
2. For new query: estimate difficulty via embedding similarity
3. Route to Haiku with timeout (e.g., 30s)
4. If timeout/failure (tests fail), cascade to Sonnet, then Opus
5. Track cascade effectiveness per query type in memory

**Effort:** Medium (timeout management, cascade orchestration, tracking)  
**Blocking:** Nothing  
**Files to modify:** `sw-model-router.sh`, `sw-loop.sh`, new: `sw-cascade-router.sh`

---

## PHASE 2 (Weeks 5-8): Security & Testing

### #3 Vulnerability Reward Model + Online RL Hardening

**What it does:** Add security signals (detected vulnerabilities, CWE patterns) to reward model; enable vulnerability-aware RL

**Why it matters:**

- Current: Reward signals are functional-only (test pass, coverage)
- SOTA: Meta's SecCoderX, Anthropic's security research
- Impact: 30-40% security issue reduction; compliance-ready code

**How to implement:**

1. Integrate lightweight SAST (e.g., Semgrep, bandit, Trivy)
2. Run on generated code; extract (vulnerability_count, cwe_classes)
3. Add to reward signal as negative reward: reward -= vulnerability_count \* weight
4. Store effective security fixes in episodic memory
5. Fine-tune on secure code examples

**Effort:** Medium (scanner integration, signal weighting, RL loop)  
**Blocking:** Nothing  
**Files to modify:** `sw-reward-aggregator.sh`, `sw-rl-optimizer.sh`, new: `sw-security-reward.sh`

---

### #6 Mutation Testing Feedback Loop

**What it does:** Validate test quality by checking % of mutants killed; regenerate tests if score low

**Why it matters:**

- Current: Coverage metrics inflated; 45% of LLM-generated tests are ineffective
- SOTA: Meta ACH, MutGen papers show mutation feedback improves test quality
- Impact: 30-40% better test effectiveness; catches subtle bugs

**How to implement:**

1. After test generation: run mutation tool (Major, PIT) on code
2. Run generated tests against mutants; compute mutation_score = killed / total
3. If score < threshold (e.g., 80%): add feedback to testgen prompt
4. Regenerate tests with mutation feedback
5. Store effective test patterns for reuse

**Effort:** Medium (mutation tool integration, feedback loop)  
**Blocking:** Nothing  
**Files to modify:** `sw-testgen.sh`, new: `sw-mutation-validator.sh`

---

### #13 Multi-Pass Mutation Generation (LLM-based)

**What it does:** Use LLM to generate diverse mutants (not just rule-based); Meta-style compliance

**Why it matters:**

- Current: Traditional mutation tools (Major) have limited operators
- SOTA: GPT-4o/DeepSeek-R1 generate 57 different AST node types vs 2 for rules
- Impact: Better mutation diversity; more confident test validation

**How to implement:**

1. Take source code + list of mutation types
2. Prompt LLM: "Generate N mutants that change behavior but keep syntax valid"
3. Validate mutants compile + are distinct from originals
4. Run tests; track mutation score
5. Feed back into testgen loop if coverage is low

**Effort:** High (prompt engineering, mutation validation)  
**Blocking:** Nothing  
**Files to modify:** new: `sw-llm-mutant-generator.sh`

---

## PHASE 3 (Weeks 9-12): Memory & Self-Healing

### #4 Episodic Memory Layer

**What it does:** Store complete execution traces (inputs, actions, outcomes); enable case-based reasoning

**Why it matters:**

- Current: Memory is pattern-based ("when X fails, do Y")
- SOTA: Mem0, EM-LLM, MemRL papers show episodic learning 20-35% faster
- Impact: Case-based analogy; long-horizon self-improvement

**How to implement:**

1. On each pipeline run: capture episode JSON (inputs, agent_actions, outputs, duration, cost, test_results)
2. Store in episodic DB (SQLite + JSON or Postgres)
3. Query: "Find 3 similar past episodes" (via embedding similarity)
4. Inject case as few-shot examples into new agent prompts
5. Active compression: every 10 episodes, consolidate → semantic facts

**Effort:** High (episode storage, retrieval, compression)  
**Blocking:** Nothing  
**Files to modify:** `sw-memory.sh`, new: `sw-episodic-memory.sh`

---

### #7 CI Repair Agent

**What it does:** When test/check fails, spawn repair agent to diagnose & fix root cause

**Why it matters:**

- Current: Retries on failure; no diagnosis
- SOTA: Pipeline Doctor pattern (2026 AIOps trend); 67% MTTR drop
- Impact: 50% fewer retries; faster merge times

**How to implement:**

1. Detect test/check failure (via CI logs)
2. Classify failure: timeout, race condition, assertion, resource, flaky
3. Spawn repair agent with failure context (logs, git diff, error)
4. Agent proposes fix (increase timeout, add sync, skip flaky test, etc.)
5. Re-run test; if passes, commit repair
6. Track effective repairs in memory

**Effort:** High (log parsing, classification, repair proposals, commit management)  
**Blocking:** Nothing  
**Files to modify:** `sw-ci.sh`, new: `sw-repair-agent.sh`

---

### #8 LLM-as-a-Judge Validation

**What it does:** Secondary model evaluates primary agent output; triggers repair if needed

**Why it matters:**

- Current: Quality gates are rule-based (coverage > X%, no ASan)
- SOTA: 2026 standard design pattern for agentic systems
- Impact: 10-15% fewer merge regressions; catches issues rules miss

**How to implement:**

1. After primary agent completes task: send code + acceptance criteria to Judge model
2. Judge evaluates: "Does this code meet requirements? Any issues?"
3. If Judge flags issues: auto-trigger repair agent or escalate
4. Log Judge decisions for learning
5. Track Judge accuracy (via post-merge bug rates)

**Effort:** Medium (prompt engineering, logic orchestration)  
**Blocking:** Nothing  
**Files to modify:** `sw-quality.sh`, new: `sw-judge.sh`

---

## TIER 2 Items (Brief Summary)

| #   | Feature                               | Quick Implementation Path                                                      |
| --- | ------------------------------------- | ------------------------------------------------------------------------------ |
| #2  | Intent Specification Engine           | Research phase; build DSL for constraints; integrate formal spec generation    |
| #9  | Conflict Detection + DAG              | Track file locks per agent; build task DAG scheduler; merge conflict resolver  |
| #10 | Reasoning Budget Allocation           | Track thinking cost vs outcome; build (task_type, complexity) → tokens lookup  |
| #11 | Formal Verification (Dafny/Lean)      | Integrate theorem prover APIs; generate specs; gate merge on proof completion  |
| #12 | Active Context Compression            | EM-LLM approach: Bayesian surprise + graph refinement for episode boundaries   |
| #14 | Anomaly Detection + Predictive Repair | Time-series analysis on logs; ML model for failure prediction; repair triggers |
| #15 | Cross-Repo Fleet Learning             | Share patterns via fleet event bus; rank patterns by repo similarity           |

---

## Implementation Checklist

### PHASE 1 (Target: 2 weeks per item)

- [ ] #1 Semantic trajectory analysis
  - [ ] Embedding integration
  - [ ] Distance tracking + regime classification
  - [ ] Early exit logic
  - [ ] Tests + monitoring
- [ ] #5 Speculative cascade routing
  - [ ] Failure prediction model
  - [ ] Cascade orchestration
  - [ ] Timeout management
  - [ ] Tracking + learning

### PHASE 2 (Target: 1.5-2 weeks per item)

- [ ] #3 Vulnerability reward model
- [ ] #6 Mutation testing loop
- [ ] #13 LLM-based mutants

### PHASE 3 (Target: 2-3 weeks per item)

- [ ] #4 Episodic memory layer
- [ ] #7 CI repair agent
- [ ] #8 LLM-as-a-Judge

---

## Success Metrics (Post-Implementation)

| Feature             | Metric                              | Target  | Current  |
| ------------------- | ----------------------------------- | ------- | -------- |
| #1 Loop convergence | Iteration waste reduction           | -25-40% | Baseline |
| #5 Cascade routing  | Cost reduction on median tasks      | -40-60% | Baseline |
| #3 Security rewards | Bug reduction                       | -30-40% | Current  |
| #6 Mutation testing | Test effectiveness (mutation score) | >80%    | ~60%     |
| #4 Episodic memory  | Solution time on similar tasks      | -20-35% | Baseline |
| #7 CI repair        | Retry cycles                        | -50%    | Baseline |
| Overall             | Pipeline success rate               | >85%    | ~77%     |

---

## Dependencies & Blocking Relationships

```
#1 (trajectory) ─────┐
                     ├──→ #5 (cascade) ──→ Cost optimization ✓
                     │
#2 (intent)  [research phase; no immediate blocks]

#3 (vulnerability) ──┐
#6 (mutations)       ├──→ Security + Testing quality
#13 (LLM mutants) ───┘

#4 (episodic) ───────┐
#12 (compression) ───┤
#15 (fleet learning) ┤ All feed each other; can implement in parallel
                     └──→ Long-horizon learning

#7 (CI repair) ──┐
#8 (judge)       └──→ Quality gates

No critical blocking path: all items can start immediately with risk.
Recommend: Start #1 + #5 in week 1, #3 + #6 in week 5, #4 + #7 in week 9.
```

---

## Cost-Benefit Analysis

### Immediate ROI (Phase 1-2, Weeks 1-8)

**Investment:**

- 2 engineers × 8 weeks @ $200K/year = ~$60K engineering cost
- Compute for research + prototyping = ~$5K

**Returns (Annual):**

- Cost reduction via cascade: 40-60% savings on compute (current $50K/month → $20-30K) = **$240-360K/year**
- Faster iteration: 30% speedup on 200 pipelines/month × $5/pipeline = **$30K/year**
- Security improvement: 30-40% fewer CVEs → reduced incident response = **$50K+ saved**

**Total Annual ROI: $320-440K on $65K investment = 5-7x**

### Long-Term ROI (Phase 3 + Beyond, Weeks 9-26)

**Additional returns:**

- Episodic memory: 20-35% faster solutions × 200 pipelines = **$50-85K/year**
- Self-healing CI: 50% fewer retries = **$30K/year** (fewer human reviews)
- Fleet learning: 20% faster on new projects = **$40K/year**

**Total Long-Term ROI: $440-555K on $120K investment = 3-4x**

---

## Next Steps

1. **This week:** Review [CUTTING_EDGE_RESEARCH_2026.md](./CUTTING_EDGE_RESEARCH_2026.md) for full details on each feature
2. **Next week:** Spike on #1 (trajectory analysis) — prototype embedding-space distance tracking
3. **Following week:** Begin #5 (cascade routing) and #3 (vulnerability rewards) in parallel
4. **Week 4+:** Ramp up to PHASE 2 items as Phase 1 items ship

---

**Generated:** April 4, 2026  
**Total research effort:** 50+ sources, 25+ papers, 8 research areas  
**Full report:** See CUTTING_EDGE_RESEARCH_2026.md (comprehensive analysis)
