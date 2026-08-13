##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk command is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: all
all: fmt vet lint test

##@ Development
.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: lint
lint: ## Run linter
	golangci-lint run

.PHONY: lint-fix
lint-fix: ## Run linter and fix issues
	golangci-lint run --fix

.PHONY: test
test: ## Run project tests
	go test ./...

.PHONY: benchmark
benchmark: ## Run project benchmarks
	go test -bench=. -benchtime=10000x -benchmem ./...

.PHONY: test-alerts
test-alerts: ## Lint and unit test the alert rule templates with promtool
	@command -v promtool >/dev/null 2>&1 || { \
		echo "Error: promtool is required to test the alert rules."; \
		echo "Install prometheus from https://prometheus.io/download/ or run 'asdf install'."; \
		exit 1; \
	}
	@set -e; \
	tmpdir=`mktemp -d`; \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	mkdir -p "$$tmpdir/tests" "$$tmpdir/namespace-label"; \
	for file in alerts/*.tpl.yaml; do \
	  base_name=`basename "$$file" .tpl.yaml`; \
	  $(call render_rules,$$file,$(ALERT_TEST_NAMESPACE),exported_namespace) > "$$tmpdir/$$base_name.yaml"; \
	  $(call render_rules,$$file,$(ALERT_TEST_NAMESPACE),namespace) > "$$tmpdir/namespace-label/$$base_name.yaml"; \
	done; \
	cp alerts/tests/*.yaml "$$tmpdir/tests/"; \
	echo "Linting rules…"; \
	promtool check rules --lint=all --lint-fatal "$$tmpdir"/*.yaml; \
	echo "Linting rules with NAMESPACE_LABEL=namespace…"; \
	promtool check rules --lint=all --lint-fatal "$$tmpdir"/namespace-label/*.yaml; \
	echo "Running unit tests…"; \
	promtool test rules --diff "$$tmpdir"/tests/*.yaml

METRIC_NAMESPACE ?= unset
# Label carrying the namespace of the custom resource. The pod scraping the
# operator usually rewrites the exported `namespace` label to
# `exported_namespace`; override this if yours does not.
NAMESPACE_LABEL ?= exported_namespace
# Metric namespace the alert rule unit tests in alerts/tests are written against
ALERT_TEST_NAMESPACE := test_operator

# Fail unless METRIC_NAMESPACE was given. $(1) is the target name, used in the
# usage hint.
define require_metric_namespace
@[ "$(METRIC_NAMESPACE)" != "unset" ] && [ -n "$(METRIC_NAMESPACE)" ] || { \
		echo "Error: METRIC_NAMESPACE is required."; \
		echo "Usage: make $(1) METRIC_NAMESPACE=my_operator"; \
		exit 1; \
	}
endef

# Render an alert rule template to stdout as a plain prometheus rules file.
# $(1) template path, $(2) metric namespace, $(3) namespace label.
define render_rules
sed -e 's/{{operator_namespace}}/$(2)_/g' -e 's/{{namespace_label}}/$(3)/g' $(1)
endef

##@ Generate
.PHONY: dashboards
dashboards: ## Generate dashboards from templates
	$(call require_metric_namespace,dashboards)
	@echo "Generating dashboards for $(METRIC_NAMESPACE)…"
	@mkdir -p generated/dashboards
	@find dashboards -type f -name '*.tpl.json' | while IFS= read -r file; do \
	  base_name=`basename "$$file" .tpl.json`; \
	  new_file="generated/dashboards/$$base_name.json"; \
	  sed "s/{{operator_namespace}}/$(METRIC_NAMESPACE)_/g" "$$file" > "$$new_file"; \
	done

.PHONY: alerts
alerts: ## Generate prometheus alert rules from templates
	$(call require_metric_namespace,alerts)
	@echo "Generating alerts for $(METRIC_NAMESPACE) (namespace label: $(NAMESPACE_LABEL))…"
	@mkdir -p generated/alerts
	@find alerts -maxdepth 1 -type f -name '*.tpl.yaml' | while IFS= read -r file; do \
	  base_name=`basename "$$file" .tpl.yaml`; \
	  new_file="generated/alerts/$$base_name.yaml"; \
	  rule_name=`echo "$(METRIC_NAMESPACE)-$$base_name" | tr '_' '-'`; \
	  { \
	    echo "apiVersion: monitoring.coreos.com/v1"; \
	    echo "kind: PrometheusRule"; \
	    echo "metadata:"; \
	    echo "  name: $$rule_name"; \
	    echo "spec:"; \
	    $(call render_rules,"$$file",$(METRIC_NAMESPACE),$(NAMESPACE_LABEL)) \
	      | sed -e 's/^/  /' -e 's/[[:space:]]*$$//'; \
	  } > "$$new_file"; \
	done
