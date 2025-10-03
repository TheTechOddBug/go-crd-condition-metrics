# Grafana dashboards

The grafana dashboards are templated. To get a dashboard that fits your metric name, run the following command, using
the name of your metric namespace as input.

```bash
make dashboards METRIC_NAMESPACE=your_operator
```

The generated files are placed under `generated/dashboards`.

The name of your metric namespace is decided by the initialization of `OperatorConditionsGauge`. For instance, here 
the namespace is `my_operator`:

```go
OperatorConditionsGauge = ccm.NewOperatorConditionsGauge("my_operator")
```

## CRD Condition Browser Dashboard

![crd_conditions_browser_dashboard_1.png](/docs/crd_conditions_browser_dashboard_1.png)

![crd_conditions_browser_dashboard_2.png](/docs/crd_conditions_browser_dashboard_2.png)