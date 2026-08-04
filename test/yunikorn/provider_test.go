package yunikorn_test

import (
	"context"
	_ "embed"
	"fmt"
	"strings"
	"time"

	"github.com/wzshiming/kube-scheduling-perf/test/utils"
	"k8s.io/apimachinery/pkg/api/resource"
	"sigs.k8s.io/e2e-framework/klient/decoder"
)

//go:embed init_queue.yaml
var initQueueYaml string

//go:embed batch_job.yaml
var batchJobYaml string

type YunikornProvider struct {
	utils.Options
}

func (p *YunikornProvider) InitCase(ctx context.Context) error {
	cpuGuaranteed := p.CpuPerQueue
	cpuMax := p.CpuPerQueue
	memoryGuaranteed := p.MemoryPerQueue
	memoryMax := p.MemoryPerQueue

	if p.CpuLendingLimit != "" {
		lending, err := resource.ParseQuantity(p.CpuLendingLimit)
		if err != nil {
			return err
		}

		guaranteed, err := resource.ParseQuantity(cpuGuaranteed)
		if err != nil {
			return err
		}
		tmp := guaranteed.DeepCopy()
		tmp.Sub(lending)
		cpuGuaranteed = tmp.String()
	}

	if p.MemoryLendingLimit != "" {
		lending, err := resource.ParseQuantity(p.MemoryLendingLimit)
		if err != nil {
			return err
		}

		guaranteed, err := resource.ParseQuantity(memoryGuaranteed)
		if err != nil {
			return err
		}
		tmp := guaranteed.DeepCopy()
		tmp.Sub(lending)
		memoryGuaranteed = tmp.String()
	}

	err := decoder.DecodeEach(ctx, strings.NewReader(utils.YamlWithArgs(initQueueYaml, map[string]any{
		"queueSize":          make([]byte, p.QueueSize),
		"impactingQueueSize": make([]byte, p.ImpactingQueuesSize),
		"criticalQueueSize":  make([]byte, p.CriticalQueuesSize),
		"cpuGuarantee":       cpuGuaranteed,
		"cpuMax":             cpuMax,
		"memoryGuarantee":    memoryGuaranteed,
		"memoryMax":          memoryMax,
		"preemption":         p.Preemption,
	})), decoder.CreateHandler(utils.Resources))
	if err != nil {
		return err
	}

	return utils.RestartDeployment(ctx, utils.Resources, "yunikorn-scheduler", "yunikorn")
}

func (p *YunikornProvider) AddJobs(ctx context.Context) error {
	steps := []struct {
		queueSize    int
		jobsPerQueue int
		podsPerJob   int
		priority     string
		duration     string
		delay        time.Duration
	}{
		{p.QueueSize, p.JobsSizePerQueue, p.PodsSizePerJob, "long-term-research", p.PodDuration, 0},
		{p.ImpactingQueuesSize, p.ImpactingJobsSizePerQueue, p.ImpactingPodsSizePerJob, "business-impacting", p.ImpactingPodDuration, 5 * time.Second},
		{p.CriticalQueuesSize, p.CriticalJobsSizePerQueue, p.CriticalPodsSizePerJob, "human-critical", p.CriticalPodDuration, 5 * time.Second},
	}

	for _, step := range steps {
		if step.delay > 0 {
			time.Sleep(step.delay)
		}
		for i := range step.queueSize {
			for range step.jobsPerQueue {
				err := p.addSingleJobs(ctx, step.podsPerJob, i, step.priority, step.duration)
				if err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func (p *YunikornProvider) addSingleJobs(ctx context.Context, podSize int, queueIndex int, priority string, duration string) error {
	return decoder.DecodeEach(ctx, strings.NewReader(utils.YamlWithArgs(batchJobYaml, map[string]any{
		"name":                fmt.Sprintf("%s-%d", priority, queueIndex),
		"queue":               fmt.Sprintf("root.sandbox.%s-%d", priority, queueIndex),
		"size":                podSize,
		"index":               utils.Index(),
		"cpuRequestPerPod":    p.CpuRequestPerPod,
		"memoryRequestPerPod": p.MemoryRequestPerPod,
		"gang":                p.Gang,
		"priority":            priority,
		"preemption":          p.Preemption,
		"duration":            duration,
	})), decoder.CreateHandler(utils.Resources))
}
