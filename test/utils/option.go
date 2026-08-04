package utils

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Options struct {
	CpuPerQueue        string
	MemoryPerQueue     string
	CpuLendingLimit    string
	MemoryLendingLimit string

	QueueSize        int
	JobsSizePerQueue int
	PodsSizePerJob   int
	PodDuration      string

	ImpactingQueuesSize       int
	ImpactingJobsSizePerQueue int
	ImpactingPodsSizePerJob   int
	ImpactingPodDuration      string

	CriticalQueuesSize       int
	CriticalJobsSizePerQueue int
	CriticalPodsSizePerJob   int
	CriticalPodDuration      string

	CpuRequestPerPod    string
	MemoryRequestPerPod string

	Gang       bool
	Preemption bool
}

func (o *Options) AddFlags() {
	flag.IntVar(&o.QueueSize, "queues-size", getEnvInt("QUEUES_SIZE", 1), "Number of queues to create")
	flag.IntVar(&o.JobsSizePerQueue, "jobs-size-per-queue", getEnvInt("JOBS_SIZE_PER_QUEUE", 1), "Number of jobs per queue")
	flag.IntVar(&o.PodsSizePerJob, "pods-size-per-job", getEnvInt("PODS_SIZE_PER_JOB", 1), "Number of pods per job")
	flag.StringVar(&o.PodDuration, "pod-duration", getEnv("POD_DURATION", "30s"), "Duration of each pod")

	flag.IntVar(&o.ImpactingQueuesSize, "impacting-queues-size", getEnvInt("IMPACTING_QUEUES_SIZE", 0), "Number of business impacting queues to create")
	flag.IntVar(&o.ImpactingJobsSizePerQueue, "impacting-jobs-size-per-queue", getEnvInt("IMPACTING_JOBS_SIZE_PER_QUEUE", 1), "Number of business impacting jobs per queue")
	flag.IntVar(&o.ImpactingPodsSizePerJob, "impacting-pods-size-per-job", getEnvInt("IMPACTING_PODS_SIZE_PER_JOB", 1), "Number of pods per business impacting job")
	flag.StringVar(&o.ImpactingPodDuration, "impacting-pod-duration", getEnv("IMPACTING_POD_DURATION", "30s"), "Duration of each business impacting pod")

	flag.IntVar(&o.CriticalQueuesSize, "critical-queues-size", getEnvInt("CRITICAL_QUEUES_SIZE", 0), "Number of human critical queues to create")
	flag.IntVar(&o.CriticalJobsSizePerQueue, "critical-jobs-size-per-queue", getEnvInt("CRITICAL_JOBS_SIZE_PER_QUEUE", 1), "Number of human critical jobs per queue")
	flag.IntVar(&o.CriticalPodsSizePerJob, "critical-pods-size-per-job", getEnvInt("CRITICAL_PODS_SIZE_PER_JOB", 1), "Number of pods per human critical job")
	flag.StringVar(&o.CriticalPodDuration, "critical-pod-duration", getEnv("CRITICAL_POD_DURATION", "30s"), "Duration of each human critical pod")

	flag.StringVar(&o.CpuPerQueue, "cpu-per-queue", getEnv("CPU_PER_QUEUE", "10000"), "CPU resources per queue")
	flag.StringVar(&o.MemoryPerQueue, "memory-per-queue", getEnv("MEMORY_PER_QUEUE", "10000Gi"), "Memory resources per queue")
	flag.StringVar(&o.CpuLendingLimit, "cpu-lending-limit", getEnv("CPU_LENDING_LIMIT", ""), "CPU lending limit per queue")
	flag.StringVar(&o.MemoryLendingLimit, "memory-lending-limit", getEnv("MEMORY_LENDING_LIMIT", ""), "Memory lending limit per queue")
	flag.StringVar(&o.CpuRequestPerPod, "cpu-request-per-pod", getEnv("CPU_REQUEST_PER_POD", "1"), "CPU request per pod")
	flag.StringVar(&o.MemoryRequestPerPod, "memory-request-per-pod", getEnv("MEMORY_REQUEST_PER_POD", "1Gi"), "Memory request per pod")
	flag.BoolVar(&o.Gang, "gang", getEnvBool("GANG", false), "Enable gang scheduling")
	flag.BoolVar(&o.Preemption, "preemption", getEnvBool("PREEMPTION", false), "Enable preemption")
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	if value, exists := os.LookupEnv(key); exists {
		var result int
		_, err := fmt.Sscan(value, &result)
		if err == nil {
			return result
		}
	}
	return fallback
}

func getEnvBool(key string, fallback bool) bool {
	if value, exists := os.LookupEnv(key); exists {
		result, err := strconv.ParseBool(strings.ToLower(value))
		if err == nil {
			return result
		}
	}
	return fallback
}
