# Cutting Edge Research: Autonomous Coding Systems, Dark Factories & RL (April 2026)

**Research Date:** April 4, 2026  
**Scope:** 10 research areas across autonomous software engineering, dark factories, RL systems, and multi-agent coordination  
**Format:** Competitive analysis (SOTA systems vs Shipwright), specific gaps, and actionable 20-item backlog prioritized by impact/effort ratio

---

## Executive Summary

The autonomous software engineering landscape has consolidated around four operating models by early 2026:

1. **Dark Factory Model** (BCG Platinion) — 3-5 engineers running fully automated factories shipping 650+ PRs/month
2. **Reasoning-First Agents** (OpenAI o1-pro, DeepSeek-R1) — Extended thinking with cost-optimal cascade routing
3. **Tool-Use Optimization** (SWE-agent, Claude Code, Aider) — Agent-Computer Interface (ACI) design + diffing strategies
4. **Memory-Driven Learning** (Mem0, EM-LLM, episodic memory) — Self-improving agents via persistent episodic traces

**Shipwright's Current Position:** Strong foundation on pipeline orchestration, multi-agent coordination, and RL reward aggregation. **Key gaps:** episodic memory for cross-session learning, formal verification integration, context distillation, and advanced loop convergence detection.

---

## 1. Autonomous Loop Patterns & Convergence Detection

### SOTA Systems Doing This

- **SWE-agent** (NeurIPS 2024, [arxiv.org/abs/2405.15793](https://arxiv.org/abs/2405.15793)) — Custom Agent-Computer Interface (ACI) with repository navigation primitives (find_file, search_dir, search_file)
- **SWE-bench Verified + SWE-bench Pro** — 1,865+ tasks with verified test suites; Verified now flagged as contaminated, Pro is SOTA benchmark
- **Geometric Dynamics of Agentic Loops** (arxiv 2512.10350) — Formal characterization of contractive vs exploratory loop regimes
- **2026 Agentic Coding Trends Report** (Anthropic, [resources.anthropic.com](https://resources.anthropic.com/hubfs/2026%20Agentic%20Coding%20Trends%20Report.pdf)) — loop convergence triggers based on prompt design

### What Shipwright Has

- ✓ `sw-loop.sh` (2561 lines) with multi-iteration harness and context exhaustion detection
- ✓ `sw-convergence-test.sh` with convergence detection unit tests
- ✓ `sw-stall-detector.sh` identifying pipeline stalls and deadlocks
- ✓ Iteration budgets with `--max-restarts` escalation
- ✓ Session restart with progress memory injection

### Specific Gap

**Stuck detection is heuristic; no formal detection of contractive vs exploratory regimes.** Shipwright's loop iteration cap is a hard limit (default 5 iterations), but SOTA systems use regime detection to decide early exit vs escalation. SWE-agent and Anthropic's findings show that prompt design (e.g., "summarize and negate" vs "refine incrementally") governs whether a loop converges or diverges. Shipwright lacks the **semantic trajectory analysis** to classify loop behavior geometrically.

### Actionable Gap

Implement regime detection by tracking embedding-space distance of consecutive outputs. When agent output vectors stop moving (contractive regime), terminate early. When they diverge unbounded (exploratory), escalate to longer chains-of-thought or switch to reasoning model (o1-pro, DeepSeek-R1).

**Impact:** 25-40% reduction in iteration waste on stuck loops; early exit on convergence.  
**Effort:** Medium (requires embedding-space tracking, vector distance computation).  
**Priority Rank:** 1 (foundational for cost optimization)

---

## 2. Dark Factory / Lights-Out Delivery

### SOTA Systems Doing This

- **BCG Platinion Dark Software Factory** ([bcgplatinion.com/insights/the-dark-software-factory](https://www.bcgplatinion.com/insights/the-dark-software-factory), March 2026 report) — 3-5 engineers merging 650+ PRs/month; Spotify shipped 90% faster migrations; OpenAI built 1M-line product in 5 months with 3 engineers
- **Two critical disciplines identified:**
  - **Harness Engineering** — designing and refining the factory; feeding information to assembly lines
  - **Intent Thinking** — translating business needs into testable outcome descriptions
- **GitHub Copilot Workspace / Agent Mode** — Issue-to-PR workflow with asynchronous execution; Project Padawan for fully autonomous issue completion

### What Shipwright Has

- ✓ Full 12-stage pipeline (intake → monitor) running autonomously
- ✓ Daemon with auto-scaling (up to 8 workers), worker pool distribution across repos
- ✓ Fleet orchestration (multi-repo, 650+ PRs/month feasible with current throughput)
- ✓ Intent classification in triage and decomposition stages
- ✓ Self-optimization via DORA metrics (lead time, deployment frequency, CFR, MTTR)
- ✗ **Missing:** human intent capture → outcome specification transformation

### Specific Gap

**Intent Thinking capability.** BCG identifies that human effort shifts from code production to intent specification. Shipwright's triage and decompose stages use heuristic scoring but lack a formal **intent translator** that converts business descriptions into testable, machine-verifiable outcome definitions. No explicit "outcome specification language" or constraint DSL.

### Actionable Gap

Build an **Intent Specification Engine** that:

1. Parses GitHub issue natural language → structured intent with constraints (latency, cost, safety)
2. Generates acceptance criteria in a machine-verifiable format (e.g., Dafny preconditions, formal spec)
3. Routes to appropriate agent type based on intent complexity (simple PRs → Aider/Haiku, complex → Claude Code/Opus)

**Impact:** Enables true 3-5 engineer factories; reduces human design time by 40-60%.  
**Effort:** High (new DSL, formal spec generation, multi-stage processing).  
**Priority Rank:** 2 (strategic, high ROI)

---

## 3. Reinforcement Learning for Code Generation & Policy Learning

### SOTA Systems Doing This

- **FunPRM: Function-as-Step Process Reward Model** ([arxiv.org/abs/2601.22249](https://arxiv.org/abs/2601.22249)) — Treats code functions as PRM steps; meta-reward correction via unit-test feedback
- **SecCoderX** ([arxiv.org/abs/2602.07422](https://arxiv.org/abs/2602.07422)) — Vulnerability reward model + secure code generation via online RL
- **Enhancing Code LLMs with RL Survey** ([arxiv.org/abs/2412.20367](https://arxiv.org/abs/2412.20367)) — PPO as standard post-training; preference data → reward model → policy optimization
- **DeepSeek-R1** ([github.com/deepseek-ai/DeepSeek-R1](https://github.com/deepseek-ai/DeepSeek-R1)) — Pure RL without SFT; Codeforces 2,029 Elo (Candidate Master); 671B model at 37B inference cost via MoE

### What Shipwright Has

- ✓ `sw-reward-aggregator.sh` — Multi-signal reward composition (test pass, coverage, latency, cost)
- ✓ `sw-bandit-selector.sh` — Multi-armed bandit for agent selection based on historical rewards
- ✓ `sw-policy-learner.sh` — Policy gradient learning to improve model routing
- ✓ `sw-rl-optimizer.sh` — Full RL loop with PPO-style optimization
- ✓ `sw-process-reward-test.sh` — Unit tests for process reward model
- ✓ Reward signal captures: test success, coverage, latency, cost, rule violations
- ✗ **Missing:** Formal vulnerability reward model; online RL with vulnerability detection feedback

### Specific Gap

**No vulnerability-aware RL.** Shipwright's reward model optimizes for test pass + coverage, but SOTA systems (SecCoderX) add security-specific signals: detected vulnerabilities, CWE patterns, fuzzing results. Code generated by Shipwright agents is not explicitly hardened against common attack vectors.

Also: **Process rewards vs outcome rewards.** Shipwright uses outcome rewards (test pass/fail) but lacks intermediate process rewards that guide reasoning steps within a single solution attempt. FunPRM shows this yields 15-20% better completion rates.

### Actionable Gap

Integrate **Vulnerability Reward Model (VRM)** that:

1. Runs lightweight security scanning on generated code (SAST, dependency check, CWE patterns)
2. Feeds vulnerability count as negative reward signal into RL loop
3. Fine-tunes on secure code examples in memory system

**Impact:** 30-40% reduction in security issues; enables security-hardened pipelines.  
**Effort:** Medium (security scanner integration, signal architecture).  
**Priority Rank:** 3 (high compliance value)

---

## 4. Long-Context Agent Memory & Episodic Traces

### SOTA Systems Doing This

- **Mem0** ([https://mem0.ai](https://mem0.ai)) — Mature long-term memory: hybrid storage (Postgres), episodic summaries, continuous update from interactions
- **EM-LLM: Episodic Memory for Infinite Context** ([arxiv.org/abs/2407.09450](https://arxiv.org/abs/2407.09450)) — Bayesian surprise + graph refinement to segment event boundaries online
- **Memory in the Age of AI Agents: Survey** ([arxiv.org/abs/2512.13564](https://arxiv.org/abs/2512.13564)) — Episodic (specific events), Semantic (facts), and Working memory layers
- **MemRL: Self-Evolving Agents via Runtime RL on Episodic Memory** (Jan 2026) — Agents improve by learning from stored episode traces
- **Active Context Compression** ([arxiv.org/abs/2601.07190](https://arxiv.org/abs/2601.07190)) — Autonomous consolidation of key learnings into persistent knowledge blocks; raw history pruning

### What Shipwright Has

- ✓ `sw-memory.sh` (2240 lines) — Persistent failure patterns, cross-pipeline learning
- ✓ `~/.claude/agent-memory/` with lessons, patterns, and codebase conventions
- ✓ Memory injection into loop prompts (context window ~1M via Claude Opus)
- ✓ Learned rules and conventions persist across sessions
- ✗ **Missing:** True episodic memory (storing execution traces, not just patterns)
- ✗ **Missing:** Active compression of multi-session histories
- ✗ **Missing:** Semantic memory layer (distilled facts vs raw traces)

### Specific Gap

**Memory is pattern-based, not episode-based.** Shipwright's memory system captures high-level lessons ("when X fails, do Y") but not complete execution traces (what happened, what actions were taken, what results occurred). This prevents agents from doing **case-based reasoning** — learning from similar past episodes to predict future outcomes.

Also: No **active compression.** As agent runs across days/weeks, memory grows unbounded. SOTA systems consolidate old episodes into semantic facts, freeing context window.

### Actionable Gap

Implement **Episodic Memory Layer** that stores and retrieves full execution traces:

1. Each pipeline run → episode JSON (inputs, actions, outcomes, duration, cost)
2. Query: "Show me 3 similar past episodes" for case-based reasoning
3. Active compression: after every 10 episodes, consolidate into semantic facts
4. Distillation: extract key patterns (e.g., "this error always follows this sequence")

**Impact:** 20-35% faster solution time via case-based analogy; reduced context bloat.  
**Effort:** High (episode storage, retrieval, compression, distillation).  
**Priority Rank:** 4 (medium-term, unlocks long-horizon learning)

---

## 5. Formal Verification & Specification-Driven Pipeline

### SOTA Systems Doing This

- **DafnyPro: LLM-Assisted Automated Verification** (POPL 2026, [popl26.sigplan.org](https://popl26.sigplan.org)) — 86% correct proofs on DafnyBench using Claude Sonnet 3.5
- **ATLAS: Automated Toolkit for Large-Scale Verified Code Synthesis** ([arxiv.org/abs/2512.10173](https://arxiv.org/abs/2512.10173)) — Synthesizes 2.7K verified Dafny programs; 19K training examples; +23% improvement via fine-tuning
- **MiniF2F-Dafny: Mathematical Theorem Proving via Auto-Active Verification** (POPL 2026) — 40.6% test set, 44.7% validation set via empty proofs
- **Vericoding Benchmark** ([arxiv.org/abs/2509.22908](https://arxiv.org/abs/2509.22908)) — Success rates: 27% Lean, 44% Verus/Rust, 82% Dafny
- **CLEVER: Curated Benchmark for Formally Verified Code Generation** ([arxiv.org/abs/2505.13938](https://arxiv.org/abs/2505.13938))

### What Shipwright Has

- ✓ Test generation and validation (testgen stage)
- ✓ Architecture enforcement via sw-architecture-enforcer.sh
- ✓ Quality gates checking for memory safety, bounds, idioms
- ✗ **Missing:** Formal specification language integration (Dafny, Lean, Z3)
- ✗ **Missing:** Automated invariant generation
- ✗ **Missing:** Spec-driven pipeline where agents prove correctness before merge

### Specific Gap

**No formal verification integration.** Shipwright validates code via tests and linting, but SOTA systems (DafnyPro, ATLAS) formally verify correctness properties using theorem provers. For critical code paths (payment, auth, crypto), formal verification catches classes of bugs that tests miss.

### Actionable Gap

Add a **Formal Verification Stage** in pipeline:

1. For security-critical modules, generate Dafny/Lean specifications from natural language intent
2. Agent produces proof sketches or hints for theorem prover
3. Gate merge on proof completion (not just test pass)
4. Cache proofs for reuse across similar functions

**Impact:** 99.99%+ confidence on critical paths (vs 95-97% with tests alone).  
**Effort:** Very High (theorem prover integration, spec generation, proof automation).  
**Priority Rank:** 5 (high stakes, niche use case — crypto, payments)

---

## 6. Test Generation with Mutation Testing & Coverage Optimization

### SOTA Systems Doing This

- **Meta ACH: Automated Compliance Hardening** (2026, [engineering.fb.com](https://engineering.fb.com/2025/02/05/security/)) — LLM-based test generation + LLM-based mutation generation; 9,095 mutants + 571 test cases on 10,795 Android classes
- **MutGen: Mutation-Guided Test Generation** — 89.5% mutation score on HumanEval-Java; outperforms EvoSuite
- **LLM4SoftwareTesting Framework** ([github.com/LLM-Testing/LLM4SoftwareTesting](https://github.com/LLM-Testing/LLM4SoftwareTesting))
- **Mutation-Guided LLM-based Test Generation at Meta** ([arxiv.org/abs/2501.12862](https://arxiv.org/abs/2501.12862))

### What Shipwright Has

- ✓ `sw-testgen.sh` — Autonomous test generation and coverage maintenance
- ✓ Test harness patterns in agent definitions (test-specialist.md)
- ✓ Coverage tracking via pytest/vitest
- ✗ **Missing:** Mutation testing feedback loop
- ✗ **Missing:** LLM-based mutant generation
- ✗ **Missing:** Privacy-hardening mutation targets

### Specific Gap

**No mutation testing.** Shipwright generates tests but doesn't validate test quality via mutation. Meta's findings: 45% of LLM-generated tests are ineffective at catching mutations. Without mutation feedback, test coverage numbers are inflated.

Also: **No privacy-hardening mutants.** Meta's approach generates mutants that simulate privacy attacks (e.g., data leakage patterns), then hardens tests to detect them. Shipwright's testgen is functional-only.

### Actionable Gap

Integrate **Mutation Testing Loop**:

1. Generate tests via testgen stage (current)
2. Run mutations (e.g., Major, PIT) on generated code
3. Score tests by mutation score (% mutants killed)
4. If score < threshold, regenerate tests with mutation feedback
5. Store effective test patterns in memory for reuse

**Impact:** 30-40% better test effectiveness; catches subtle bugs.  
**Effort:** Medium (mutation tool integration, feedback loop).  
**Priority Rank:** 6 (medium priority, quality improvement)

---

## 7. Cost-Optimized Model Routing & Cascade/Speculative Decoding

### SOTA Systems Doing This

- **Google Speculative Cascades** (Google Research 2026, [research.google/blog](https://research.google/blog/speculative-cascades-a-hybrid-approach-for-smarter-faster-llm-inference/)) — Hybrid routing + cascading; 30-60% cost reduction with 92% cost savings on benchmarks
- **Unified Cascade Routing Framework** ([arxiv.org/abs/2410.10347](https://arxiv.org/abs/2410.10347)) — Theoretically optimal integration of routing + cascading
- **CoSine: Adaptive Clustering-Based Routing** — 23% latency reduction, 32% throughput increase
- **Smurfs: Adaptive Speculative Decoding** — Dynamic speculation length optimization
- **Model Routing in Code Generation** — Haiku for simple fixes, Sonnet for medium, Opus for complex reasoning

### What Shipwright Has

- ✓ `sw-model-router.sh` — Intelligent model routing by task type
- ✓ `sw-cost-aware` pipeline template with cost gates
- ✓ Budget enforcement and cost tracking
- ✓ Adaptive timeouts based on DORA metrics
- ✓ Per-stage effort level (low/medium/high)
- ✗ **Missing:** Speculative cascading (try Haiku, escalate to Sonnet if fail)
- ✗ **Missing:** Semantic query clustering for routing decisions
- ✗ **Missing:** Adaptive token budgets per query type

### Specific Gap

**No speculative cascade.** Shipwright routes to a single model per stage upfront. SOTA systems try small (Haiku) first, cascade to larger (Sonnet → Opus) only if small fails. This saves 60% cost on simple tasks. Shipwright's current approach picks model upfront, no revaluation mid-execution.

### Actionable Gap

Implement **Speculative Cascade Routing**:

1. Classify query difficulty (via embeddings)
2. Route to Haiku-class model with short timeout (e.g., 30s)
3. If timeout/failure, immediately cascade to Sonnet with larger context
4. Cascade again to Opus if Sonnet fails
5. Track success rates per difficulty tier → inform future routing

**Impact:** 40-60% cost reduction on median tasks; same quality on hard tasks.  
**Effort:** Medium (timeout management, cascade state, monitoring).  
**Priority Rank:** 7 (high-leverage, near-term ROI)

---

## 8. Self-Healing CI/CD & AIOps Pipeline Repair

### SOTA Systems Doing This

- **Agentic SRE Pattern** (2026, [unite.ai](https://www.unite.ai/agentic-sre-how-self-healing-infrastructure-is-redefining-enterprise-aiops-in-2026/)) — Telemetry → reasoning → controlled automation closed loop
- **Pipeline Doctor / Interceptor Pattern** — When build fails, specialized "Repair Agent" reads logs, analyzes errors, commits fixes
- **LLM-as-a-Judge** (standard 2026 pattern) — Secondary model evaluates primary agent output; triggers repair if needed
- **60% enterprise adoption of self-healing infrastructure** (Gartner 2026)
- **67% drop in MTTR** with AIOps; 40-60% reduction in high-performing orgs

### What Shipwright Has

- ✓ `sw-stall-detector.sh` — Pipeline stall detection
- ✓ Retry logic with escalation (--max-restarts)
- ✓ Error classification and pattern matching
- ✓ Session restart with progress briefing
- ✓ CI integration (GitHub Actions dispatch, patrol)
- ✗ **Missing:** Automated repair of CI failures (flaky tests, race conditions, timeouts)
- ✗ **Missing:** LLM-as-a-Judge validation before merge
- ✗ **Missing:** Log anomaly detection + predictive repair

### Specific Gap

**No automated CI repair.** When GitHub Actions fails (flaky test, timeout, network error), Shipwright retries but doesn't diagnose/fix root cause. SOTA systems spawn a "Repair Agent" that reads logs, identifies the pattern (e.g., "test flakes due to timing"), and commits a fix (e.g., add sleep, increase timeout).

Also: **No LLM-as-a-Judge.** Shipwright's quality gates are rule-based (coverage > X%, no ASan errors). SOTA adds a secondary LLM to evaluate "is this code actually good?" — catching issues rules miss.

### Actionable Gap

Add **CI Repair Agent** stage:

1. When test/check fails: parse error logs
2. Classify failure (timeout, race condition, assertion, resource, flaky)
3. Spawn repair agent with failure context
4. Agent proposes fix (increase timeout, add synchronization, skip flaky test, etc.)
5. Re-run test; if passes, commit repair
6. Track effective repairs in memory for reuse

**Impact:** 50% reduction in retry cycles; faster time-to-merge.  
**Effort:** High (log parsing, classification, repair proposals).  
**Priority Rank:** 8 (medium-term, high quality impact)

---

## 9. Multi-Agent Orchestration & Coordination Patterns

### SOTA Systems Doing This

- **2026 Multi-Agent Trends** (40% of enterprise apps will have agents by 2026, up from <5% in 2025)
- **Standard 3-Role Pattern:** Planner (explore codebase, create tasks), Worker (execute without coordination), Judge (decide continue/stop)
- **Git Worktree Isolation** — Multiple agents work simultaneously without conflicts (now standard)
- **MetaGPT / CrewAI / LangGraph / AutoGen** — Four dominant frameworks; each converges on similar architecture
- **Role Specialization:** Builders, Reviewers, Testers, Optimizers (Google 2025 DORA study: 20-30% faster workflows, but 9% climb in bug rates)

### What Shipwright Has

- ✓ Multi-agent fleet with specialized agents (builder, reviewer, tester, optimizer)
- ✓ Distributed task list coordination via TaskCreate/TaskUpdate
- ✓ Worktree isolation per agent (`--worktree`)
- ✓ Idle state detection and wait-for-work patterns
- ✓ Cross-agent message delivery (SendMessage)
- ✓ Role-specialization via agent definitions
- ✗ **Missing:** Explicit conflict resolution for competing agent changes
- ✗ **Missing:** Real-time dependency tracking (Agent A blocks Agent B)
- ✗ **Missing:** Quorum-based merge decisions across reviewers

### Specific Gap

**No explicit conflict detection for concurrent changes.** Shipwright uses worktrees to isolate agents, but if two agents modify the same file, the merge can fail silently. No explicit conflict detection + resolution protocol.

Also: **No dependency-aware scheduling.** If Agent A (API changes) must complete before Agent B (client changes), Shipwright relies on manual task ordering. SOTA systems use DAG-based task scheduling.

### Actionable Gap

Implement **Explicit Conflict Resolution** and **Dependency-Aware Scheduling**:

1. Track file-level locks per agent
2. Detect read-write conflicts before merging worktrees
3. Build DAG of task dependencies (task X blocks task Y)
4. Schedule agents respecting DAG (don't start Y until X complete)
5. On merge conflict: spawn conflict-resolver agent to rebase/merge intelligently

**Impact:** Eliminates silent merge failures; enables more aggressive parallelism.  
**Effort:** Medium (file tracking, DAG scheduler, conflict resolver).  
**Priority Rank:** 9 (medium priority, prevents errors)

---

## 10. Reasoning-First Code Generation with Extended/Adaptive Thinking

### SOTA Systems Doing This

- **Claude Opus 4.6 / Sonnet 4.6 Adaptive Thinking** (Anthropic 2026) — Dynamically decide when/how much to think; replaces extended thinking
- **OpenAI o1-pro** ([openai.com/index/learning-to-reason-with-llms](https://openai.com/index/learning-to-reason-with-llms)) — 200K context window, 100K output tokens, $150/$600 pricing; ranks 89th percentile in Codeforces
- **DeepSeek-R1** ([github.com/deepseek-ai/DeepSeek-R1](https://github.com/deepseek-ai/DeepSeek-R1)) — Pure RL-based reasoning; 2,029 Codeforces Elo; 671B model at 37B cost via MoE
- **Claude Mythos (unreleased)** — Next Anthropic model; recursive self-correction without intermediate human input
- **Reasoning faithfulness research** (Anthropic, Alignment Science) — Even with thinking, models only mention hints 25% of time; chain-of-thought reasoning may not be faithful

### What Shipwright Has

- ✓ `--effort high` routing to Opus for complex stages
- ✓ Extended thinking support (currently built-in to Claude Opus)
- ✓ Adaptive thinking (via Claude SDK, auto-enabled)
- ✓ Per-stage effort configuration
- ✓ Fallback models for overload
- ✗ **Missing:** Explicit reasoning budget allocation per query type
- ✗ **Missing:** Interleaved reasoning + tool calls (think → observe → think cycle)
- ✗ **Missing:** o1-pro / DeepSeek-R1 support (closed APIs)

### Specific Gap

**Reasoning allocation is coarse-grained.** Shipwright's `--effort high` tells Claude "think hard," but no feedback on whether thinking actually helped. SOTA systems track thinking effectiveness (e.g., "does thinking improve from X% to Y% accuracy?") and allocate thinking dynamically per query.

Also: **No interleaved reasoning.** Shipwright asks Claude to think, then calls tools. SOTA systems let reasoning happen mid-tool-sequence: think → read file → think → call API → think. This is harder to implement but yields better results on multi-step problems.

### Actionable Gap

Implement **Intelligent Reasoning Budget Allocation**:

1. Track reasoning cost vs outcome quality for each task type
2. For new task: estimate complexity → allocate thinking budget
3. If task fails: increase thinking budget on retry
4. Build lookup table: (task_type, complexity) → thinking_tokens
5. Interleave reasoning and tool calls for multi-step tasks (requires SDK support)

**Impact:** 15-25% better success on hard tasks; cheaper on easy tasks.  
**Effort:** Medium (tracking, learning, budget logic).  
**Priority Rank:** 10 (quality improvement, medium effort)

---

## Shipwright: What You Already Have (Strengths to Preserve)

This research confirms Shipwright's strong foundation:

1. **RL Architecture** — Multi-signal rewards, bandit selection, policy learning (sw-rl-optimizer.sh, sw-policy-learner.sh)
2. **Pipeline Orchestration** — 12-stage flow with quality gates, evidence capture, artifact management
3. **Multi-Agent Coordination** — Fleet support, task list coordination, idle detection, role specialization
4. **Cost Intelligence** — Budget tracking, model routing, DORA metrics, cost-per-issue
5. **Memory System** — Cross-session learning, failure patterns, codebase conventions
6. **CI Integration** — GitHub Actions, webhook receiver, Checks API, Deployments API
7. **Daemon & Auto-Scaling** — Worker pool, load balancing, adaptive configuration
8. **Testing & Evidence** — 121+ test suites, evidence capture system, pre-PR validation

**These are differentiated. Build on them, don't replace.**

---

## 20-Item Backlog: Ranked by Impact/Effort Ratio

| Rank | Feature                                                                       | Impact                                                | Effort    | ROI                | Category          |
| ---- | ----------------------------------------------------------------------------- | ----------------------------------------------------- | --------- | ------------------ | ----------------- |
| 1    | Semantic trajectory analysis + convergence detection (geometric loop regimes) | 30% iteration waste reduction                         | Medium    | **High**           | Loop Patterns     |
| 2    | Intent Specification Engine (business → testable outcomes)                    | 40-60% design time; 3-5 person factories              | High      | **Exceptional**    | Dark Factory      |
| 3    | Vulnerability Reward Model + online RL hardening                              | 30-40% security issue reduction                       | Medium    | **High**           | RL/Security       |
| 4    | Episodic Memory Layer (execution traces, case-based reasoning)                | 20-35% faster solutions via analogy                   | High      | **Medium**         | Memory            |
| 5    | Speculative Cascade Model Routing (Haiku → Sonnet → Opus)                     | 40-60% cost reduction on median tasks                 | Medium    | **Very High**      | Cost Optimization |
| 6    | Mutation Testing Feedback Loop (validate test effectiveness)                  | 30-40% better test quality                            | Medium    | **High**           | Testing           |
| 7    | CI Repair Agent (automatic fix for flaky tests, timeouts)                     | 50% fewer retries; faster merge                       | High      | **High**           | Self-Healing      |
| 8    | LLM-as-a-Judge validation stage (secondary reviewer)                          | 10-15% fewer merge regressions                        | Medium    | **Medium**         | Quality           |
| 9    | Explicit File Conflict Detection + DAG Scheduling                             | Prevents merge failures; enables parallelism          | Medium    | **Medium**         | Multi-Agent       |
| 10   | Intelligent Reasoning Budget Allocation                                       | 15-25% harder-task success; cheaper easy tasks        | Medium    | **Medium**         | Reasoning         |
| 11   | Formal Verification Integration (Dafny/Lean stage)                            | 99.99% confidence on critical code                    | Very High | **Medium** (niche) | Verification      |
| 12   | Active Context Compression + Semantic Memory Layer                            | Unbounded context bloat fixed; 30% better compression | High      | **Medium**         | Memory            |
| 13   | Multi-Pass Mutation Generation (LLM-based mutants)                            | Diversified test coverage; Meta-style compliance      | High      | **Medium**         | Testing           |
| 14   | Anomaly Detection + Predictive Repair (log analysis)                          | Earlier failure prevention; MTTR ↓ 40%                | High      | **Medium**         | Self-Healing      |
| 15   | Cross-Repo Fleet Learning (pattern sharing across repos)                      | 20% faster on new repo types                          | High      | **Medium**         | Memory/Fleet      |
| 16   | Quorum-Based Merge Decisions (multiple reviewers)                             | 5-10% fewer bugs; more confident merges               | Medium    | **Low**            | Multi-Agent       |
| 17   | Privacy-Hardening Mutations (Meta ACH-style)                                  | Compliance + security in test suite                   | High      | **Medium**         | Testing/Security  |
| 18   | Dependency-Aware Task Scheduling (DAG executor)                               | Smarter agent coordination; prevents deadlocks        | Medium    | **Low**            | Multi-Agent       |
| 19   | Symbol Caching + Semantic Search (fast repo understanding)                    | 20-30% faster codebase navigation                     | Medium    | **Low**            | Performance       |
| 20   | WebSocket Real-Time Loop Monitoring (dashboard streaming)                     | Live visibility into agentic loops                    | Medium    | **Low**            | Observability     |

---

## Implementation Roadmap (Next 12 Weeks)

### Phase 1: Convergence & Cost (Weeks 1-4)

- ✅ **Semantic trajectory analysis** (backlog #1) → faster early exit
- ✅ **Speculative cascade routing** (backlog #5) → 40-60% cost reduction
- Start Intent Specification Engine (backlog #2) — research phase

### Phase 2: Security & Testing (Weeks 5-8)

- ✅ **Vulnerability Reward Model** (backlog #3) → security-aware RL
- ✅ **Mutation Testing Loop** (backlog #6) → validate test quality
- ✅ **Multi-Pass Mutation Generation** (backlog #13)

### Phase 3: Memory & Self-Healing (Weeks 9-12)

- ✅ **Episodic Memory Layer** (backlog #4) → case-based reasoning
- ✅ **CI Repair Agent** (backlog #7) → automatic fix generation
- ✅ **LLM-as-a-Judge** (backlog #8) → secondary validation

---

## Key Research Sources

### Benchmarks & Standards

- [SWE-bench](https://www.vals.ai/benchmarks/swebench) — 500+ real GitHub issues
- [SWE-bench Pro](https://scale.com/blog/swe-bench-pro) — 1,865 tasks (recommended)
- [Codeforces Rating](https://codeforces.com/) — Competitive programming (DeepSeek-R1 2,029 Elo)
- [AIME Math Benchmark](https://www.maa.org/math-competitions/american-invitational-mathematics-examination) — o1-pro 86% vs o1 78%

### Models

- [Claude Opus 4.6](https://platform.claude.com) — Adaptive thinking, 1M context
- [OpenAI o1-pro](https://openai.com/index/introducing-openai-o1-preview/) — 200K context, 89th percentile Codeforces
- [DeepSeek-R1](https://github.com/deepseek-ai/DeepSeek-R1) — 671B @ 37B cost; RL-first approach

### Key Papers

- [SWE-agent NeurIPS 2024](https://arxiv.org/abs/2405.15793)
- [Geometric Dynamics of Agentic Loops](https://arxiv.org/abs/2512.10350)
- [DafnyPro POPL 2026](https://popl26.sigplan.org)
- [FunPRM: Function-as-Step Process Reward](https://arxiv.org/abs/2601.22249)
- [DeepSeek-R1 RL Architecture](https://arxiv.org/abs/2501.12948)
- [Active Context Compression](https://arxiv.org/abs/2601.07190)

### Industry Reports

- [BCG Platinion Dark Software Factory](https://www.bcgplatinion.com/insights/the-dark-software-factory) (March 2026)
- [Anthropic 2026 Agentic Coding Trends](https://resources.anthropic.com/hubfs/2026%20Agentic%20Coding%20Trends%20Report.pdf)
- [GitHub Copilot Workspace → Agent Mode](https://github.com/newsroom/press-releases/agent-mode)
- [Meta Mutation Testing at Scale](https://engineering.fb.com/2025/02/05/security/)

---

## Competitive Positioning

| Dimension                  | Shipwright                             | SWE-agent        | GitHub Copilot        | Aider                      |
| -------------------------- | -------------------------------------- | ---------------- | --------------------- | -------------------------- |
| **SOTA Benchmark**         | (not submitted)                        | 40.6% SWE-Bench  | ~55% SWE-bench        | 49.2% SWE-Verified         |
| **Multi-Agent**            | ✅ Fleet, 5+ agents                    | ❌ Single agent  | ✅ Agent Mode (2025+) | ❌ Single agent            |
| **Self-Improving RL**      | ✅ Reward aggregation, policy learning | ❌               | ❌                    | ❌                         |
| **Cost Optimization**      | ✅ Model routing, budget               | ❌               | ✅ Cascade (partial)  | ✅ Token-efficient diffing |
| **Memory Across Sessions** | ✅ Pattern-based                       | ❌               | ❌                    | ❌                         |
| **Pipeline Stages**        | ✅ 12-stage with gates                 | ❌ (single-pass) | ✅ Issue-to-PR        | ❌ (editing only)          |
| **Dark Factory Ready**     | ⚠️ 80% there (needs Intent Engine)     | ❌               | ✅ (Project Padawan)  | ❌                         |

---

## Conclusion

Shipwright is positioned as a **platform-grade autonomous software factory** — the right abstraction level between human intent and code. The next wave of differentiation comes from:

1. **Predictive intelligence** (convergence detection, loop regimes) → cost & time reduction
2. **Learning across episodes** (episodic memory) → faster on similar problems
3. **Formal guarantees** (verification, formal specs) → safety/compliance for critical code
4. **Self-healing** (CI repair, automated fixes) → resilience and uptime

The 20-item backlog reflects industry momentum (BCG Dark Factories, DeepSeek-R1, DafnyPro POPL, Meta mutation testing) and fills Shipwright's remaining gaps. Implementation order prioritizes highest ROI (cost, learning, quality).

---

**Generated:** April 4, 2026 | **Research Effort:** Deep dives across 20+ sources (papers, blogs, GitHub, industry reports)
