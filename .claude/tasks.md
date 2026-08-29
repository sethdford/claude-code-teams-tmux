# Tasks — Pre-Build Diff-Size and Iteration-Velocity Anomaly Warning in Pipeline Vitals

## Status: In Progress
Pipeline: standard | Branch: feat/pre-build-diff-size-and-iteration-veloci-3313

## Checklist
- [ ] `sw-pipeline-vitals.sh` reads `build.diff_lines` / `build.iterations` from `~/.shipwright/baselines/default.json`
- [ ] Threshold multiplier read via `_smart_int "vitals.anomaly_multiplier" 3` (env + daemon-config overridable)
- [ ] `shipwright vitals` prints an `Anomaly` warning line for an in-progress pipeline over threshold, and prints nothing when under
- [ ] `pipeline_compute_vitals --json` contains an `.anomaly` object; `--anomaly` mode works; `--help` documents it
- [ ] `pipeline_vitals_anomaly` written to `events.jsonl` exactly once per (issue, kind), not per poll
- [ ] `build.diff_lines` / `build.iterations` baselines are recorded on build-stage completion
- [ ] Cold start (`count < 3`), missing baseline, malformed baseline, and zero baseline never flag and never fail
- [ ] `health_score`, verdicts, and the daemon gate are byte-for-byte unchanged when no anomaly is present
- [ ] `scripts/sw-pipeline-vitals-test.sh` passes with the 10 new cases; existing 10 still pass
- [ ] `shellcheck` clean on both changed scripts; bash 3.2 compatible (no `declare -A`, no `readarray`, no `${var,,}`)
- [ ] `npm test` green
- [ ] `.claude/CLAUDE.md` documents the `vitals` config block (hand-written region only)

## Notes
- Generated from pipeline plan at 2026-08-29T13:31:41Z
- Pipeline will update status as tasks complete
