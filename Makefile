export PATH := $(CURDIR)/bin:$(PATH)

TEST_TIMEOUT_SECONDS ?= 3600

CLEANUP_TIMEOUT_SECONDS ?= 600

RESULT_METRICS_TIMEOUT_SECONDS ?= 120

NODES_SIZE ?= 1000

QUEUES_SIZE ?= 1
JOBS_SIZE_PER_QUEUE ?= 1
PODS_SIZE_PER_JOB ?= 1

IMPACTING_QUEUES_SIZE ?= 0
IMPACTING_JOBS_SIZE_PER_QUEUE ?= 1
IMPACTING_PODS_SIZE_PER_JOB ?= 1

CRITICAL_QUEUES_SIZE ?= 0
CRITICAL_JOBS_SIZE_PER_QUEUE ?= 1
CRITICAL_PODS_SIZE_PER_JOB ?= 1

CPU_REQUEST_PER_POD ?= 1
MEMORY_REQUEST_PER_POD ?= 1Gi

CPU_PER_NODE ?= 16
MEMORY_PER_NODE ?= 64Gi

CPU_PER_QUEUE ?= 10000
MEMORY_PER_QUEUE ?= 10000Gi
CPU_LENDING_LIMIT ?=
MEMORY_LENDING_LIMIT ?=

GANG ?= false
PREEMPTION ?= false

COMPARISON_SCHEDULERS := kueue volcano yunikorn
SCHEDULERS ?= $(COMPARISON_SCHEDULERS)
RELATIVE_DASHBOARD_SCENARIO ?=
PROMETHEUS_URL ?= http://127.0.0.1:31003

LIMIT_CPU ?= 8

KIND_CLUSTER_NAME ?= volcano-benchmark-1348
KUBECONFIG ?= /root/benchmark-1348-deploy/kubeconfig
KUBECTL ?= /root/benchmark-1348-deploy/bin/kubectl
KUBECTL_CMD = $(KUBECTL) --kubeconfig $(KUBECONFIG)
RESIDENT_DEPLOY_DIR ?= /root/benchmark-1348-deploy
AUDIT_EXPORTER_NAMESPACE ?= kube-system
AUDIT_EXPORTER_DEPLOYMENT ?= kube-apiserver-audit-exporter
AUDIT_EXPORTER_CONTAINER ?= exporter
AUDIT_EXPORTER_LOG_PATH ?= /var/log/kubernetes/kube-apiserver-audit.log
AUDIT_REPORT_LOG_PATH ?= $(RESIDENT_DEPLOY_DIR)/logs/kube-apiserver-audit.log

IMAGE_PREFIX ?= 
GO_IMAGE ?= $(IMAGE_PREFIX)docker.io/library/golang:1.25
GOPROXY ?= https://proxy.golang.org,direct
GOOS ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
GO_IN_DOCKER = docker run --rm --network host \
	-u $(shell id -u):$(shell id -g) \
	-v $(shell pwd):/workspace/ -w /workspace/ \
	-e GOOS=$(GOOS) -e CGO_ENABLED=0 -e GOPATH=/workspace/gopath/ -e GOPROXY=$(GOPROXY) -e GOCACHE=/workspace/go-build $(GO_IMAGE)

TEST_ENVS = \
		SCHEDULERS="$(SCHEDULERS)" \
		NODES_SIZE=$(NODES_SIZE) \
		CPU_PER_NODE=$(CPU_PER_NODE) \
		MEMORY_PER_NODE=$(MEMORY_PER_NODE) \
		QUEUES_SIZE=$(QUEUES_SIZE) \
		JOBS_SIZE_PER_QUEUE=$(JOBS_SIZE_PER_QUEUE) \
		PODS_SIZE_PER_JOB=$(PODS_SIZE_PER_JOB) \
		IMPACTING_QUEUES_SIZE=$(IMPACTING_QUEUES_SIZE) \
		IMPACTING_JOBS_SIZE_PER_QUEUE=$(IMPACTING_JOBS_SIZE_PER_QUEUE) \
		IMPACTING_PODS_SIZE_PER_JOB=$(IMPACTING_PODS_SIZE_PER_JOB) \
		CRITICAL_QUEUES_SIZE=$(CRITICAL_QUEUES_SIZE) \
		CRITICAL_JOBS_SIZE_PER_QUEUE=$(CRITICAL_JOBS_SIZE_PER_QUEUE) \
		CRITICAL_PODS_SIZE_PER_JOB=$(CRITICAL_PODS_SIZE_PER_JOB) \
		CPU_PER_QUEUE=$(CPU_PER_QUEUE) \
		MEMORY_PER_QUEUE=$(MEMORY_PER_QUEUE) \
		CPU_LENDING_LIMIT=$(CPU_LENDING_LIMIT) \
		MEMORY_LENDING_LIMIT=$(MEMORY_LENDING_LIMIT) \
		CPU_REQUEST_PER_POD=$(CPU_REQUEST_PER_POD) \
		MEMORY_REQUEST_PER_POD=$(MEMORY_REQUEST_PER_POD) \
		PREEMPTION=$(PREEMPTION) \
		GANG=$(GANG)

.PHONY: default
default: ensure-directories
	$(MAKE) scenario-1
	$(MAKE) scenario-2
	$(MAKE) scenario-3
	$(MAKE) scenario-4
	$(MAKE) scenario-5
	$(MAKE) scenario-6
	$(MAKE) scenario-7
	$(MAKE) scenario-8

.PHONY: scenario-1
scenario-1:
	$(MAKE) serial-test \
		RELATIVE_DASHBOARD_SCENARIO=1 \
		TEST_TIMEOUT_SECONDS=350 \
		NODES_SIZE=1000 \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=10000  PODS_SIZE_PER_JOB=1

.PHONY: scenario-2
scenario-2:
	$(MAKE) serial-test \
		RELATIVE_DASHBOARD_SCENARIO=2 \
		TEST_TIMEOUT_SECONDS=200 \
		NODES_SIZE=1000 \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=500    PODS_SIZE_PER_JOB=20

.PHONY: scenario-3
scenario-3:
	$(MAKE) serial-test \
		RELATIVE_DASHBOARD_SCENARIO=3 \
		TEST_TIMEOUT_SECONDS=160 \
		NODES_SIZE=1000 \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=20     PODS_SIZE_PER_JOB=500

.PHONY: scenario-4
scenario-4:
	$(MAKE) serial-test \
		RELATIVE_DASHBOARD_SCENARIO=4 \
		TEST_TIMEOUT_SECONDS=190 \
		NODES_SIZE=1000 \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=1      PODS_SIZE_PER_JOB=10000

.PHONY: scenario-5
scenario-5:
	$(MAKE) serial-test \
		RELATIVE_DASHBOARD_SCENARIO=5 \
		TEST_TIMEOUT_SECONDS=430 \
		NODES_SIZE=1000 GANG=true \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=10000  PODS_SIZE_PER_JOB=1

.PHONY: scenario-6
scenario-6:
	$(MAKE) serial-test \
		RELATIVE_DASHBOARD_SCENARIO=6 \
		TEST_TIMEOUT_SECONDS=310 \
		NODES_SIZE=1000 GANG=true \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=500    PODS_SIZE_PER_JOB=20

.PHONY: scenario-7
scenario-7:
	$(MAKE) serial-test \
		RELATIVE_DASHBOARD_SCENARIO=7 \
		TEST_TIMEOUT_SECONDS=310 \
		NODES_SIZE=1000 GANG=true \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=20     PODS_SIZE_PER_JOB=500

.PHONY: scenario-8
scenario-8:
	$(MAKE) serial-test \
		RELATIVE_DASHBOARD_SCENARIO=8 \
		TEST_TIMEOUT_SECONDS=400 \
		NODES_SIZE=1000 GANG=true \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=1      PODS_SIZE_PER_JOB=10000

.PHONY: ensure-directories
ensure-directories:
	./hack/ensure-directories.sh

define test-scheduler

.PHONY: prepare-$(1)
prepare-$(1):
	make up-$(1)
	make wait-$(1)
	make test-init-$(1)

.PHONY: start-$(1)
start-$(1):
	make reset-auditlog-$(1)
	mkdir -p ./tmp
	wc -c < $(AUDIT_REPORT_LOG_PATH) > ./tmp/result-$(1)-audit-from-bytes
	date +%s%3N > ./tmp/result-$(1)-from-millis
	make test-batch-job-$(1)

.PHONY: end-$(1)
end-$(1):
	$(MAKE) wait-audit-metrics-scraped SCHEDULER=$(1)
	mkdir -p ./tmp
	@timestamp="$$$$(date +%s%3N)"; audit_bytes="$$$$(wc -c < $(AUDIT_REPORT_LOG_PATH))"; \
	printf '%s\n' "$$$$timestamp" > ./tmp/result-$(1)-to-millis; \
	printf '%s\n' "$$$$audit_bytes" > ./tmp/result-$(1)-audit-to-bytes; \
	printf '%s\n' "$$$$timestamp" > ./tmp/result-to-millis
	$(MAKE) down-$(1)

.PHONY: up-$(1)
up-$(1):
	$(MAKE) activate-$(1)

.PHONY: down-$(1)
down-$(1):
	$(MAKE) deactivate-$(1)

.PHONY: wait-$(1)
wait-$(1):
	$(MAKE) wait-resident-$(1)

bin/test-$(1): $(shell find ./test/utils ./test/$(1) -type f)
	$(GO_IN_DOCKER) go test -c -o ./bin/test-$(1) ./test/$(1)

.PHONY: test-init-$(1)
test-init-$(1): bin/test-$(1)
	KUBECONFIG=$(KUBECONFIG) ./bin/test-$(1) -test.timeout $(TEST_TIMEOUT_SECONDS)s -test.run '^TestInit' -test.v

.PHONY: test-batch-job-$(1)
test-batch-job-$(1): test-batch-job-$(1)
	KUBECONFIG=$(KUBECONFIG) ./bin/test-$(1) -test.timeout $(TEST_TIMEOUT_SECONDS)s -test.run '^TestBatchJob' -test.v

.PHONY: reset-auditlog-$(1)
reset-auditlog-$(1):
	$(MAKE) reset-audit-exporter SCHEDULER=$(1)

endef

$(foreach sched,$(SCHEDULERS),$(eval $(call test-scheduler,$(sched))))

bin/crop-dashboard-image: hack/crop-dashboard-image.go
	mkdir -p ./bin
	$(GO_IN_DOCKER) go build -o ./bin/crop-dashboard-image ./hack/crop-dashboard-image.go

.PHONY: wait-deployment-replicas
wait-deployment-replicas:
	@set -eu; \
		for target in $(WAIT_DEPLOYMENTS); do \
			ref="$${target%=*}"; expected="$${target##*=}"; \
			namespace="$${ref%/*}"; name="$${ref#*/}"; ready=false; \
			for attempt in $$(seq 1 300); do \
				object="$$( $(KUBECTL_CMD) get deployment -n "$$namespace" "$$name" -o json )"; \
				selector="$$(printf '%s' "$$object" | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')"; \
				pods="$$( $(KUBECTL_CMD) get pods -n "$$namespace" -l "$$selector" -o name )"; \
				if printf '%s' "$$object" | jq -e --argjson expected "$$expected" \
					'(.spec.replicas // 1) == $$expected and (.status.observedGeneration // 0) >= .metadata.generation and (.status.replicas // 0) == $$expected and (.status.readyReplicas // 0) == $$expected and (.status.availableReplicas // 0) == $$expected and (.status.updatedReplicas // 0) == $$expected' >/dev/null && \
					{ test "$$expected" != 0 || test -z "$$pods"; }; then ready=true; break; fi; \
				sleep 1; \
			done; \
			if test "$$ready" != true; then echo "Deployment did not converge: $$ref=$$expected" >&2; exit 1; fi; \
		done

.PHONY: reset-audit-exporter
reset-audit-exporter:
	@test -n "$(SCHEDULER)" || (echo 'SCHEDULER is required' >&2; exit 1)
	$(KUBECTL_CMD) scale deployment -n $(AUDIT_EXPORTER_NAMESPACE) $(AUDIT_EXPORTER_DEPLOYMENT) --replicas=0
	$(MAKE) wait-deployment-replicas WAIT_DEPLOYMENTS='$(AUDIT_EXPORTER_NAMESPACE)/$(AUDIT_EXPORTER_DEPLOYMENT)=0'
	@patch="$$(jq -nc --arg container '$(AUDIT_EXPORTER_CONTAINER)' --arg log '$(AUDIT_EXPORTER_LOG_PATH)' --arg scheduler '$(SCHEDULER)' \
		'{spec:{template:{spec:{containers:[{name:$$container,args:["--audit-log-path",$$log,"--cluster-label",$$scheduler,"--start-at-end"]}]}}}}')"; \
	$(KUBECTL_CMD) patch deployment -n $(AUDIT_EXPORTER_NAMESPACE) $(AUDIT_EXPORTER_DEPLOYMENT) --type=strategic -p "$$patch"
	$(KUBECTL_CMD) scale deployment -n $(AUDIT_EXPORTER_NAMESPACE) $(AUDIT_EXPORTER_DEPLOYMENT) --replicas=1
	$(MAKE) wait-deployment-replicas WAIT_DEPLOYMENTS='$(AUDIT_EXPORTER_NAMESPACE)/$(AUDIT_EXPORTER_DEPLOYMENT)=1'

.PHONY: wait-audit-metrics-scraped
wait-audit-metrics-scraped:
	@test -n "$(SCHEDULER)" || (echo 'SCHEDULER is required' >&2; exit 1)
	@set -eu; \
		last=-1; stable=0; stable_at=0; attempt=0; \
		deadline=$$(( $$(date +%s) + $(RESULT_METRICS_TIMEOUT_SECONDS) )); \
		while test "$$(date +%s)" -lt "$$deadline"; do \
			attempt=$$((attempt + 1)); \
			sleep 1; \
			if ! exporter_metrics="$$( $(KUBECTL_CMD) --request-timeout=5s get --raw '/api/v1/namespaces/$(AUDIT_EXPORTER_NAMESPACE)/services/$(AUDIT_EXPORTER_DEPLOYMENT):8080/proxy/metrics' 2>/dev/null )"; then \
				stable=0; stable_at=0; \
				printf 'audit_metrics_retry scheduler=%s attempt=%s source=exporter\n' '$(SCHEDULER)' "$$attempt" >&2; \
				continue; \
			fi; \
			exporter_total="$$(printf '%s\n' "$$exporter_metrics" | awk '/^api_requests_total\{/{sum += $$NF} END {printf "%.0f", sum + 0}')"; \
			if test "$$exporter_total" = "$$last"; then stable=$$((stable + 1)); else stable=0; stable_at=0; fi; \
			if test "$$stable" -ge 2 && test "$$stable_at" = 0; then stable_at="$$(date +%s%3N)"; fi; \
			last="$$exporter_total"; \
			if ! prometheus_response="$$(curl -fsS --connect-timeout 2 --max-time 5 --get --data-urlencode 'query=sum(api_requests_total{cluster="$(SCHEDULER)"})' http://127.0.0.1:31003/api/v1/query)"; then \
				printf 'audit_metrics_retry scheduler=%s attempt=%s source=prometheus-total\n' '$(SCHEDULER)' "$$attempt" >&2; \
				continue; \
			fi; \
			if ! prometheus_total="$$(printf '%s\n' "$$prometheus_response" | jq -er 'if .status == "success" and (.data.result | length) > 0 then .data.result[0].value[1] else "0" end')"; then \
				printf 'audit_metrics_retry scheduler=%s attempt=%s source=prometheus-total-response\n' '$(SCHEDULER)' "$$attempt" >&2; \
				continue; \
			fi; \
			if ! prometheus_response="$$(curl -fsS --connect-timeout 2 --max-time 5 --get --data-urlencode 'query=max(timestamp(api_requests_total{cluster="$(SCHEDULER)"}))*1000' http://127.0.0.1:31003/api/v1/query)"; then \
				printf 'audit_metrics_retry scheduler=%s attempt=%s source=prometheus-timestamp\n' '$(SCHEDULER)' "$$attempt" >&2; \
				continue; \
			fi; \
			if ! prometheus_timestamp="$$(printf '%s\n' "$$prometheus_response" | jq -er 'if .status == "success" and (.data.result | length) > 0 then .data.result[0].value[1] else "0" end')"; then \
				printf 'audit_metrics_retry scheduler=%s attempt=%s source=prometheus-timestamp-response\n' '$(SCHEDULER)' "$$attempt" >&2; \
				continue; \
			fi; \
			if test "$$stable" -ge 2 && test "$$exporter_total" -gt 0 && \
				awk -v observed="$$prometheus_total" -v expected="$$exporter_total" 'BEGIN { exit !(observed >= expected) }' && \
				awk -v observed="$$prometheus_timestamp" -v expected="$$stable_at" 'BEGIN { exit !(observed >= expected) }'; then \
				printf 'audit_metrics_scraped scheduler=%s total=%s sample_millis=%s\n' '$(SCHEDULER)' "$$exporter_total" "$$prometheus_timestamp"; exit 0; \
			fi; \
		done; \
		echo 'Timed out waiting for Audit Exporter metrics to reach Prometheus for $(SCHEDULER)' >&2; exit 1

.PHONY: cleanup-kueue-resources
cleanup-kueue-resources:
	$(KUBECTL_CMD) delete jobs.batch --all -n bench-kueue --ignore-not-found --wait=false
	$(KUBECTL_CMD) delete podgroups.scheduling.x-k8s.io --all -n bench-kueue --ignore-not-found --wait=false
	$(KUBECTL_CMD) delete workloads.kueue.x-k8s.io --all -n bench-kueue --ignore-not-found --wait=false
	$(KUBECTL_CMD) delete localqueues.kueue.x-k8s.io --all -n bench-kueue --ignore-not-found --wait=false
	$(KUBECTL_CMD) delete pods --all -n bench-kueue --ignore-not-found --force --grace-period=0 --wait=false
	$(MAKE) wait-no-kueue-namespaced-resources
	@set -eu; \
		resources="$$( $(KUBECTL_CMD) get clusterqueues.kueue.x-k8s.io -o name )"; \
		for resource in $$resources; do \
			case "$$resource" in clusterqueue.kueue.x-k8s.io/default-cluster-queue-*) $(KUBECTL_CMD) delete "$$resource" --ignore-not-found --timeout=5m;; esac; \
		done
	$(KUBECTL_CMD) delete resourceflavors.kueue.x-k8s.io default --ignore-not-found --timeout=5m
	$(KUBECTL_CMD) delete workloadpriorityclasses.kueue.x-k8s.io \
		human-critical business-impacting long-term-research --ignore-not-found --timeout=5m
	$(MAKE) assert-no-kueue-resources

.PHONY: wait-no-kueue-namespaced-resources
wait-no-kueue-namespaced-resources:
	@set -eu; \
		for attempt in $$(seq 1 $(CLEANUP_TIMEOUT_SECONDS)); do \
			residual="$$( $(KUBECTL_CMD) get jobs.batch,pods,workloads.kueue.x-k8s.io,localqueues.kueue.x-k8s.io,podgroups.scheduling.x-k8s.io -n bench-kueue -o name )"; \
			test -z "$$residual" && exit 0; \
			sleep 1; \
		done; \
		printf 'Residual namespaced Kueue resources after %s seconds:\n%s\n' '$(CLEANUP_TIMEOUT_SECONDS)' "$$residual" >&2; exit 1

.PHONY: cleanup-volcano-resources
cleanup-volcano-resources:
	$(KUBECTL_CMD) delete jobs.batch.volcano.sh --all -n bench-volcano --ignore-not-found --timeout=5m
	$(KUBECTL_CMD) delete pods --all -n bench-volcano --ignore-not-found --force --grace-period=0 --timeout=5m
	@set -eu; \
		resources="$$( $(KUBECTL_CMD) get queues.scheduling.volcano.sh -o name )"; \
		for resource in $$resources; do \
			case "$$resource" in queue.scheduling.volcano.sh/test-queue-*) $(KUBECTL_CMD) delete "$$resource" --ignore-not-found --timeout=5m;; esac; \
		done
	$(KUBECTL_CMD) delete queues.scheduling.volcano.sh benchmark-root --ignore-not-found --timeout=5m
	$(KUBECTL_CMD) delete priorityclasses.scheduling.k8s.io \
		human-critical business-impacting long-term-research --ignore-not-found --timeout=5m
	$(MAKE) assert-no-volcano-resources

.PHONY: cleanup-yunikorn-resources
cleanup-yunikorn-resources:
	$(KUBECTL_CMD) delete jobs.batch --all -n bench-yunikorn --ignore-not-found --timeout=5m
	$(KUBECTL_CMD) delete pods --all -n bench-yunikorn --ignore-not-found --force --grace-period=0 --timeout=5m
	$(MAKE) assert-no-yunikorn-resources

.PHONY: assert-no-kueue-resources
assert-no-kueue-resources:
	@set -eu; \
		for attempt in $$(seq 1 $(CLEANUP_TIMEOUT_SECONDS)); do \
			namespaced="$$( $(KUBECTL_CMD) get jobs.batch,pods,workloads.kueue.x-k8s.io,localqueues.kueue.x-k8s.io,podgroups.scheduling.x-k8s.io -n bench-kueue -o name )"; \
			all_queues="$$( $(KUBECTL_CMD) get clusterqueues.kueue.x-k8s.io -o name )"; \
			queues="$$(printf '%s\n' "$$all_queues" | sed -n '/\/default-cluster-queue-/p')"; \
			flavor="$$( $(KUBECTL_CMD) get resourceflavors.kueue.x-k8s.io default -o name --ignore-not-found )"; \
			priorities=''; \
			for name in human-critical business-impacting long-term-research; do item="$$( $(KUBECTL_CMD) get workloadpriorityclasses.kueue.x-k8s.io "$$name" -o name --ignore-not-found )"; priorities="$${priorities}$${item}"; done; \
			residual="$${namespaced}$${queues}$${flavor}$${priorities}"; \
			test -z "$$residual" && exit 0; \
			sleep 1; \
		done; \
		printf 'Residual Kueue resources:\n%s\n' "$$residual" >&2; exit 1

.PHONY: assert-no-volcano-resources
assert-no-volcano-resources:
	@set -eu; \
		for attempt in $$(seq 1 300); do \
			namespaced="$$( $(KUBECTL_CMD) get jobs.batch.volcano.sh,pods -n bench-volcano -o name )"; \
			all_queues="$$( $(KUBECTL_CMD) get queues.scheduling.volcano.sh -o name )"; \
			queues="$$(printf '%s\n' "$$all_queues" | sed -n -e '/\/benchmark-root$$/p' -e '/\/test-queue-/p')"; \
			priorities=''; \
			for name in human-critical business-impacting long-term-research; do item="$$( $(KUBECTL_CMD) get priorityclasses.scheduling.k8s.io "$$name" -o name --ignore-not-found )"; priorities="$${priorities}$${item}"; done; \
			residual="$${namespaced}$${queues}$${priorities}"; \
			test -z "$$residual" && exit 0; \
			sleep 1; \
		done; \
		printf 'Residual Volcano resources:\n%s\n' "$$residual" >&2; exit 1

.PHONY: assert-no-yunikorn-resources
assert-no-yunikorn-resources:
	@set -eu; \
		for attempt in $$(seq 1 300); do \
			residual="$$( $(KUBECTL_CMD) get jobs.batch,pods -n bench-yunikorn -o name )"; \
			test -z "$$residual" && exit 0; \
			sleep 1; \
		done; \
		printf 'Residual YuniKorn resources:\n%s\n' "$$residual" >&2; exit 1

.PHONY: enable-all-schedulers
enable-all-schedulers:
	$(KUBECTL_CMD) scale deployment -n kueue-system kueue-controller-manager --replicas=1
	$(KUBECTL_CMD) scale deployment -n coscheduling coscheduling scheduler-plugins-controller --replicas=1
	$(KUBECTL_CMD) scale deployment -n volcano-system volcano-scheduler volcano-controllers volcano-admission --replicas=1
	$(KUBECTL_CMD) scale deployment -n yunikorn yunikorn-scheduler yunikorn-admission-controller --replicas=1

.PHONY: ensure-audit-exporter-running
ensure-audit-exporter-running:
	$(KUBECTL_CMD) scale deployment -n $(AUDIT_EXPORTER_NAMESPACE) $(AUDIT_EXPORTER_DEPLOYMENT) --replicas=1
	$(MAKE) wait-deployment-replicas WAIT_DEPLOYMENTS='$(AUDIT_EXPORTER_NAMESPACE)/$(AUDIT_EXPORTER_DEPLOYMENT)=1'

.PHONY: activate-kueue
activate-kueue:
	$(KUBECTL_CMD) scale deployment -n volcano-system volcano-scheduler volcano-controllers volcano-admission --replicas=0
	$(KUBECTL_CMD) scale deployment -n yunikorn yunikorn-scheduler yunikorn-admission-controller --replicas=0
	$(KUBECTL_CMD) scale deployment -n kueue-system kueue-controller-manager --replicas=1
	$(KUBECTL_CMD) scale deployment -n coscheduling coscheduling scheduler-plugins-controller --replicas=1
	$(MAKE) wait-deployment-replicas WAIT_DEPLOYMENTS='kueue-system/kueue-controller-manager=1 coscheduling/coscheduling=1 coscheduling/scheduler-plugins-controller=1 volcano-system/volcano-scheduler=0 volcano-system/volcano-controllers=0 volcano-system/volcano-admission=0 yunikorn/yunikorn-scheduler=0 yunikorn/yunikorn-admission-controller=0'
	$(MAKE) cleanup-kueue-resources

.PHONY: activate-volcano
activate-volcano:
	$(KUBECTL_CMD) scale deployment -n kueue-system kueue-controller-manager --replicas=0
	$(KUBECTL_CMD) scale deployment -n coscheduling coscheduling scheduler-plugins-controller --replicas=0
	$(KUBECTL_CMD) scale deployment -n yunikorn yunikorn-scheduler yunikorn-admission-controller --replicas=0
	$(KUBECTL_CMD) scale deployment -n volcano-system volcano-scheduler volcano-controllers volcano-admission --replicas=1
	$(MAKE) wait-deployment-replicas WAIT_DEPLOYMENTS='kueue-system/kueue-controller-manager=0 coscheduling/coscheduling=0 coscheduling/scheduler-plugins-controller=0 volcano-system/volcano-scheduler=1 volcano-system/volcano-controllers=1 volcano-system/volcano-admission=1 yunikorn/yunikorn-scheduler=0 yunikorn/yunikorn-admission-controller=0'
	$(MAKE) cleanup-volcano-resources

.PHONY: activate-yunikorn
activate-yunikorn:
	$(KUBECTL_CMD) scale deployment -n volcano-system volcano-scheduler volcano-controllers volcano-admission --replicas=0
	$(KUBECTL_CMD) scale deployment -n kueue-system kueue-controller-manager --replicas=0
	$(KUBECTL_CMD) scale deployment -n coscheduling coscheduling scheduler-plugins-controller --replicas=0
	$(KUBECTL_CMD) scale deployment -n yunikorn yunikorn-scheduler yunikorn-admission-controller --replicas=1
	$(MAKE) wait-deployment-replicas WAIT_DEPLOYMENTS='kueue-system/kueue-controller-manager=0 coscheduling/coscheduling=0 coscheduling/scheduler-plugins-controller=0 volcano-system/volcano-scheduler=0 volcano-system/volcano-controllers=0 volcano-system/volcano-admission=0 yunikorn/yunikorn-scheduler=1 yunikorn/yunikorn-admission-controller=1'
	$(MAKE) cleanup-yunikorn-resources

.PHONY: deactivate-kueue
deactivate-kueue:
	$(MAKE) cleanup-kueue-resources
	$(MAKE) enable-all-schedulers
	$(MAKE) wait-all-schedulers

.PHONY: deactivate-volcano
deactivate-volcano:
	$(MAKE) cleanup-volcano-resources
	$(MAKE) enable-all-schedulers
	$(MAKE) wait-all-schedulers

.PHONY: deactivate-yunikorn
deactivate-yunikorn:
	$(MAKE) cleanup-yunikorn-resources
	$(MAKE) enable-all-schedulers
	$(MAKE) wait-all-schedulers

.PHONY: wait-resident-kueue
wait-resident-kueue:
	$(MAKE) wait-deployment-replicas WAIT_DEPLOYMENTS='kueue-system/kueue-controller-manager=1 coscheduling/coscheduling=1 coscheduling/scheduler-plugins-controller=1 volcano-system/volcano-scheduler=0 volcano-system/volcano-controllers=0 volcano-system/volcano-admission=0 yunikorn/yunikorn-scheduler=0 yunikorn/yunikorn-admission-controller=0'
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-base.sh 1000

.PHONY: wait-resident-volcano
wait-resident-volcano:
	$(MAKE) wait-deployment-replicas WAIT_DEPLOYMENTS='kueue-system/kueue-controller-manager=0 coscheduling/coscheduling=0 coscheduling/scheduler-plugins-controller=0 volcano-system/volcano-scheduler=1 volcano-system/volcano-controllers=1 volcano-system/volcano-admission=1 yunikorn/yunikorn-scheduler=0 yunikorn/yunikorn-admission-controller=0'
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-base.sh 1000

.PHONY: wait-resident-yunikorn
wait-resident-yunikorn:
	$(MAKE) wait-deployment-replicas WAIT_DEPLOYMENTS='kueue-system/kueue-controller-manager=0 coscheduling/coscheduling=0 coscheduling/scheduler-plugins-controller=0 volcano-system/volcano-scheduler=0 volcano-system/volcano-controllers=0 volcano-system/volcano-admission=0 yunikorn/yunikorn-scheduler=1 yunikorn/yunikorn-admission-controller=1'
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-base.sh 1000

.PHONY: wait-all-schedulers
wait-all-schedulers:
	$(MAKE) wait-deployment-replicas WAIT_DEPLOYMENTS='kueue-system/kueue-controller-manager=1 coscheduling/coscheduling=1 coscheduling/scheduler-plugins-controller=1 volcano-system/volcano-scheduler=1 volcano-system/volcano-controllers=1 volcano-system/volcano-admission=1 yunikorn/yunikorn-scheduler=1 yunikorn/yunikorn-admission-controller=1 $(AUDIT_EXPORTER_NAMESPACE)/$(AUDIT_EXPORTER_DEPLOYMENT)=1'
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-base.sh 1000

bin/kind:
	$(GO_IN_DOCKER) go build -o ./bin/kind sigs.k8s.io/kind

.PHONY: up
up: ensure-directories
	echo $(TEST_ENVS)
	test "$$($(KUBECTL_CMD) config view --minify -o jsonpath='{.clusters[0].name}')" = "kind-$(KIND_CLUSTER_NAME)"
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-base.sh 1000
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-schedulers.sh
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-monitoring.sh
	$(MAKE) -j $(addprefix bin/test-,$(SCHEDULERS))

.PHONY: down
down:
	$(MAKE) enable-all-schedulers
	$(MAKE) ensure-audit-exporter-running
	$(MAKE) wait-all-schedulers
	$(MAKE) cleanup-kueue-resources
	$(MAKE) cleanup-volcano-resources
	$(MAKE) cleanup-yunikorn-resources
	$(MAKE) wait-all-schedulers

.PHONY: validate-result-scenario
validate-result-scenario:
	@case "$(RELATIVE_DASHBOARD_SCENARIO)" in \
		1|2|3|4|5|6|7|8) ;; \
		*) echo 'RELATIVE_DASHBOARD_SCENARIO must be an integer from 1 to 8' >&2; exit 1;; \
	esac

.PHONY: serial-test
serial-test: validate-result-scenario ensure-directories
	mkdir -p ./tmp
	rm -f ./tmp/result-to-millis \
		./tmp/relative-dashboard-from-millis ./tmp/relative-dashboard-to-millis \
		./tmp/relative-dashboard-from-iso ./tmp/relative-dashboard-to-iso
	@for sched in $(SCHEDULERS); do \
		rm -f "./tmp/result-$$sched-from-millis" "./tmp/result-$$sched-to-millis" \
			"./tmp/result-$$sched-audit-from-bytes" "./tmp/result-$$sched-audit-to-bytes"; \
	done
	date +%s%3N > ./tmp/result-from-millis
	$(foreach sched,$(SCHEDULERS), \
		$(MAKE) prepare-$(sched); \
		$(MAKE) start-$(sched); \
		$(MAKE) end-$(sched); \
	)

	@if test "$(strip $(SCHEDULERS))" = "$(COMPARISON_SCHEDULERS)"; then \
		$(MAKE) update-relative-dashboard SCENARIO="$(RELATIVE_DASHBOARD_SCENARIO)"; \
		$(MAKE) save-result; \
	fi
	$(foreach sched,$(SCHEDULERS), \
		$(MAKE) save-scheduler-result SCHEDULER=$(sched) SCENARIO=$(RELATIVE_DASHBOARD_SCENARIO); \
	)
	@for sched in $(SCHEDULERS); do \
		rm -f "./tmp/result-$$sched-from-millis" "./tmp/result-$$sched-to-millis" \
			"./tmp/result-$$sched-audit-from-bytes" "./tmp/result-$$sched-audit-to-bytes"; \
	done
	rm -f ./tmp/result-from-millis ./tmp/result-to-millis
	rm -f ./tmp/relative-dashboard-from-millis ./tmp/relative-dashboard-to-millis \
		./tmp/relative-dashboard-from-iso ./tmp/relative-dashboard-to-iso

.PHONY: update-relative-dashboard
update-relative-dashboard:
	@test -n "$(SCENARIO)" || (echo 'SCENARIO is required' >&2; exit 1)
	SCENARIO="$(SCENARIO)" \
	GANG="$(GANG)" \
	JOBS_SIZE_PER_QUEUE="$(JOBS_SIZE_PER_QUEUE)" \
	PODS_SIZE_PER_JOB="$(PODS_SIZE_PER_JOB)" \
	RESULT_WINDOW_DIR="$(CURDIR)/tmp" \
	PROMETHEUS_URL="$(PROMETHEUS_URL)" \
	KUBECTL="$(KUBECTL)" \
	KUBECONFIG="$(KUBECONFIG)" \
	./hack/update-relative-dashboard.sh

.PHONY: save-scheduler-result
save-scheduler-result:
	@case "$(SCENARIO)" in \
		1|2|3|4|5|6|7|8) ;; \
		*) echo 'SCENARIO must be an integer from 1 to 8' >&2; exit 1;; \
	esac
	@case "$(SCHEDULER)" in \
		kueue|volcano|yunikorn) ;; \
		*) echo 'SCHEDULER must be kueue, volcano, or yunikorn' >&2; exit 1;; \
	esac
	test -s ./tmp/result-$(SCHEDULER)-from-millis
	test -s ./tmp/result-$(SCHEDULER)-to-millis
	test -s ./tmp/result-$(SCHEDULER)-audit-from-bytes
	test -s ./tmp/result-$(SCHEDULER)-audit-to-bytes
	test ! -e ./tmp/result-$(SCHEDULER)-staging || (echo 'Scheduler result staging already exists: ./tmp/result-$(SCHEDULER)-staging' >&2; exit 1)
	mkdir -p ./tmp/result-$(SCHEDULER)-staging
	SCHEDULER="$(SCHEDULER)" \
	FROM_MILLIS="$$(cat ./tmp/result-$(SCHEDULER)-from-millis)" \
	TO_MILLIS="$$(cat ./tmp/result-$(SCHEDULER)-to-millis)" \
	AUDIT_FROM_BYTES="$$(cat ./tmp/result-$(SCHEDULER)-audit-from-bytes)" \
	AUDIT_TO_BYTES="$$(cat ./tmp/result-$(SCHEDULER)-audit-to-bytes)" \
	OUTPUT_DIR="$(CURDIR)/tmp/result-$(SCHEDULER)-staging" \
	PROMETHEUS_URL="$(PROMETHEUS_URL)" \
	AUDIT_LOG_PATH="$(AUDIT_REPORT_LOG_PATH)" \
	./hack/save-scheduler-result.sh
	@target="./results/scenario-$(SCENARIO)/$(SCHEDULER)"; \
	mkdir -p "$$(dirname "$$target")"; \
	rm -rf -- "$$target"; \
	mv ./tmp/result-$(SCHEDULER)-staging "$$target"

.PHONY: up-overview
up-overview:
	make -C ./clusters/overview up

.PHONY: down-overview
down-overview:
	make -C ./clusters/overview down

.PHONY: wait-overview
wait-overview:
	make -C ./clusters/overview wait

.PHONY: prepare-overview
prepare-overview:
	make up-overview
	make wait-overview

.PHONY: start-overview
start-overview:
	make -C ./clusters/overview start-export

.PHONY: end-overview
end-overview:
	make down-overview

.PHONY: save-result
save-result: validate-result-scenario
	test "$(strip $(SCHEDULERS))" = "$(COMPARISON_SCHEDULERS)"
	test -s ./tmp/result-from-millis
	test -s ./tmp/result-to-millis
	test ! -e ./tmp/result-staging || (echo 'Result staging already exists: ./tmp/result-staging' >&2; exit 1)
	mkdir -p ./tmp/result-staging
	echo $(TEST_ENVS) > ./tmp/result-staging/envs.txt
	printf 'from=%s\nto=%s\n' "$$(cat ./tmp/result-from-millis)" "$$(cat ./tmp/result-to-millis)" > ./tmp/result-staging/result-window.txt
	@if $(MAKE) bin/crop-dashboard-image && \
			SCENARIO="$(RELATIVE_DASHBOARD_SCENARIO)" \
			FROM="$$(cat ./tmp/relative-dashboard-from-millis)" \
			TO="$$(cat ./tmp/relative-dashboard-to-millis)" \
			FROM_ISO="$$(cat ./tmp/relative-dashboard-from-iso)" \
			TO_ISO="$$(cat ./tmp/relative-dashboard-to-iso)" \
			OUTPUT_FILE="$(CURDIR)/tmp/result-staging/job-submission.png" \
			./hack/save-relative-dashboard-image.sh; then \
			:; \
	else \
		status=$$?; \
		echo "warning: relative Dashboard image was not saved (exit $$status)" >&2; \
		rm -f ./tmp/result-staging/job-submission.png; \
	fi
	@set -eu; \
		target="./results/scenario-$(RELATIVE_DASHBOARD_SCENARIO)"; \
		mkdir -p "$$(dirname "$$target")"; \
		rm -rf -- "$$target"; \
		mv ./tmp/result-staging "$$target"
	rm -f ./tmp/result-from-millis ./tmp/result-to-millis

.PHONY: delete-registry
delete-registry:
	-docker rm -f kind-registry

.PHONY: cleanup
cleanup:
	-make down \
		delete-registry
	-rm -rf ./logs/
