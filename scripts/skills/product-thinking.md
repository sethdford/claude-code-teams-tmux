## Product Thinking Expertise

Consider the user perspective in your implementation:

### User Stories
- Who is the user for this feature?
- What problem does this solve for them?
- What is their workflow before and after this change?
- Define acceptance criteria from the user's perspective

### User Experience
- What is the simplest interaction that solves the problem?
- How does the user discover this feature?
- What happens when things go wrong? (error states, recovery)
- Is the feature accessible to users with disabilities?

### Edge Cases from User Perspective
- What if the user has no data yet? (empty state)
- What if the user has too much data? (pagination, filtering)
- What if the user makes a mistake? (undo, confirmation)
- What if the user is on a slow connection? (loading states)

### Progressive Disclosure
- Show the most important information first
- Hide complexity behind progressive interactions
- Don't overwhelm with options — provide sensible defaults
- Use contextual help instead of documentation

### Feedback & Communication
- Confirm successful actions immediately
- Explain errors in plain language — not error codes
- Show progress for long-running operations
- Preserve user context across navigation
