## Brainstorming: Socratic Design Refinement

Before writing the implementation plan, challenge your assumptions with these questions:

### Requirements Clarity
- What is the **minimum viable change** that satisfies this issue?
- Are there implicit requirements not stated in the issue?
- What are the acceptance criteria? If none are stated, define them.

### Design Alternatives
- What are at least 2 different approaches to solve this?
- What are the trade-offs of each? (complexity, performance, maintainability)
- Which approach minimizes the blast radius of changes?

### Risk Assessment
- What could go wrong with the chosen approach?
- What existing functionality could break?
- Are there edge cases not covered by the issue description?

### Dependency Analysis
- What existing code does this depend on?
- What other code depends on what you're changing?
- Are there any circular dependency risks?

### Simplicity Check
- Can this be solved with fewer files changed?
- Is there existing infrastructure you can reuse?
- Would a simpler approach work for 90% of cases?

Document your reasoning in the plan. Show the alternatives you considered and why you chose this approach.
