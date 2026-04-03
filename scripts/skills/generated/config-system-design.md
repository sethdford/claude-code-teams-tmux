## Config-Driven System Design

Moving from hardcoded constants to configuration requires careful design of schema, validation, precedence, and fallback behavior.

### Schema Design

- **Organize by concern**: Group related timeouts together (stage_timeouts), limits together (iteration_limits), etc.
- **Provide sensible defaults**: Schema should document the default value for each field.
- **Version the schema**: Include a schema_version field to enable future migrations without breaking existing policies.
- **Use constraints in schema**: Set min/max bounds on numeric fields (e.g., max_iterations > 0, timeout in seconds).

### Validation & Error Messages

- **Fail fast with context**: When schema validation fails, report the field path, expected type, and constraint violation.
- **Provide a fix suggestion**: For common errors (typo in field name), suggest the closest valid field.
- **Test error cases explicitly**: Schema validation is the primary defense against misconfiguration.

### Fallback & Precedence

- **Hardcoded defaults**: If policy.json is missing, use hardcoded defaults from code.
- **Override precedence**: policy.json (base) < policy-overrides.json (adaptive suggestions) < environment variables (operator overrides).
- **Don't cascade overrides**: If an override suggests an invalid value, reject it and log; don't silently fall back.

### Migration Strategy

- **Extract values systematically**: Identify all hardcoded constants; group by semantic meaning (stage timeout, max retries, cost limit).
- **Preserve behavior exactly**: After migration, no behavior should change—hardcoded defaults must exactly match original values.
- **Test side-by-side**: Load both hardcoded and policy-driven values; assert they produce identical results.
- **Phase migration**: Migrate one script at a time with full test coverage before moving to the next.

### Adaptive Override Design

- **Narrow scope**: Intelligence layer should only suggest overrides for values it has evidence for (e.g., stage timeout based on historical run duration).
- **Confidence threshold**: Only write an override if confidence is high (e.g., 95th percentile data).
- **Explainability**: Include reasoning in the override (why the new value was suggested) for debugging.
- **Validation before apply**: Adaptive overrides must pass schema validation before being written to disk.

### Documentation

- **POLICY.md**: Document each tunable, its default, valid range, and impact on pipeline behavior.
- **Schema inline comments**: Use JSON Schema description fields to make the schema self-documenting.
- **Example policies**: Show real-world policy configurations for different use cases (fast iteration, cost-aware, high-reliability).
