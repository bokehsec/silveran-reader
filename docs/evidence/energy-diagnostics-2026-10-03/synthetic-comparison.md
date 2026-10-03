# Silveran performance comparison

Resource intervals overlap and are sampled 1/16; never sum or extrapolate their totals.
Activity durations/counts are not energy. CPU includes background work; foreground ratios do not split CPU.
Merged compatible duration histograms provide bucket upper bounds, not averaged percentiles.
Unknown metrics and missing builds remain unknown. Regression thresholds await ED-5 real-device baselines.

## Cohort: iOS, iPad16,1, 18.6, development, 1, 100, 1, activity

Reports: 1; coverage: 2026-10-03T10:00:00Z – 2026-10-03T11:00:00Z

| Operation / process | Count | Duration samples | p50 upper seconds | p95 upper seconds | Evidence |
| --- | ---: | ---: | ---: | ---: | --- |
| annotation.commitInk/native | 100 | 100 | 0.01 | 0.01 | distribution only; baseline thresholds pending |

Observed context seconds per activity window (overlap, partial coverage): `[{}]`

OS measurements per report: `{}`

App-total CPU seconds divided by foreground hours (includes background CPU): `[]`

## Cohort: iOS, iPad16,1, 18.6, development, 1, 101, 1, activity

Reports: 1; coverage: 2026-10-03T10:00:00Z – 2026-10-03T11:00:00Z

| Operation / process | Count | Duration samples | p50 upper seconds | p95 upper seconds | Evidence |
| --- | ---: | ---: | ---: | ---: | --- |
| annotation.commitInk/native | 100 | 100 | 0.5 | 0.5 | distribution only; baseline thresholds pending |

Observed context seconds per activity window (overlap, partial coverage): `[{}]`

OS measurements per report: `{}`

App-total CPU seconds divided by foreground hours (includes background CPU): `[]`

## Build comparisons

```json
{
  "operations": [
    {
      "operation": "annotation.commitInk/native",
      "fromBuild": "100",
      "toBuild": "101",
      "countChange": 0,
      "p50UpperSecondsBefore": 0.01,
      "p50UpperSecondsAfter": 0.5,
      "p95UpperSecondsBefore": 0.01,
      "p95UpperSecondsAfter": 0.5,
      "evidence": "investigate distribution changes with matched workloads; no energy causation claim"
    }
  ],
  "osAggregates": []
}
```

## Coverage warnings

- 100: partial activity coverage
- 101: partial activity coverage
