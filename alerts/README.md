# Prometheus alerts

Generic alerting rules for the condition metrics this package records. They are templated, because
the metric name depends on the namespace you gave to `NewOperatorConditionsGauge`.

```bash
make alerts METRIC_NAMESPACE=your_operator
```

The generated files are placed under `generated/alerts`. Each template becomes one
[`PrometheusRule`](https://prometheus-operator.dev/docs/api-reference/api/#monitoring.coreos.com/v1.PrometheusRule)
resource. If you do not run prometheus-operator, drop the four `apiVersion`/`kind`/`metadata`/`spec`
lines from the top of the file and un-indent the rest to get a plain rules file for `rule_files`.

## The namespace label

Most of the time the pod scraping your operator already owns the `namespace` label, so the label this
package exports arrives in Prometheus as `exported_namespace`. That is the default. If your setup
keeps the original label, generate with:

```bash
make alerts METRIC_NAMESPACE=your_operator NAMESPACE_LABEL=namespace
```

## The rules

| Alert | Fires when | Threshold |
|---|---|---|
| `CustomResourceNotReady` | A resource's `Ready` condition has been `False` continuously | `for: 30m` |
| `CustomResourceConditionUnknown` | Any condition has had status `Unknown` continuously | `for: 30m` |
| `CustomResourceConditionStuck` | A resource's `Ready` condition has not been `True` since its last transition | `> 6h` |

Each rule aggregates the metric rather than matching series directly. That drops the `reason`,
`status` and `id` labels, so a controller that keeps rewriting the reason while a resource stays
unhealthy does not restart the `for:` clock every time. The aggregation is `max()` rather than
`sum()` so that the value stays a `lastTransitionTime` — the freshest one — even when a former
leader pod is still exporting a stale series for the same resource.

### Why both a `for:` rule and a value based rule

`CustomResourceNotReady` and `CustomResourceConditionStuck` look redundant, and they do overlap. They
measure different things:

- A `for:` clause measures how long the **alert** has been true. That is bounded by how long the
  series has been continuously present, so a scrape gap, an operator restart or a ruler restart
  silently restarts the clock.
- `CustomResourceConditionStuck` compares `time()` against the metric value, which is the condition's
  own `lastTransitionTime`. It therefore measures how long the **resource** has actually been in this
  state, survives all of the above, and reports the real age of the state in its annotations.

Keep the stuck threshold comfortably above the `for:` threshold, and route it at a lower severity if
you page on the first rule.

## What to tune

**Thresholds first.** `30m`, `30m` and `21600` seconds (6 hours) are starting points. What counts as
too long depends entirely on how quickly your controller is expected to converge.

**Condition polarity.** `CustomResourceNotReady` and `CustomResourceConditionStuck` are scoped to
`condition="Ready"` on purpose. Matching every condition would fire forever on negative polarity
conditions such as `Degraded` or `FailedToProvision`, where `False` is the healthy state. Add your own
positive polarity conditions to the matcher — the `condition` label is already in the aggregation, so
it is a one line change. `CustomResourceConditionUnknown` is deliberately unscoped, because `Unknown`
is bad under either polarity.

**Severity and routing.** Every rule ships as `severity: warning` with no team or routing labels,
since those are specific to your alertmanager setup.

**Annotations.** The `dashboard_url` annotation deep links into the
[CRD Conditions Browser dashboard](../dashboards) in this repository, filtered down to the resource
that triggered the alert. It assumes that dashboard is installed under its default UID.

## Testing

The rules ship with [promtool unit tests](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/):

```bash
make test-alerts
```

This renders the templates against a fixed test metric namespace, lints them with both namespace
label variants, and runs the unit tests in `tests/`. It needs `promtool` on your `PATH` — install
[prometheus](https://prometheus.io/download/) to get it.

If you change a template, run this. The rules are compared against exact expected annotations, so
`promtool test rules --diff` shows you precisely what changed in the rendered alert text.
