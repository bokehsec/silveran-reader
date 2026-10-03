# Silveran performance comparison

Resource intervals overlap and are sampled 1/16; never sum or extrapolate their totals.
Activity durations/counts are not energy. CPU includes background work; foreground ratios do not split CPU.
Merged compatible duration histograms provide bucket upper bounds, not averaged percentiles.
Unknown metrics and missing builds remain unknown. Regression thresholds await ED-5 real-device baselines.

## Cohort: iOS, iPad16,1, 18.6, development, 1, 100, 1, metrickit

Reports: 1; coverage: 2026-10-03T14:45:45Z – 2026-10-03T15:45:45Z

| Operation / process | Count | Duration samples | p50 upper seconds | p95 upper seconds | Evidence |
| --- | ---: | ---: | ---: | ---: | --- |

Observed context seconds per activity window (overlap, partial coverage): `[{}]`

OS measurements per report: `{"cpuSeconds": [12]}`

App-total CPU seconds divided by foreground hours (includes background CPU): `[]`

## Build comparisons

```json
{
  "operations": [],
  "osAggregates": []
}
```

## Coverage warnings

- 100: missing foregroundSeconds
- 100: partial metrickit coverage
