# Deep Research: Autonomous Coding Systems 2026 - Complete Index

**Research Date:** April 4, 2026  
**Scope:** Cutting-edge research on autonomous software engineering, dark factories, RL systems, and agent coordination  
**Status:** Complete (65 sources, 25+ papers, 10 research areas)

---

## Quick Start Guide

### For Product Strategy (15 min read)

1. Start with: **RESEARCH_SUMMARY.txt** (executive summary)
2. Skim: **BACKLOG_QUICK_REFERENCE.md** (priority matrix + ROI)
3. Deep dive: **CUTTING_EDGE_RESEARCH_2026.md** (sections #1-5)

### For Implementation Planning (30 min read)

1. Read: **BACKLOG_QUICK_REFERENCE.md** (full roadmap)
2. Reference: **RESEARCH_SOURCES.md** (key papers per feature)
3. Deep dive: **CUTTING_EDGE_RESEARCH_2026.md** (specific gap sections)

### For Architecture Decisions (60 min read)

1. Read: **CUTTING_EDGE_RESEARCH_2026.md** (entire document)
2. Cross-reference: **RESEARCH_SOURCES.md** (full URLs for papers)
3. Apply: **BACKLOG_QUICK_REFERENCE.md** (implementation checklist)

---

## Document Overview

### 1. CUTTING_EDGE_RESEARCH_2026.md (34 KB) ★ PRIMARY REPORT

**Content:**

- 10-area competitive analysis (loop patterns, dark factory, RL, memory, verification, testing, cost, self-healing, multi-agent, reasoning)
- SOTA systems deep-dive with specific examples and benchmarks
- Shipwright strengths (8 differentiated capabilities)
- Shipwright gaps (10 specific missing features)
- 20-item actionable backlog ranked by impact/effort ratio
- 3-phase 12-week implementation roadmap
- ROI analysis (5-7x immediate, 3-4x long-term)

**Best for:** Strategic decisions, identifying gaps, understanding SOTA landscape, implementation planning

**Key sections:**

- Section 1: Autonomous Loop Patterns (SWE-agent, geometric dynamics, convergence)
- Section 2: Dark Factory Model (BCG Platinion, 3-5 engineer factories)
- Section 3: RL for Code (FunPRM, SecCoderX, DeepSeek-R1)
- Section 4: Episodic Memory (Mem0, EM-LLM, active compression)
- Section 5: Formal Verification (DafnyPro, ATLAS, Dafny benchmarks)
- Section 6: Mutation Testing (Meta ACH, MutGen, diversity)
- Section 7: Cost Optimization (Google Cascades, routing frameworks)
- Section 8: Self-Healing CI/CD (Agentic SRE, Pipeline Doctor, MTTR)
- Section 9: Multi-Agent Coordination (3-role pattern, frameworks, conflicts)
- Section 10: Reasoning Models (Claude Opus 4.6, o1-pro, DeepSeek-R1)

---

### 2. BACKLOG_QUICK_REFERENCE.md (15 KB) ★ ACTIONABLE PRIORITY LIST

**Content:**

- Priority matrix (Rank, ID, Feature, Impact, Effort, ROI, Category)
- Top 8 items with implementation details
- 12-week phase-based roadmap
- Implementation checklist
- Success metrics
- Dependency graph
- Cost-benefit analysis
- Next steps timeline

**Best for:** Quick decision-making, sprint planning, ROI justification, tracking progress

**Key sections:**

- At-a-glance matrix (20 items ranked)
- Phase 1 items with full implementation guidance (#1, #5, #2 research)
- Phase 2 items (#3, #6, #13)
- Phase 3 items (#4, #7, #8)
- Tier 2 items summary (brief implementation paths)
- Dependency relationships
- Post-implementation success metrics
- Budget and timeline planning

---

### 3. RESEARCH_SOURCES.md (16 KB) ★ COMPLETE BIBLIOGRAPHY

**Content:**

- 60+ sources organized by research area
- Complete URLs for every paper, blog, report, tool
- Key findings extracted from each source
- Quick link summary grouped by backlog item
- Total coverage: 25+ academic papers, 15+ industry reports, 10+ GitHub repos

**Best for:** Finding original sources, deep diving on specific topics, citation, verification

**Key sections:**

- Dark Factory & Autonomous Delivery (BCG, Anthropic, GitHub)
- Autonomous Loop Patterns (SWE-agent, geometric dynamics, benchmarks)
- RL for Code Generation (FunPRM, SecCoderX, DeepSeek, Meta ACH)
- Reasoning Models (Claude, OpenAI o1-pro, alignment science)
- Memory Systems (Mem0, EM-LLM, episodic learning)
- Formal Verification (DafnyPro, ATLAS, benchmarks)
- Test Generation & Mutation (Meta, MutGen, LLMorpheus)
- Cost Optimization (Google Cascades, routing frameworks)
- Self-Healing CI/CD (Agentic SRE, AIOps, patterns)
- Multi-Agent Coordination (frameworks, patterns, DORA)
- Competitive Analysis (SWE-agent, Claude Code, Aider, Cline)

---

### 4. RESEARCH_SUMMARY.txt (plaintext, ~5 KB)

**Content:**

- Executive summary of all research
- Key findings by category
- Competitive analysis summary
- 20-item backlog summary
- ROI analysis
- Implementation roadmap
- Next steps

**Best for:** Email distribution, quick briefing, non-Markdown contexts

---

## Research Coverage by Topic

### Autonomous Loop Patterns & Convergence Detection

**SOTA Systems:**

- SWE-agent (NeurIPS 2024) — custom ACI, repository primitives
- Geometric Dynamics paper (arxiv 2512.10350) — formal regime characterization
- Anthropic 2026 report — convergence triggers via prompt design
- 220 loops study — stuck detection empirical data

**Shipwright Status:** Has basic convergence detection; missing formal regime analysis

**Backlog Item:** #1 (Semantic trajectory analysis) — Week 1

---

### Dark Factory / Lights-Out Delivery

**SOTA Systems:**

- BCG Platinion (March 2026) — 3-5 engineers, 650+ PRs/month, Spotify/OpenAI cases
- GitHub Copilot Agent Mode — Issue-to-PR workflow
- Project Padawan (upcoming) — fully autonomous issue completion

**Shipwright Status:** Has 12-stage pipeline; missing Intent Specification Engine

**Backlog Item:** #2 (Intent Specification Engine) — High impact, research phase Week 2

---

### Reinforcement Learning for Code Generation

**SOTA Systems:**

- FunPRM — function-as-step process rewards, +15-20% completion
- SecCoderX — vulnerability reward model, secure code RL
- Meta ACH — 9,095 mutants + 571 tests on 10K classes
- DeepSeek-R1 — pure RL without SFT, 2,029 Codeforces Elo

**Shipwright Status:** Has reward aggregation + policy learning; missing vulnerability signals

**Backlog Items:** #3 (Vulnerability Reward), #6 (Mutation Feedback), #13 (LLM Mutants)

---

### Episodic Memory & Long-Context Learning

**SOTA Systems:**

- Mem0 — hybrid storage, episodic + semantic layers
- EM-LLM — Bayesian surprise + graph refinement for episodes
- MemRL — agents improve via runtime RL on episodic memory
- Active compression — consolidate episodes → semantic facts

**Shipwright Status:** Pattern-based memory only; no execution traces

**Backlog Items:** #4 (Episodic Memory), #12 (Active Compression), #15 (Fleet Learning)

---

### Formal Verification & Specification

**SOTA Systems:**

- DafnyPro (POPL 2026) — 86% on DafnyBench via Claude
- ATLAS — 2.7K verified programs, 19K training examples
- MiniF2F-Dafny — mathematical theorem proving
- Vericoding benchmark — 27% Lean, 44% Verus, 82% Dafny

**Shipwright Status:** Tests only; no formal verification

**Backlog Item:** #11 (Formal Verification) — High effort, niche but high stakes

---

### Test Generation & Mutation Testing

**SOTA Systems:**

- Meta ACH — LLM-based test generation + mutant generation
- MutGen — 89.5% mutation score, outperforms EvoSuite
- LLMorpheus — open-source LLM-based mutation tool
- GPT-4o mutants — 57 different AST node types vs 2 for rule-based

**Shipwright Status:** Has testgen; no mutation feedback loop

**Backlog Items:** #6 (Mutation Loop), #13 (LLM Mutants), #17 (Privacy Mutations)

---

### Cost Optimization & Model Routing

**SOTA Systems:**

- Google Speculative Cascades — 30-60% cost reduction
- Unified routing + cascading — theoretically optimal framework
- CoSine — 23% latency, 32% throughput improvement
- Smurfs — adaptive speculation length per query

**Shipwright Status:** Has model routing; no speculative cascading

**Backlog Item:** #5 (Cascade Routing) — High ROI, Week 1

---

### Self-Healing CI/CD & AIOps

**SOTA Systems:**

- Agentic SRE pattern — telemetry → reasoning → automation
- Pipeline Doctor / Interceptor — repair agent on failure
- LLM-as-a-Judge — standard 2026 quality gate pattern
- 67% MTTR drop with AIOps; 60% enterprise adoption (Gartner)

**Shipwright Status:** Has retry logic; no repair agent or secondary validation

**Backlog Items:** #7 (CI Repair), #8 (Judge), #14 (Anomaly Detection)

---

### Multi-Agent Coordination & Orchestration

**SOTA Systems:**

- Standard 3-role (Planner, Worker, Judge)
- Git worktrees now standard isolation
- MetaGPT, CrewAI, LangGraph, AutoGen frameworks
- Google DORA 2025: 20-30% faster, 9% bug rate climb

**Shipwright Status:** Strong multi-agent support; missing conflict resolution + DAG

**Backlog Items:** #9 (Conflict Detection), #18 (DAG Scheduler)

---

### Reasoning Models with Extended/Adaptive Thinking

**SOTA Systems:**

- Claude Opus 4.6 — adaptive thinking (dynamic budget)
- OpenAI o1-pro — $150/$600 pricing, 200K context, 89th% Codeforces
- DeepSeek-R1 — 2,029 Elo, MoE architecture
- Claude Mythos (unreleased) — recursive self-correction

**Shipwright Status:** Uses extended thinking; missing budget allocation per query type

**Backlog Item:** #10 (Reasoning Budget Allocation)

---

## Competitive Landscape (2026)

| System             | SWE-bench | Multi-Agent | RL  | Memory | Cost-Opt | Verification | Notes                                   |
| ------------------ | --------- | ----------- | --- | ------ | -------- | ------------ | --------------------------------------- |
| **Claude Code**    | 80.9%     | ❌          | ❌  | ❌     | ✓        | ❌           | Highest score, single-agent             |
| **SWE-agent**      | 40.6%     | ❌          | ❌  | ❌     | ❌       | ❌           | Best ACI design, NeurIPS 2024           |
| **Aider**          | 49.2%     | ❌          | ❌  | ❌     | ✓✓       | ❌           | 4.2x token efficient                    |
| **Cline**          | —         | ❌          | ❌  | ❌     | ✓        | ❌           | 500K downloads, IDE integration         |
| **GitHub Copilot** | —         | ✓           | ❌  | ❌     | ✓        | ❌           | Project Padawan (autonomous)            |
| **Shipwright**     | —         | ✓✓          | ✓✓  | ✓      | ✓        | ❌           | **UNIQUE: Platform for dark factories** |

**Shipwright's positioning:** Only full-stack platform combining multi-agent orchestration + RL optimization + memory system + cost intelligence.

---

## Implementation Roadmap at a Glance

```
PHASE 1 (Weeks 1-4): CONVERGENCE & COST
  Week 1-2: #1 Semantic trajectory analysis
  Week 1-2: #5 Speculative cascade routing
  Week 2+:  #2 Intent Specification (research phase)

PHASE 2 (Weeks 5-8): SECURITY & TESTING
  Week 5-6: #3 Vulnerability Reward Model
  Week 5-6: #6 Mutation Testing Loop
  Week 7-8: #13 LLM-based Mutants

PHASE 3 (Weeks 9-12): MEMORY & SELF-HEALING
  Week 9-10: #4 Episodic Memory Layer
  Week 9-10: #7 CI Repair Agent
  Week 11-12: #8 LLM-as-a-Judge

TIER 2 (Weeks 13-26): LONGER-TERM
  #2 Intent Specification (full implementation)
  #9 Conflict Detection + DAG
  #10 Reasoning Budget Allocation
  #11 Formal Verification
  #12 Active Compression
  #14 Anomaly Detection
  #15 Fleet Learning
```

---

## Success Metrics (Post-Implementation)

| Feature             | Metric            | Target  | Current  |
| ------------------- | ----------------- | ------- | -------- |
| #1 Loop convergence | Iteration waste ↓ | -25-40% | Baseline |
| #5 Cascade routing  | Cost reduction    | -40-60% | Baseline |
| #3 Security         | Bug reduction     | -30-40% | Current  |
| #4 Episodic memory  | Solution time     | -20-35% | Baseline |
| #6 Mutation testing | Mutation score    | >80%    | ~60%     |
| #7 CI repair        | Retry cycles      | -50%    | Baseline |
| **Overall**         | Pipeline success  | >85%    | ~77%     |

---

## Investment & ROI

**Phase 1-2 (8 weeks, 2 engineers):**

- Cost: $65K (engineering + compute)
- Return: $320-440K annually
- ROI: **5-7x**

**Long-term (26 weeks):**

- Additional return: $120-155K/year
- ROI: **3-4x** on incremental investment

---

## How to Use These Documents

### Weekly Strategy Review

1. Open **BACKLOG_QUICK_REFERENCE.md** → Priority matrix
2. Check progress against timeline
3. Update next week's focus

### Pre-Sprint Planning

1. Read relevant sections in **CUTTING_EDGE_RESEARCH_2026.md**
2. Extract implementation details from "Actionable Gap"
3. Check **RESEARCH_SOURCES.md** for key papers

### Deep Technical Design

1. Read full section in **CUTTING_EDGE_RESEARCH_2026.md**
2. Review all sources in **RESEARCH_SOURCES.md**
3. Implement checklist from **BACKLOG_QUICK_REFERENCE.md**

### Competitive Briefing

1. Share **RESEARCH_SUMMARY.txt** (5 min read)
2. Reference SOTA systems from specific sections
3. Deep dive as needed

---

## Notes for Implementation

### Assumptions Made

- Shipwright has access to Claude API (embedding, reasoning)
- GitHub Actions integration complete
- Current pipeline success rate ~77%
- Monthly compute budget ~$50K

### Risk Factors

- Model API availability (o1-pro limited to ChatGPT Pro)
- DeepSeek-R1 accessibility (China-based, regulatory risk)
- Formal verification tools (complex integration)
- RL training stability (exploration vs exploitation tuning)

### Mitigation Strategies

- Start with proven patterns (Google Cascades, Meta ACH)
- Use open-source where possible (DeepSeek-R1, Dafny, Aider)
- Prototype before full implementation (#2 Intent Engine research phase)
- A/B test new features (reasoning budgets, cascade routing)
- Track metrics continuously (DORA, cost, success rate)

---

## Questions for Follow-Up

1. **Dark Factory Ready:** How aggressively should we pursue the Intent Specification Engine (#2)? It's strategic but high-effort.

2. **Formal Verification:** Is the cryptographic/payment use case common enough to justify #11 (Dafny/Lean integration)?

3. **Reasoning Models:** Should we wait for Claude Mythos, or start with o1-pro now?

4. **Priority Trade-offs:** If we can only do 3 items in Phase 1, should we skip #2 (Intent) research and focus on cost/convergence?

5. **Multi-Agent Safety:** With Google's DORA showing 9% bug rate climb, how should quality gates (#8 Judge) be weighted?

---

**Generated:** April 4, 2026  
**Research effort:** 65+ sources, 25+ papers, 10 research areas, 8 hours  
**Next review:** After Phase 1 completion (Week 4)

---

## Document Navigation

- Primary Report: `CUTTING_EDGE_RESEARCH_2026.md`
- Quick Reference: `BACKLOG_QUICK_REFERENCE.md`
- Sources: `RESEARCH_SOURCES.md`
- Summary: `RESEARCH_SUMMARY.txt`
- This Index: `RESEARCH_INDEX.md` (you are here)
