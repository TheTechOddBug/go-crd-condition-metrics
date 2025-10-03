# CRD Condition Metrics

A simple and easy to integrate metric recording utility for kubernetes operators, giving you metrics
which are representative—and kept in line with your [CRD status Conditions](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md#typical-status-properties).

This package is built on the [Prometheus GaugeVecSet implementation for go](https://github.com/sourcehawk/go-prometheus-gaugevecset).

## 📚 Table of Contents

1. [Features](#features)
2. [Installation](#installation)
3. [Motivation](#motivation)
4. [Setup: Operator Initialization](#operator-initialization)
5. [Setup: Controller Usage](#controller-usage)
6. [PromQL Usage Examples](#promql-usage-examples)

---

## Features
- **Ensures consistency between your CRD statuses and your metrics**: The metrics are based on your status conditions and 
   synced when you update the conditions.
- **Easy integration**: Get metrics anywhere with little initial setup and a simple method calls.
- **Light weight and performant**: Small memory footprint at large scale, fast ops.
- **Keeps cardinality under control**: Only 1 metric series per (custom resource, condition type) combination. 
   Gives you low cardinality even with thousands of unique label combinations.
- [Dashboards available](/dashboards) to get you started!

---

### Installation

Install the go package

```go
go get github.com/sourcehawk/go-crd-condition-metrics
```

Importing it:

```go
import (
	ccm "github.com/sourcehawk/go-crd-condition-metrics/pkg/crd-condition-metrics"
)
```

---

## Motivation

Creating meaningful metrics for custom resources is an essential part of building observability into any Kubernetes 
operator or controller. But despite its importance, there’s a lack of standardization—especially when it comes to 
exposing metrics that accurately reflect the actual `status` of a CRD.

In Kubernetes, the `status.conditions` field has become the de facto convention for representing the state of a 
resource. It captures key lifecycle signals such as `Ready`, `Reconciled`, `Degraded`, or `FailedToProvision`, along 
with rich metadata like `reason`, `status`, and `lastTransitionTime`.

This package was created to **standardize the way we expose those conditions as metrics**, allowing you to:
- Derive metrics directly from your resource’s `status.conditions`
- Keep metric values and labels fully in sync with the real resource state
- Avoid excessive metric cardinality
- Gain visibility into when a condition last transitioned

### Pattern inspiration: kube-state-metrics

This metric strategy is inspired by `kube_pod_status_phase` from [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics), 
which exports one time series per `phase` for each `(namespace, pod)` pair and marks exactly one as active (`1`) while 
the others are set to inactive (`0`).

Example:

```
kube_pod_status_phase{namespace="default", pod="nginx", phase="Running"} 1
kube_pod_status_phase{namespace="default", pod="nginx", phase="Pending"} 0
kube_pod_status_phase{namespace="default", pod="nginx", phase="Failed"}  0
```

We adopt a similar idea for `status.conditions`, but with some key differences:

- We expose **only one time series per (custom resource, condition type)**. All other condition variants 
  (status/reason combinations) are removed when a new one is set.
- Instead of using binary values (`1` or `0`), we set the **Unix timestamp of `lastTransitionTime`** as the metric 
  value. This allows you to query when a condition was last updated.

Example metric from this package:

```
my_operator_controller_condition{
    controller="my_controller",
    kind="MyCR",
    name="my-cr",
    namespace="default",
    condition="Ready",
    status="False",
    reason="FailedToProvision"
} 17591743210
```

This makes it easy to build dashboards and alerts like:
- Show all CRs currently in a non-`Ready` state
- Alert if a CR has been stuck in a given condition for too long
- Visualize how long a CR has remained in its current status

### Why this matters

When operating controllers at scale, consistency and cardinality matter. Metrics should reflect the actual resource 
state—not drift from it—and they should not grow uncontrollably as conditions change.

This package gives you a lightweight, plug-and-play way to track CRD condition metrics correctly, consistently, and 
with full context.

---

## Operator Initialization

The metric should be initialized and registered once.

You can embed the `ConditionMetricRecorder` in your controller's recorder.

```go
package my_metrics

import (
    controllermetrics "sigs.k8s.io/controller-runtime/pkg/metrics"
    ccm "github.com/sourcehawk/go-crd-condition-metrics/pkg/crd-condition-metrics"
)

// We need this variable later to create the ConditionMetricsRecorder
var OperatorConditionsGauge *ccm.OperatorConditionsGauge

// Initialize the operator condition gauge once
func init() {
    OperatorConditionsGauge = ccm.NewOperatorConditionsGauge("my_operator")
    controllermetrics.Registry.MustRegister(OperatorConditionsGauge)
}

// Embed in existing metrics recorder
type MyControllerRecorder struct {
	ccm.ConditionMetricRecorder
}
```

When constructing your reconciler, initialize the condition metrics recorder with the
operator conditions gauge and a unique name for each controller.

_cmd/main.go_
```go
package main

import (
    mymetrics "path/to/pkg/my_metrics"
	ccm "github.com/sourcehawk/go-crd-condition-metrics/pkg/crd-condition-metrics"
)

func main() {
    // ...
    recorder := mymetrics.MyControllerRecorder{
        ConditionMetricRecorder: ccm.ConditionMetricRecorder{
            Controller: "my-controller", // unique name per reconciler
            OperatorConditionsGauge: mymetrics.OperatorConditionsGauge,
        },
    }
	
    reconciler := &MyReconciler{
        Recorder: recorder, 
    }
    // ...
}
```

---

## Controller Usage

The easiest drop-in way to start using the metrics recorder is by creating a `SetStatusCondition` wrapper, which
comes instead of `meta.SetStatusCondition`. We call `RecordConditionFor` to record our metrics.

To delete the metrics for a given custom resource, simply call `RemoveConditionsFor` and pass the object.

```go
const (
	kind = "MyCR"
)

// SetStatusCondition utility function which replaces and wraps meta.SetStatusCondition calls
func (r *MyReconciler) SetStatusCondition(cr *v1.MyCR, cond metav1.Condition) bool {
    changed := meta.SetStatusCondition(&cr.Status.Conditions, cond)
    // refetch the condition to get the updated version
    updated := meta.FindStatusCondition(cr.Status.Conditions, cond.Type)
    if updated != nil {
        r.Recorder.RecordConditionFor(
            kind, cr, updated.Type, string(updated.Status), updated.Reason, updated.LastTransitionTime,
        )
    }
    return changed
}

func (r *MyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // Get the resource we're reconciling
    cr := new(v1.MyCR)
    if err = r.Get(ctx, req.NamespacedName, cr); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }
	
    // Remove the metrics when the CR is deleted
    if cr.DeletionTimeStamp != nil {
        r.Recorder.RemoveConditionsFor(kind, cr)
    }
	
    // ...
	
    // Update the status conditions using our wrapper function
    if r.SetStatusCondition(cr, condition) {
        if err = r.Status().Update(ctx, cr); err != nil {
            return ctrl.Result{}, err
        }
    }
	
    return ctrl.Result{}, nil
}
```

---

## PromQL usage examples

Here are some examples of how we can query the metrics. 

The examples assume the `OperatorConditionsGauge` was
initialized with the namespace `my_operator` which results in the metric name being `my_operator_controller_condition`.

In code:
```go
OperatorConditionsGauge = ccm.NewOperatorConditionsGauge("my_operator")
```

> [!IMPORTANT] Most of the time, the `namespace` label is reserved by the pod scraping the metrics. 
> The `namespace` label we set is therefore in most cases labeled as `exported_namespace`.
> **The examples do not assume this to be the case.**

Get all CR's of kind `App` that have the condition `Ready` set to `False`.

```promql
my_operator_controller_condition{
    kind="App",
    condition="Ready",
    status="False",
}
```

Output:

```
my_operator_controller_condition{condition="Ready", controller="myctrlr", namespace="ns-1", id="ns-1/my-app-1", kind="App", name="my-app-1", reason="Foo", status="False"} 1759416292
my_operator_controller_condition{condition="Ready", controller="myctrlr", namespace="ns-1", id="ns-1/my-app-2", kind="App", name="my-app-2", reason="Bar", status="False"} 1759329097
my_operator_controller_condition{condition="Ready", controller="myctrlr", namespace="ns-2", id="ns-2/my-app", kind="App", name="my-app", reason="Foo", status="False"} 1759329145
my_operator_controller_condition{condition="Ready", controller="myctrlr", namespace="ns-3", id="ns-3/my-app", kind="App", name="my-app", reason="Foo", status="False"} 1759406280
```

---

Count the number of CR's of kind `App` that have `Ready` condition status `False`

```
count(
  my_operator_controller_condition{
    kind="App",
    condition="Ready",
    status="False",
  } > 0
)
```

Output:

```
4
```