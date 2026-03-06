## Detection Accuracy Validation

When implementing multi-class project type detection, validation must span accuracy, confidence calibration, and generated configuration correctness.

### Build a Real-World Test Corpus

Create 5–10 sample repositories for each of the 8+ project types (node web, node cli, go library, python web, rust cli, java library, etc.). Use actual open-source projects or realistic test fixtures, not synthetic examples. Each sample should have:
- Real package files (package.json, go.mod, pyproject.toml, Cargo.toml, etc.)
- Typical directory structures for that type
- Representative dependencies (web frameworks, CLI libraries, etc.)

### Multi-Class Classification Metrics

For each sample repository, record:
1. **Detected type** — what the algorithm returns
2. **Confidence score** — 0.0–1.0 returned by the algorithm
3. **Ground truth type** — what the repo actually is (determined manually or by convention)
4. **Per-type precision and recall** — e.g., "go library detection: 90% precision, 85% recall"
5. **Overall accuracy** — percentage of detections that match ground truth

Track false positives and false negatives separately to identify systematic weaknesses (e.g., "node CLIs misclassified as web apps 15% of the time").

### Confidence Score Calibration

A detection system is well-calibrated if claimed confidence matches actual accuracy. For example, if 100 detections claim 85% confidence, approximately 85 should be correct.

- Plot confidence bins (0.8–0.9, 0.9–1.0, etc.) vs. actual accuracy on the test corpus
- If detected types claiming 90% confidence are only 70% accurate, the scoring function is overconfident—adjust heuristic weights
- Document any known low-confidence edge cases (e.g., "hybrid projects with multiple languages score 60–75% confidence")

### Config Generation Verification

For each detected type, verify the generated configurations are correct:
1. **daemon-config.json** — test commands, parallelism settings, and templates should match the project type (e.g., rust projects should use cargo test, not npm test)
2. **Recommended agents** — library projects might emphasize security; web services might emphasize scaling
3. **Example output** — generate one complete, realistic example per project type for documentation
4. **No breaking changes** — test that generated configs don't conflict with or break existing shipwright workflows

### Edge Case & Regression Testing

Test detection on challenging inputs:
- **Monorepos** — multiple projects in one repo; detection should handle or explicitly decline
- **Workspaces** — npm/yarn workspaces or cargo workspaces
- **Minimal projects** — single file, no dependencies; heuristics must not crash
- **Unusual structures** — non-standard directories, missing package files
- **Multi-language projects** — detection should prioritize dominant language
- **Repos with manual type specs** — ensure backward compatibility; don't override explicit user configuration

### Production Observability

Once deployed, instrument detection to monitor real-world accuracy:
- Log confidence scores and detected types alongside generation of daemon-config.json
- Alert if per-type accuracy drops below a threshold (e.g., node detection below 85%)
- Collect misclassifications and route them to a learning system for heuristic refinement
- Periodically recalibrate confidence scores based on production data
