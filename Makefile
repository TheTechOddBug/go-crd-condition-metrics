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

METRIC_NAMESPACE ?= unset

##@ Generate
.PHONY: dashboards
dashboards: ## Generate dashboards from templates
	@# Fail if METRIC_NAMESPACE is unset
	@[ "$(METRIC_NAMESPACE)" != "unset" ] && [ -n "$(METRIC_NAMESPACE)" ] || { \
		echo "Error: METRIC_NAMESPACE is required."; \
		echo "Usage: make dashboards METRIC_NAMESPACE=my_operator"; \
		exit 1; \
	}
	@echo "Generating dashboards for $(METRIC_NAMESPACE)…"
	@mkdir -p generated/dashboards
	@find dashboards -type f -name '*.tpl.json' | while IFS= read -r file; do \
	  base_name=`basename "$$file" .tpl.json`; \
	  new_file="generated/dashboards/$$base_name.json"; \
	  sed "s/{{operator_namespace}}/$(METRIC_NAMESPACE)_/g" "$$file" > "$$new_file"; \
	done
