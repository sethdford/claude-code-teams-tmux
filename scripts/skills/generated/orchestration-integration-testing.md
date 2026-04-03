## Orchestration Integration Testing

Orchestration layers couple previously independent systems through data flow. Testing requires a different mindset than component unit tests.

### Test Structure

**Happy Path**: Trace a mock pipeline start through all 5 stages (score → compose → predict → route → monitor). Assert each stage receives enriched context from the prior stage. Example: verify that composer receives scorer's complexity assessment in its input payload.

**Data Enrichment**: For each stage, write a test that "removes" its enrichment and asserts downstream stages degrade predictably. If predictor receives no risk score, does router still function? If composer receives no complexity, does it default correctly?

**Failure Isolation**: One component fails (e.g., predictor times out). Assert:
- Orchestrator detects the failure (checkpoint)
- Gracefully degrades: downstream stages skip or use cached data
- Pipeline continues (not cascading failure)
- Unified report documents which stages were unavailable

**Unified Report Validation**: Assert the final intelligence report contains contributions from all active stages. Use a JSON schema validator. Check that metrics aggregate correctly (total cost estimate = router estimate + baseline, not duplication).

**Measurement Baseline**: Before orchestration kicks in, record pipeline outcomes (success rate, cost, MTTR). After orchestration, A/B test on 20+ runs and assert statistical improvement. Use `shipwright memory show` to check baseline was captured.

### Patterns

- **Mock individual stages** but wire real data contracts between them (use actual JSON payloads, not mock objects).
- **Use scenario data** (real pipeline complexity distributions, observed risk scores) to drive tests.
- **Test timing**: Does orchestrator add < 5s latency per pipeline start? Measure P95 time for full orchestration sequence.
- **Test cardinality**: What happens with 100+ pipelines running orchestration simultaneously? Shared cache contention?

### Fail-Fast Checks

- Unified report is not empty and contains >= 1 enrichment from orchestration (else orchestrator is a no-op)
- Data contracts are validated (e.g., scorer output schema matches composer input schema)
- Backward compatibility: old pipelines can run without orchestrator (graceful disable)
