## Two-Stage Code Review

This review runs in two passes. Complete Pass 1 fully before starting Pass 2.

### Pass 1: Spec Compliance

Compare the implementation against the plan and issue requirements:

1. **Task Checklist**: Does the code implement every task from plan.md?
2. **Files Modified**: Were all planned files actually modified?
3. **Requirements Coverage**: Does the implementation satisfy every requirement from the issue?
4. **Missing Features**: Is anything from the plan NOT implemented?
5. **Scope Creep**: Was anything added that WASN'T in the plan?

For each gap found:
- **[SPEC-GAP]** description — what was planned vs what was implemented

If all requirements are met, write: "Spec compliance: PASS — all planned tasks implemented."

---

### Pass 2: Code Quality

Now review the code for engineering quality:

1. **Logic bugs** — incorrect conditions, off-by-one errors, null handling
2. **Security** — injection, XSS, auth bypass, secret exposure
3. **Error handling** — missing catch blocks, silent failures, unclear error messages
4. **Performance** — unnecessary loops, missing indexes, N+1 queries
5. **Naming and clarity** — confusing names, missing context, magic numbers
6. **Test coverage** — are new code paths tested? Edge cases covered?

For each issue found, use format:
- **[SEVERITY]** file:line — description

Severity: Critical, Bug, Security, Warning, Suggestion
