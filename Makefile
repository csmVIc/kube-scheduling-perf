export PATH := $(CURDIR)/bin:$(PATH)

TEST_TIMEOUT_SECONDS ?= 3600

RESULT_RECENT_DURATION_SECONDS ?= 300

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

SCHEDULERS ?= kueue volcano yunikorn

LIMIT_CPU ?= 8

KIND_CLUSTER_NAME ?= volcano-benchmark-1348
KUBECONFIG ?= /root/benchmark-1348-deploy/kubeconfig
KUBECTL ?= /root/benchmark-1348-deploy/bin/kubectl
KUBECTL_CMD = $(KUBECTL) --kubeconfig $(KUBECONFIG)
RESIDENT_DEPLOY_DIR ?= /root/benchmark-1348-deploy
RESIDENT_AUDIT_LOG ?= $(RESIDENT_DEPLOY_DIR)/logs/kube-apiserver-audit.log
RESIDENT_STATE_DIR ?= ./tmp/resident-state
CONTROL_PLANE_CONTAINER ?= $(KIND_CLUSTER_NAME)-control-plane

IMAGE_PREFIX ?= 
GO_IMAGE ?= $(IMAGE_PREFIX)docker.io/library/golang:1.25
GOPROXY ?= https://proxy.golang.org,direct
GOOS ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
GO_IN_DOCKER = docker run --rm --network host \
	-u $(shell id -u):$(shell id -g) \
	-v $(shell pwd):/workspace/ -w /workspace/ \
	-e GOOS=$(GOOS) -e CGO_ENABLED=0 -e GOPATH=/workspace/gopath/ -e GOPROXY=$(GOPROXY) -e GOCACHE=/workspace/go-build $(GO_IMAGE)

TEST_ENVS = \
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
	make serial-test \
		RESULT_RECENT_DURATION_SECONDS=250 TEST_TIMEOUT_SECONDS=350 \
		NODES_SIZE=1000 \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=10000  PODS_SIZE_PER_JOB=1
	make serial-test \
		RESULT_RECENT_DURATION_SECONDS=100 TEST_TIMEOUT_SECONDS=200 \
		NODES_SIZE=1000 \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=500    PODS_SIZE_PER_JOB=20
	make serial-test \
		RESULT_RECENT_DURATION_SECONDS=60 TEST_TIMEOUT_SECONDS=160 \
		NODES_SIZE=1000 \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=20     PODS_SIZE_PER_JOB=500
	make serial-test \
		RESULT_RECENT_DURATION_SECONDS=90 TEST_TIMEOUT_SECONDS=190 \
		NODES_SIZE=1000 \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=1      PODS_SIZE_PER_JOB=10000

	make serial-test \
		RESULT_RECENT_DURATION_SECONDS=330 TEST_TIMEOUT_SECONDS=430 \
		NODES_SIZE=1000 GANG=true \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=10000  PODS_SIZE_PER_JOB=1
	make serial-test \
		RESULT_RECENT_DURATION_SECONDS=210 TEST_TIMEOUT_SECONDS=310 \
		NODES_SIZE=1000 GANG=true \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=500    PODS_SIZE_PER_JOB=20
	make serial-test \
		RESULT_RECENT_DURATION_SECONDS=210 TEST_TIMEOUT_SECONDS=310 \
		NODES_SIZE=1000 GANG=true \
		QUEUES_SIZE=1  JOBS_SIZE_PER_QUEUE=20     PODS_SIZE_PER_JOB=500
	make serial-test \
		RESULT_RECENT_DURATION_SECONDS=300 TEST_TIMEOUT_SECONDS=400 \
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
	make test-batch-job-$(1)

.PHONY: end-$(1)
end-$(1):
	mkdir -p ./logs
	cp $(RESIDENT_AUDIT_LOG) ./logs/kube-apiserver-audit.$(1).log
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
	mkdir -p ./logs
	docker exec $(CONTROL_PLANE_CONTAINER) sh -c 'true > /var/log/kubernetes/kube-apiserver-audit.log'
	true > ./logs/kube-apiserver-audit.$(1).log

endef

$(foreach sched,$(SCHEDULERS),$(eval $(call test-scheduler,$(sched))))

.PHONY: ensure-no-resident-state
ensure-no-resident-state:
	mkdir -p $(RESIDENT_STATE_DIR)
	@test -z "$$(find $(RESIDENT_STATE_DIR) -maxdepth 1 -type f -print -quit)" || \
		(echo "Resident state exists; run 'make down' before starting another scheduler" >&2; exit 1)

.PHONY: cleanup-kueue-resources
cleanup-kueue-resources:
	-$(KUBECTL_CMD) delete jobs.batch --all -n bench-kueue --ignore-not-found --wait=false
	-$(KUBECTL_CMD) delete pods --all -n bench-kueue --ignore-not-found --force --grace-period=0
	-$(KUBECTL_CMD) delete workloads.kueue.x-k8s.io --all -n bench-kueue --ignore-not-found --wait=false
	-$(KUBECTL_CMD) delete localqueues.kueue.x-k8s.io --all -n bench-kueue --ignore-not-found --wait=false
	-$(KUBECTL_CMD) delete podgroups.scheduling.x-k8s.io --all -n bench-kueue --ignore-not-found --wait=false
	@$(KUBECTL_CMD) get clusterqueues.kueue.x-k8s.io -o name | \
		grep '^clusterqueue.kueue.x-k8s.io/default-cluster-queue-' | \
		xargs -r $(KUBECTL_CMD) delete --ignore-not-found --wait=false
	-$(KUBECTL_CMD) delete resourceflavors.kueue.x-k8s.io default --ignore-not-found --wait=false
	-$(KUBECTL_CMD) delete workloadpriorityclasses.kueue.x-k8s.io \
		human-critical business-impacting long-term-research --ignore-not-found --wait=false

.PHONY: cleanup-volcano-resources
cleanup-volcano-resources:
	-$(KUBECTL_CMD) delete jobs.batch.volcano.sh --all -n bench-volcano --ignore-not-found --wait=false
	-$(KUBECTL_CMD) delete pods --all -n bench-volcano --ignore-not-found --force --grace-period=0
	@$(KUBECTL_CMD) get queues.scheduling.volcano.sh -o name | \
		grep '^queue.scheduling.volcano.sh/test-queue-' | \
		xargs -r $(KUBECTL_CMD) delete --ignore-not-found --wait=false
	-$(KUBECTL_CMD) delete queues.scheduling.volcano.sh benchmark-root --ignore-not-found --wait=false
	-$(KUBECTL_CMD) delete priorityclasses.scheduling.k8s.io \
		human-critical business-impacting long-term-research --ignore-not-found --wait=false

.PHONY: cleanup-yunikorn-resources
cleanup-yunikorn-resources:
	-$(KUBECTL_CMD) delete jobs.batch --all -n bench-yunikorn --ignore-not-found --wait=false
	-$(KUBECTL_CMD) delete pods --all -n bench-yunikorn --ignore-not-found --force --grace-period=0

.PHONY: restore-all-scheduler-deployments
restore-all-scheduler-deployments:
	$(KUBECTL_CMD) scale deployment -n kueue-system kueue-controller-manager --replicas=1
	$(KUBECTL_CMD) scale deployment -n coscheduling coscheduling scheduler-plugins-controller --replicas=1
	$(KUBECTL_CMD) scale deployment -n volcano-system volcano-scheduler volcano-controllers volcano-admission --replicas=1
	$(KUBECTL_CMD) scale deployment -n yunikorn yunikorn-scheduler yunikorn-admission-controller --replicas=1

.PHONY: restore-volcano-config
restore-volcano-config:
	@if [ -f $(RESIDENT_STATE_DIR)/volcano-scheduler-configmap.json ]; then \
		set -e; \
		$(KUBECTL_CMD) delete configmap -n volcano-system volcano-scheduler-configmap --ignore-not-found; \
		$(KUBECTL_CMD) create -f $(RESIDENT_STATE_DIR)/volcano-scheduler-configmap.json; \
		rm -f $(RESIDENT_STATE_DIR)/volcano-scheduler-configmap.json; \
		$(KUBECTL_CMD) rollout restart deployment -n volcano-system volcano-scheduler; \
	fi

.PHONY: restore-yunikorn-config
restore-yunikorn-config:
	@if [ -f $(RESIDENT_STATE_DIR)/yunikorn-configs.json ]; then \
		set -e; \
		$(KUBECTL_CMD) delete configmap -n yunikorn yunikorn-configs --ignore-not-found; \
		$(KUBECTL_CMD) create -f $(RESIDENT_STATE_DIR)/yunikorn-configs.json; \
		rm -f $(RESIDENT_STATE_DIR)/yunikorn-configs.json; \
		$(KUBECTL_CMD) rollout restart deployment -n yunikorn yunikorn-scheduler; \
	elif [ -f $(RESIDENT_STATE_DIR)/yunikorn-configs.absent ]; then \
		set -e; \
		$(KUBECTL_CMD) delete configmap -n yunikorn yunikorn-configs --ignore-not-found; \
		rm -f $(RESIDENT_STATE_DIR)/yunikorn-configs.absent; \
		$(KUBECTL_CMD) rollout restart deployment -n yunikorn yunikorn-scheduler; \
	fi

.PHONY: activate-kueue
activate-kueue:
	$(MAKE) ensure-no-resident-state
	$(MAKE) cleanup-kueue-resources
	$(KUBECTL_CMD) scale deployment -n volcano-system volcano-scheduler volcano-controllers volcano-admission --replicas=0
	$(KUBECTL_CMD) scale deployment -n yunikorn yunikorn-scheduler yunikorn-admission-controller --replicas=0
	$(KUBECTL_CMD) scale deployment -n kueue-system kueue-controller-manager --replicas=1
	$(KUBECTL_CMD) scale deployment -n coscheduling coscheduling scheduler-plugins-controller --replicas=1

.PHONY: activate-volcano
activate-volcano:
	$(MAKE) ensure-no-resident-state
	$(MAKE) cleanup-volcano-resources
	$(KUBECTL_CMD) get configmap -n volcano-system volcano-scheduler-configmap -o json > \
		$(RESIDENT_STATE_DIR)/volcano-scheduler-configmap.raw.json
	jq 'del(.metadata.creationTimestamp, .metadata.managedFields, .metadata.resourceVersion, .metadata.uid)' \
		$(RESIDENT_STATE_DIR)/volcano-scheduler-configmap.raw.json > \
		$(RESIDENT_STATE_DIR)/volcano-scheduler-configmap.json
	rm -f $(RESIDENT_STATE_DIR)/volcano-scheduler-configmap.raw.json
	$(KUBECTL_CMD) scale deployment -n kueue-system kueue-controller-manager --replicas=0
	$(KUBECTL_CMD) scale deployment -n coscheduling coscheduling scheduler-plugins-controller --replicas=0
	$(KUBECTL_CMD) scale deployment -n yunikorn yunikorn-scheduler yunikorn-admission-controller --replicas=0
	$(KUBECTL_CMD) scale deployment -n volcano-system volcano-scheduler volcano-controllers volcano-admission --replicas=1

.PHONY: activate-yunikorn
activate-yunikorn:
	$(MAKE) ensure-no-resident-state
	$(MAKE) cleanup-yunikorn-resources
	@set -e; if $(KUBECTL_CMD) get configmap -n yunikorn yunikorn-configs -o json > \
		$(RESIDENT_STATE_DIR)/yunikorn-configs.raw.json 2>/dev/null; then \
		jq 'del(.metadata.creationTimestamp, .metadata.managedFields, .metadata.resourceVersion, .metadata.uid)' \
			$(RESIDENT_STATE_DIR)/yunikorn-configs.raw.json > $(RESIDENT_STATE_DIR)/yunikorn-configs.json; \
		rm -f $(RESIDENT_STATE_DIR)/yunikorn-configs.raw.json; \
	else \
		rm -f $(RESIDENT_STATE_DIR)/yunikorn-configs.raw.json; \
		touch $(RESIDENT_STATE_DIR)/yunikorn-configs.absent; \
	fi
	-$(KUBECTL_CMD) delete configmap -n yunikorn yunikorn-configs --ignore-not-found
	$(KUBECTL_CMD) scale deployment -n volcano-system volcano-scheduler volcano-controllers volcano-admission --replicas=0
	$(KUBECTL_CMD) scale deployment -n kueue-system kueue-controller-manager --replicas=0
	$(KUBECTL_CMD) scale deployment -n coscheduling coscheduling scheduler-plugins-controller --replicas=0
	$(KUBECTL_CMD) scale deployment -n yunikorn yunikorn-scheduler yunikorn-admission-controller --replicas=1

.PHONY: deactivate-kueue
deactivate-kueue:
	$(MAKE) cleanup-kueue-resources
	$(MAKE) restore-all-scheduler-deployments
	$(MAKE) wait-all-schedulers

.PHONY: deactivate-volcano
deactivate-volcano:
	$(MAKE) cleanup-volcano-resources
	$(MAKE) restore-volcano-config
	$(MAKE) restore-all-scheduler-deployments
	$(MAKE) wait-all-schedulers

.PHONY: deactivate-yunikorn
deactivate-yunikorn:
	$(MAKE) cleanup-yunikorn-resources
	$(MAKE) restore-yunikorn-config
	$(MAKE) restore-all-scheduler-deployments
	$(MAKE) wait-all-schedulers

.PHONY: wait-resident-kueue
wait-resident-kueue:
	$(KUBECTL_CMD) rollout status deployment -n kueue-system kueue-controller-manager --timeout=5m
	$(KUBECTL_CMD) rollout status deployment -n coscheduling coscheduling --timeout=5m
	$(KUBECTL_CMD) rollout status deployment -n coscheduling scheduler-plugins-controller --timeout=5m
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-base.sh 1000

.PHONY: wait-resident-volcano
wait-resident-volcano:
	$(KUBECTL_CMD) rollout status deployment -n volcano-system volcano-scheduler --timeout=5m
	$(KUBECTL_CMD) rollout status deployment -n volcano-system volcano-controllers --timeout=5m
	$(KUBECTL_CMD) rollout status deployment -n volcano-system volcano-admission --timeout=5m
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-base.sh 1000

.PHONY: wait-resident-yunikorn
wait-resident-yunikorn:
	$(KUBECTL_CMD) rollout status deployment -n yunikorn yunikorn-scheduler --timeout=5m
	$(KUBECTL_CMD) rollout status deployment -n yunikorn yunikorn-admission-controller --timeout=5m
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-base.sh 1000

.PHONY: wait-all-schedulers
wait-all-schedulers:
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-base.sh 1000
	cd $(RESIDENT_DEPLOY_DIR) && ./scripts/verify-schedulers.sh

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
	$(MAKE) cleanup-kueue-resources
	$(MAKE) cleanup-volcano-resources
	$(MAKE) cleanup-yunikorn-resources
	$(MAKE) restore-volcano-config
	$(MAKE) restore-yunikorn-config
	$(MAKE) restore-all-scheduler-deployments
	$(MAKE) wait-all-schedulers

.PHONY: serial-test
serial-test: ensure-directories
	$(foreach sched,$(SCHEDULERS), \
		$(MAKE) prepare-$(sched); \
		$(MAKE) start-$(sched); \
		$(MAKE) end-$(sched); \
	)

	$(MAKE) save-result

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
save-result:
	sleep $(RESULT_RECENT_DURATION_SECONDS)
	RECENT_DURATION="$(RESULT_RECENT_DURATION_SECONDS)second" ./hack/save-result-images.sh
	mkdir -p ./tmp
	echo $(TEST_ENVS) > ./tmp/envs.txt
	-mv ./output ./tmp/output
	-mv ./logs ./tmp/logs
	mkdir -p ./results
	mv ./tmp ./results/$(shell date +%s)

.PHONY: move-to-result
move-to-result:
	mkdir -p ./tmp
	-mv ./logs ./tmp/logs
	mkdir -p ./results
	mv ./tmp ./results/$(shell date +%s)

.PHONY: delete-registry
delete-registry:
	-docker rm -f kind-registry

.PHONY: cleanup
cleanup:
	-make down \
		delete-registry
	-rm -rf ./logs/
