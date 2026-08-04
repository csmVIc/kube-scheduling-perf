package kueue_test

import (
	"context"
	_ "embed"
	"fmt"
	"strings"
	"time"

	"github.com/wzshiming/kube-scheduling-perf/test/utils"
	"sigs.k8s.io/e2e-framework/klient/decoder"
)

//go:embed init.yaml
var initYaml string

//go:embed init_queue.yaml
var initQueueYaml string

//go:embed batch_job.yaml
var batchJobYaml string

type KueueProvider struct {
	utils.Options
}

func (p *KueueProvider) InitCase(ctx context.Context) error {
	var err error
	for i := 0; i < 3; i++ {
		err = decoder.DecodeEach(ctx, strings.NewReader(utils.YamlWithArgs(initYaml, map[string]any{
			"preemption": p.Preemption,
		})), decoder.CreateHandler(utils.Resources))
		if err == nil {
			break
		}
		time.Sleep(5 * time.Second)
	}
	if err != nil {
		return err
	}

	for i := range p.QueueSize {
		err := decoder.DecodeEach(ctx, strings.NewReader(utils.YamlWithArgs(initQueueYaml, map[string]any{
			"name":               fmt.Sprintf("long-term-research-%d", i),
			"cpuPerQueue":        p.CpuPerQueue,
			"memoryPerQueue":     p.MemoryPerQueue,
			"cpuLendingLimit":    p.CpuLendingLimit,
			"memoryLendingLimit": p.MemoryLendingLimit,
			"preemption":         p.Preemption,
		})), decoder.CreateHandler(utils.Resources))
		if err != nil {
			return err
		}
	}

	for i := range p.ImpactingQueuesSize {
		err := decoder.DecodeEach(ctx, strings.NewReader(utils.YamlWithArgs(initQueueYaml, map[string]any{
			"name":               fmt.Sprintf("business-impacting-%d", i),
			"cpuPerQueue":        p.CpuPerQueue,
			"memoryPerQueue":     p.MemoryPerQueue,
			"cpuLendingLimit":    p.CpuLendingLimit,
			"memoryLendingLimit": p.MemoryLendingLimit,
			"preemption":         p.Preemption,
		})), decoder.CreateHandler(utils.Resources))
		if err != nil {
			return err
		}
	}

	for i := range p.CriticalQueuesSize {
		err := decoder.DecodeEach(ctx, strings.NewReader(utils.YamlWithArgs(initQueueYaml, map[string]any{
			"name":               fmt.Sprintf("human-critical-%d", i),
			"cpuPerQueue":        p.CpuPerQueue,
			"memoryPerQueue":     p.MemoryPerQueue,
			"cpuLendingLimit":    p.CpuLendingLimit,
			"memoryLendingLimit": p.MemoryLendingLimit,
			"preemption":         p.Preemption,
		})), decoder.CreateHandler(utils.Resources))
		if err != nil {
			return err
		}
	}
	return nil
}

func (p *KueueProvider) AddJobs(ctx context.Context) error {
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

func (p *KueueProvider) addSingleJobs(ctx context.Context, podSize int, queueIndex int, priority string, duration string) error {
	return decoder.DecodeEach(ctx, strings.NewReader(utils.YamlWithArgs(batchJobYaml, map[string]any{
		"name":                fmt.Sprintf("%s-%d", priority, queueIndex),
		"queue":               fmt.Sprintf("default-local-queue-%s-%d", priority, queueIndex),
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
